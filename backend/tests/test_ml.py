"""Dataset and training regressions that do not train or download a model."""

import shutil
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch
from zipfile import BadZipFile

import numpy as np
import tensorflow as tf
from PIL import Image

from ml import evaluate_model, image_preprocessing as images, model_calibration, train_model
from ml.train_5fold import run
from scripts import convert_heic_dataset


class DatasetTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def image(self, relative, color=(10, 20, 30)):
        target = self.root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        Image.new("RGB", (24, 32), color).save(target)
        return target

    def test_rejects_oversized_image_before_decoding(self):
        source = MagicMock(width=images.MAX_IMAGE_PIXELS + 1, height=1)
        source.load.side_effect = AssertionError("must not decode oversized pixels")
        with patch.object(Image, "open") as opened:
            opened.return_value.__enter__.return_value = source
            with self.assertRaisesRegex(ValueError, "pixel limit"):
                images.load_inference_image("large.png")
        source.load.assert_not_called()

    def test_validation_pixels_match_serving_including_exif(self):
        path = self.root / "oriented.jpg"
        array = np.zeros((30, 50, 3), dtype=np.uint8)
        array[:, :25, 0] = 240
        array[:, 25:, 1] = 240
        source = Image.fromarray(array)
        exif = source.getexif()
        exif[274] = 6
        source.save(path, exif=exif)
        with images.load_rgb_image(path) as decoded:
            self.assertEqual(decoded.size, (30, 50))
        actual, label = images.load_image(tf.constant(str(path)), tf.constant(1), False)
        np.testing.assert_array_equal(actual.numpy(), images.load_inference_image(path))
        self.assertEqual(int(label), 1)

    def test_scanner_rejects_truncated_jpeg_that_verify_accepts(self):
        path = self.image("Premium/batch_01/truncated.jpg")
        path.write_bytes(path.read_bytes()[:-20])
        with Image.open(path) as image:
            image.verify()
        scanned = images.scan_dataset(self.root)
        self.assertEqual(len(scanned.paths), 0)
        self.assertTrue(any(reason == "corrupt or unreadable image" for reason, _ in scanned.problems))

    def test_duplicate_pixels_across_groups_block_training(self):
        for class_index, class_name in enumerate(images.CLASS_NAMES):
            for batch in range(5):
                self.image(f"{class_name}/batch_{batch:02}/image.png", (class_index * 60, batch * 30, 50))
        original = self.root / images.CLASS_NAMES[0] / "batch_00/image.png"
        copied = self.root / images.CLASS_NAMES[1] / "batch_00/copied.png"
        shutil.copyfile(original, copied)
        scanned = images.scan_dataset(self.root)
        with self.assertRaisesRegex(images.DatasetError, "duplicate image pixels"):
            images.check_ready_for_training(scanned, 5)

    def test_pipeline_rejects_empty_or_mismatched_inputs(self):
        for paths, labels, batch_size in (([], [], 1), (["one"], [], 1), (["one"], [0], 0)):
            with self.subTest(paths=paths, labels=labels, batch_size=batch_size):
                with self.assertRaises(images.DatasetError):
                    images.make_dataset(paths, labels, batch_size, False, 42)

    def test_training_pipeline_decodes_and_batches_bounded_rgb_images(self):
        paths = np.asarray([str(self.image("first.png")), str(self.image("second.png", (50, 60, 70)))])
        dataset = images.make_dataset(paths, np.asarray([0, 1]), 2, True, 42)
        batch, labels = next(iter(dataset))
        self.assertEqual(batch.shape, (2, *images.IMAGE_SIZE, 3))
        self.assertEqual(batch.dtype, tf.float32)
        self.assertTrue(np.isfinite(batch.numpy()).all())
        self.assertEqual(sorted(labels.numpy().tolist()), [0, 1])

    def test_unusable_embedding_cache_returns_none(self):
        target = self.root / "cache.npz"
        np.savez(target, class_names=np.array(["Premium"]), labels=np.array([0]),
                 paths=np.array(["file"]), embeddings=np.array([["invalid"]]))
        self.assertIsNone(model_calibration.load_support_embeddings(["Premium"], target))
        np.savez(target, class_names=np.array(["Premium"]), labels=np.array([0]),
                 paths=np.array([]), embeddings=np.array([[1.0]]))
        self.assertIsNone(model_calibration.load_support_embeddings(["Premium"], target))

    def test_mistyped_corrupt_and_complex_embedding_caches_are_unavailable(self):
        target = self.root / "cache.npz"
        with target.open("wb") as stream:
            np.save(stream, np.array([1, 2, 3]))
        self.assertIsNone(model_calibration.load_support_embeddings(["Premium"], str(target)))
        np.savez(target, class_names=np.array(["Premium"]), labels=np.array([0]),
                 paths=np.array(["file"]), embeddings=np.array([[1 + 2j]]))
        self.assertIsNone(model_calibration.load_support_embeddings(["Premium"], target))
        with patch.object(np, "load", side_effect=BadZipFile("CRC mismatch")):
            self.assertIsNone(model_calibration.load_support_embeddings(["Premium"], target))

    def test_inference_closes_large_pixel_buffers_when_resize_fails(self):
        image = MagicMock(size=(100, 100))
        image.__enter__.return_value = image
        crop = image.crop.return_value.__enter__.return_value
        crop.resize.side_effect = OSError("resize failed")
        with patch.object(images, "load_rgb_image", return_value=image):
            with self.assertRaisesRegex(OSError, "resize failed"):
                images.load_inference_image("file.png")
        image.__exit__.assert_called_once()
        image.crop.return_value.__exit__.assert_called_once()

    def test_conversion_refuses_distinct_images_with_same_output_name(self):
        audit = {
            "structural_problems": [],
            "destination_collisions": [["sample.heic", "sample.jpg"]],
            "records": [
                {"source_path": "sample.heic", "valid": True, "pixel_sha256": "first"},
                {"source_path": "sample.jpg", "valid": True, "pixel_sha256": "second"},
            ],
        }
        with patch.object(convert_heic_dataset, "BACKEND", self.root):
            with self.assertRaisesRegex(ValueError, "Different images"):
                convert_heic_dataset.prepare(SimpleNamespace(), audit)
        self.assertFalse((self.root / "data/dataset_converted").exists())


