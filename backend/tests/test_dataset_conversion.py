"""Transactional HEIC replacement, using tiny real images in temporary folders."""

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np
import pillow_heif
from PIL import Image

from ml.image_preprocessing import load_rgb_image
from scripts import convert_dataset_heic as conversion


class DatasetConversionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.dataset = self.directory / "dataset"
        self.dataset.mkdir()
        self.backups = self.directory / "backups"
        pillow_heif.register_heif_opener()

    def heic(self, name="one.HEIC", orientation=None):
        path = self.dataset / "Premium" / "batch_06" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        pixels = np.zeros((32, 48, 3), dtype=np.uint8)
        pixels[:16, :, 0] = 230
        pixels[16:, :, 2] = 230
        with Image.fromarray(pixels) as image:
            options = {}
            if orientation is not None:
                exif = image.getexif()
                exif[274] = orientation
                options["exif"] = exif
            image.save(path, format="HEIF", **options)
        return path

    def test_plan_is_read_only_and_lists_every_image_without_trimming(self):
        for number in range(31):
            self.heic(f"photo_{number:02}.heic")
        before = {path: path.read_bytes() for path in self.dataset.rglob("*.heic")}

        plan = conversion.plan_conversion(self.dataset)

        self.assertEqual(plan["conversion_count"], 31)
        self.assertEqual(plan["image_count"], 31)
        self.assertEqual({path: path.read_bytes() for path in before}, before)
        self.assertFalse(self.backups.exists())
        self.assertFalse(list(self.dataset.rglob("*.jpg")))

    def test_apply_preserves_original_bytes_dimensions_orientation_and_total(self):
        original = self.heic(orientation=6)
        original_bytes = original.read_bytes()
        with load_rgb_image(original) as expected_image:
            expected_size = expected_image.size
            expected_pixels = np.asarray(expected_image)

        report = conversion.apply_conversion(self.dataset, self.backups)

        output = original.with_suffix(".jpg")
        backup = Path(report["backup"]) / "originals" / original.relative_to(self.dataset)
        self.assertEqual(report["converted"], 1)
        self.assertEqual(report["image_count"], 1)
        self.assertFalse(original.exists())
        self.assertEqual(backup.read_bytes(), original_bytes)
        self.assertFalse(Path(report["backup"]).is_relative_to(self.dataset))
        with Image.open(output) as jpeg:
            jpeg.load()
            self.assertEqual(jpeg.format, "JPEG")
            self.assertEqual(jpeg.mode, "RGB")
            self.assertEqual(jpeg.size, expected_size)
            self.assertIn(jpeg.getexif().get(274), (None, 1))
            self.assertLess(np.abs(np.asarray(jpeg).astype(float) - expected_pixels).mean(), 5)
        manifest = json.loads(Path(report["manifest"]).read_text(encoding="utf-8"))
        self.assertEqual(manifest["status"], "completed")
        self.assertEqual(manifest["image_count_before"], manifest["image_count_after"])
        record = manifest["files"][0]
        self.assertEqual(record["source_sha256"], conversion.sha256(backup))
        self.assertEqual(record["output_sha256"], conversion.sha256(output))
        self.assertEqual(record["size"], list(expected_size))

    def test_existing_jpeg_collision_fails_before_any_modification(self):
        original = self.heic()
        output = original.with_suffix(".jpg")
        output.write_bytes(b"existing user JPEG")
        original_bytes = original.read_bytes()

        with self.assertRaisesRegex(ValueError, "collid|exists"):
            conversion.apply_conversion(self.dataset, self.backups)

        self.assertEqual(original.read_bytes(), original_bytes)
        self.assertEqual(output.read_bytes(), b"existing user JPEG")
        self.assertFalse(self.backups.exists())

    def test_two_heif_extensions_with_same_stem_fail_before_modification(self):
        first = self.heic("same.heic")
        second = self.heic("same.heif")
        with self.assertRaisesRegex(ValueError, "collid|exists"):
            conversion.apply_conversion(self.dataset, self.backups)
        self.assertTrue(first.exists())
        self.assertTrue(second.exists())
        self.assertFalse(self.backups.exists())

    def test_invalid_second_image_never_changes_active_first_image(self):
        first = self.heic("a.heic")
        second = first.parent / "z.heic"
        second.write_bytes(b"invalid HEIC")
        original_bytes = first.read_bytes()

        with self.assertRaisesRegex(RuntimeError, "stopped safely"):
            conversion.apply_conversion(self.dataset, self.backups)

        self.assertEqual(first.read_bytes(), original_bytes)
        self.assertEqual(second.read_bytes(), b"invalid HEIC")
        self.assertFalse(list(self.dataset.rglob("*.jpg")))

    def test_partial_original_removal_is_rolled_back_from_verified_backups(self):
        first, second = self.heic("a.heic"), self.heic("b.heic")
        before = {path: path.read_bytes() for path in (first, second)}
        real_unlink = Path.unlink
        source_removals = []

        def fail_second_removal(path, *args, **kwargs):
            if path in before:
                source_removals.append(path)
                if len(source_removals) == 2:
                    raise OSError("simulated disk failure during original removal")
            return real_unlink(path, *args, **kwargs)

        with patch.object(Path, "unlink", new=fail_second_removal):
            with self.assertRaisesRegex(RuntimeError, "simulated disk failure"):
                conversion.apply_conversion(self.dataset, self.backups)

        self.assertEqual(len(source_removals), 2)
        self.assertEqual({path: path.read_bytes() for path in before}, before)
        self.assertFalse(list(self.dataset.rglob("*.jpg")))
        manifests = list(self.backups.glob("*/manifest.json"))
        self.assertEqual(len(manifests), 1)
        manifest = json.loads(manifests[0].read_text())
        self.assertEqual(manifest["status"], "failed")
        self.assertEqual(manifest["rollback_errors"], [])
        for path in before:
            backup = manifests[0].parent / "originals" / path.relative_to(self.dataset)
            self.assertEqual(backup.read_bytes(), before[path])

    def test_backup_copy_failure_preserves_originals_and_never_promotes_jpeg(self):
        original = self.heic()
        original_bytes = original.read_bytes()
        with patch.object(conversion, "copy_verified", side_effect=OSError("backup storage full")):
            with self.assertRaisesRegex(RuntimeError, "backup storage full"):
                conversion.apply_conversion(self.dataset, self.backups)
        self.assertEqual(original.read_bytes(), original_bytes)
        self.assertFalse(list(self.dataset.rglob("*.jpg")))

    def test_no_heic_is_a_safe_noop(self):
        directory = self.dataset / "Premium" / "batch_06"
        directory.mkdir(parents=True)
        output = directory / "rice.jpg"
        with Image.new("RGB", (12, 16), "white") as image:
            image.save(output)
        before = output.read_bytes()

        report = conversion.apply_conversion(self.dataset, self.backups)

        self.assertEqual(report["status"], "no_changes")
        self.assertEqual(report["converted"], 0)
        self.assertEqual(report["image_count"], 1)
        self.assertEqual(output.read_bytes(), before)
        self.assertFalse(self.backups.exists())

    def test_misplaced_images_and_overlapping_backup_are_refused(self):
        original = self.heic()
        with self.assertRaisesRegex(ValueError, "overlap"):
            conversion.apply_conversion(self.dataset, self.dataset / "backups")
        misplaced = self.dataset / "outside.heic"
        misplaced.write_bytes(original.read_bytes())
        with self.assertRaisesRegex(ValueError, "outside"):
            conversion.plan_conversion(self.dataset)
        self.assertTrue(original.exists())
        self.assertTrue(misplaced.exists())
        self.assertFalse(self.backups.exists())


if __name__ == "__main__":
    unittest.main()
