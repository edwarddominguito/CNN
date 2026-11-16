"""Phone photo regressions, using small real HEIC files and no model training."""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

import numpy as np
import pillow_heif
import tensorflow as tf
from PIL import Image

from ml import image_preprocessing as images


class DatasetFormatTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        pillow_heif.register_heif_opener()

    def image(self, relative, color=(20, 60, 110), image_format=None):
        target = self.root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        with Image.new("RGB", (24, 32), color) as source:
            source.save(target, format=image_format)
        return target

    def test_scanner_reads_heic_heif_and_webp_without_changing_sources(self):
        paths = [
            self.image("Premium/batch_06/PHOTO.HEIC", image_format="HEIF"),
            self.image("Well-Milled/batch_06/rice.heif", (50, 100, 150), "HEIF"),
            self.image("Poor-Quality-Rice-Mix/batch_06/rice.webp", (80, 130, 180)),
        ]
        original_bytes = {path: path.read_bytes() for path in paths}

        scanned = images.scan_dataset(self.root)

        self.assertEqual(scanned.class_names, images.CLASS_NAMES)
        self.assertEqual(set(scanned.paths.tolist()), {str(path) for path in paths})
        self.assertEqual(scanned.labels.tolist(), [0, 1, 2])
        self.assertEqual(len(set(scanned.groups.tolist())), 3)
        self.assertEqual(scanned.problems, [])
        for path in paths:
            self.assertEqual(path.read_bytes(), original_bytes[path])

    def test_tensorflow_reads_unicode_heic_byte_paths_for_training_and_validation(self):
        path = self.image("Premium/batch_06/paláy_米.HEIC", image_format="HEIF")
        paths = np.asarray([str(path)])
        labels = np.asarray([2], dtype=np.int32)
        expected = images.load_inference_image(path)

        for training in (False, True):
            with self.subTest(training=training):
                dataset = images.make_dataset(paths, labels, 1, training, 42)
                batch, actual_labels = next(iter(dataset))
                self.assertEqual(batch.shape, (1, *images.IMAGE_SIZE, 3))
                self.assertEqual(batch.dtype, tf.float32)
                self.assertEqual(actual_labels.numpy().tolist(), [2])
                self.assertTrue(np.isfinite(batch.numpy()).all())
                if not training:
                    np.testing.assert_array_equal(batch.numpy()[0], expected)

        # tf.numpy_function receives UTF-8 bytes even though scanning uses Paths.
        with images.load_rgb_image(os.fsencode(path)) as decoded:
            self.assertEqual(decoded.size, (24, 32))

    def test_standard_images_do_not_require_optional_heif_dependency(self):
        path = self.image("Premium/batch_01/rice.jpg")
        with patch.dict(sys.modules, {"pillow_heif": None}):
            scanned = images.scan_dataset(self.root)
            self.assertEqual(scanned.paths.tolist(), [str(path)])
            self.assertEqual(scanned.problems, [])
            self.assertEqual(images.load_inference_image(path).shape, (*images.IMAGE_SIZE, 3))

    def test_missing_heif_dependency_is_reported_and_blocks_incomplete_training(self):
        # There are already enough JPEG batches to train: missing all the newly
        # added HEIC photos must still be an explicit failure, not a partial run.
        for grade, class_name in enumerate(images.CLASS_NAMES):
            for batch in range(5):
                self.image(f"{class_name}/batch_{batch:02}/rice.jpg", (grade * 70, batch * 35, 20))
        path = self.image("Premium/batch_06/new.heic", (100, 120, 140), "HEIF")

        with patch.dict(sys.modules, {"pillow_heif": None}):
            with self.assertRaisesRegex(ValueError, "(?i)(heic|heif|pillow)"):
                images.load_rgb_image(path)
            scanned = images.scan_dataset(self.root)

        self.assertEqual(len(scanned.paths), 15)
        self.assertTrue(any(problem_path == path and
                            any(word in reason.lower() for word in ("heic", "heif", "pillow"))
                            for reason, problem_path in scanned.problems))
        with self.assertRaisesRegex(images.DatasetError, "(?i)(heic|heif|pillow)"):
            images.check_ready_for_training(scanned, 5)

    def test_corrupt_heic_is_excluded_instead_of_reaching_tensorflow(self):
        path = self.root / "Premium/batch_06/broken.HEIC"
        path.parent.mkdir(parents=True)
        path.write_bytes(b"this is not a HEIC photo")

        scanned = images.scan_dataset(self.root)

        self.assertEqual(len(scanned.paths), 0)
        self.assertTrue(any(problem_path == path for _, problem_path in scanned.problems))
        self.assertEqual(scanned.batches["Premium"]["batch_06"], 0)

    def test_codec_decode_failures_are_reported_by_path(self):
        path = self.image("Premium/batch_06/rice.heic", image_format="HEIF")
        for failure in (EOFError("truncated HEIF"), RuntimeError("HEIF decode failed"),
                        SyntaxError("invalid HEIF header")):
            with self.subTest(failure=type(failure).__name__):
                with patch.object(images, "load_rgb_image", side_effect=failure):
                    scanned = images.scan_dataset(self.root)
                self.assertEqual(len(scanned.paths), 0)
                self.assertTrue(any(problem_path == path for _, problem_path in scanned.problems))

    def test_multiframe_heif_is_rejected_before_any_frame_is_discarded(self):
        path = self.root / "multiple.heic"
        with Image.new("RGB", (24, 32), "red") as first, \
             Image.new("RGB", (24, 32), "blue") as second:
            first.save(path, format="HEIF", save_all=True, append_images=[second])

        with self.assertRaisesRegex(ValueError, "multiple-frame"):
            images.load_rgb_image(path)

    def test_oversized_heif_is_rejected_before_pixel_decode(self):
        source = MagicMock(width=images.MAX_IMAGE_PIXELS + 1, height=1,
                           format="HEIF", n_frames=1)
        source.load.side_effect = AssertionError("oversized HEIF must not be decoded")
        with patch.object(Image, "open") as opened:
            opened.return_value.__enter__.return_value = source
            with self.assertRaisesRegex(ValueError, "pixel limit"):
                images.load_rgb_image(self.root / "oversized.heic")
        source.load.assert_not_called()


if __name__ == "__main__":
    unittest.main()