class TrainingTests(unittest.TestCase):
    def test_failed_atomic_save_preserves_previous_file_and_removes_staging(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            target = directory / "model.keras"
            target.write_bytes(b"previous model")

            def failed_save(pending):
                pending.write_bytes(b"partial new model")
                raise OSError("disk full")

            with self.assertRaisesRegex(OSError, "disk full"):
                train_model.save_atomically(target, failed_save)
            self.assertEqual(target.read_bytes(), b"previous model")
            self.assertEqual(list(directory.iterdir()), [target])

    def test_overlapping_atomic_writers_have_independent_staging(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "model.keras"

            def outer_save(pending):
                pending.write_bytes(b"outer")
                train_model.save_atomically(target, lambda inner: inner.write_bytes(b"inner"))

            train_model.save_atomically(target, outer_save)
            self.assertEqual(target.read_bytes(), b"outer")
            self.assertEqual(list(target.parent.iterdir()), [target])

    def test_invalid_metrics_json_never_replaces_previous_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "metrics.json"
            target.write_text('{"accuracy":36.2}', encoding="utf-8")
            with self.assertRaises(ValueError):
                evaluate_model.write_json(target, {"accuracy": float("nan")})
            self.assertEqual(target.read_text(encoding="utf-8"), '{"accuracy":36.2}')
            self.assertEqual(list(target.parent.iterdir()), [target])

    def test_failed_plot_write_closes_figure(self):
        before = evaluate_model.plt.get_fignums()
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "matrix.png"
            with patch("matplotlib.figure.Figure.savefig", side_effect=OSError("disk full")):
                with self.assertRaisesRegex(OSError, "disk full"):
                    evaluate_model.save_confusion_matrix([[1, 0], [0, 1]], ["A", "B"], target, "test")
        self.assertEqual(evaluate_model.plt.get_fignums(), before)

    def test_evaluation_rejects_invalid_probabilities_and_accepts_partial_grade_set(self):
        model = MagicMock()
        outputs = (
            [[-0.1, 0.6, 0.5]], [[0.1, 0.1, 0.1]], [[float("nan"), 0, 1]],
            [["invalid", "output", "values"]], [[1 + 2j, 0, 0]], [[1, 0]],
        )
        with patch.object(evaluate_model, "load_inference_image", return_value=np.zeros((2, 2, 3), dtype=np.uint8)):
            for output in outputs:
                with self.subTest(output=output), self.assertRaisesRegex(ValueError, "probabilit"):
                    model.predict.return_value = output
                    evaluate_model.evaluate_fold(model, ["one"], [0], ["A", "B", "C"])
            model.predict.return_value = [[0.8, 0.1, 0.1]]
            result = evaluate_model.evaluate_fold(model, ["one"], [0], ["A", "B", "C"])
        self.assertEqual(result["accuracy"], 1.0)
        self.assertEqual(result["per_class"]["B"]["support"], 0)

    def test_failed_final_training_preserves_existing_dashboard_metrics(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            metrics_path = directory / "metrics.json"
            metrics_path.write_text('{"accuracy":36.2}', encoding="utf-8")
            args = SimpleNamespace(seed=42, dataset=directory, results_dir=directory / "results",
                                   output_model=directory / "model.keras", check_only=False,
                                   batch_size=1, epochs=1)
            scanned = SimpleNamespace(class_names=images.CLASS_NAMES)
            fold = {"confusion_matrix": np.eye(3).tolist(), "accuracy": 0.5,
                    "f1_score": 0.5, "best_epoch": 1}
            with patch("ml.train_5fold.scan_dataset", return_value=scanned), \
                 patch("ml.train_5fold.describe_dataset"), \
                 patch("ml.train_5fold.check_ready_for_training"), \
                 patch("ml.train_5fold.build_folds", return_value=[None] * 5), \
                 patch("ml.train_5fold.run_one_fold", return_value=fold), \
                 patch.object(evaluate_model, "save_fold_results", return_value="saved"), \
                 patch.object(evaluate_model, "save_confusion_matrix"), \
                 patch.object(evaluate_model, "save_dashboard_metrics") as save_metrics, \
                 patch.object(train_model, "train_deployment_model", side_effect=RuntimeError("training failed")):
                with self.assertRaisesRegex(RuntimeError, "training failed"):
                    run(args)
                save_metrics.assert_not_called()
            self.assertEqual(metrics_path.read_text(encoding="utf-8"), '{"accuracy":36.2}')

    def test_check_only_validates_actual_folds(self):
        args = SimpleNamespace(seed=42, dataset=Path("dataset"), results_dir=Path("results"),
                               output_model=Path("model.keras"), check_only=True)
        with patch("ml.train_5fold.scan_dataset") as scan, \
             patch("ml.train_5fold.describe_dataset"), \
             patch("ml.train_5fold.check_ready_for_training"), \
             patch("ml.train_5fold.build_folds", side_effect=images.DatasetError("invalid fold")):
            with self.assertRaisesRegex(images.DatasetError, "invalid fold"):
                run(args)
            scan.assert_called_once()

    def test_custom_deployment_model_filename_is_honored(self):
        scanned = SimpleNamespace(paths=np.array(["one"]), labels=np.array([0]),
                                  class_names=["Premium", "Well-Milled"])
        model = MagicMock()
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "custom.keras"
            with patch.object(train_model, "start_fresh_model", return_value=model), \
                 patch.object(train_model, "make_dataset"), \
                 patch.object(train_model, "save_atomically") as save, \
                 patch.object(train_model, "save_calibration_cache") as cache:
                train_model.train_deployment_model(scanned, [1], 1, 42, target)
            self.assertEqual(save.call_args_list[0].args[0], target)
            self.assertEqual(save.call_args_list[1].args[0], target.parent / "class_names.json")
            cache.assert_called_once_with(model, scanned, target.parent / "support_embeddings.npz")

    def test_evaluation_loads_only_one_batch_at_a_time(self):
        model = MagicMock()
        model.predict.side_effect = lambda batch, verbose: np.eye(3)[batch[:, 0, 0, 0]]
        with patch.object(evaluate_model, "load_inference_image", side_effect=lambda path: np.full((2, 2, 3), int(path), dtype=np.uint8)):
            result = evaluate_model.evaluate_fold(model, ["0", "1", "2", "0", "1"],
                                                  [0, 1, 2, 0, 1], ["A", "B", "C"], batch_size=2)
        self.assertEqual(result["accuracy"], 1.0)
        self.assertEqual([len(call.args[0]) for call in model.predict.call_args_list], [2, 2, 1])


if __name__ == "__main__":
    unittest.main()
