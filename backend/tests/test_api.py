"""API failure paths and resource limits, isolated from real prediction history."""

import asyncio
import io
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import httpx
import anyio.to_thread
import numpy as np
from fastapi.testclient import TestClient
from PIL import Image

from app import main


class FakeModel:
    input_shape = (None, 224, 224, 3)
    output_shape = (None, 3)

    def __call__(self, images, training=False):
        return np.array([[0.8, 0.15, 0.05]], dtype=np.float32)


def png():
    data = io.BytesIO()
    Image.new("RGB", (32, 32), "white").save(data, format="PNG")
    return data.getvalue()


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        for patcher in (
            patch.object(main, "UPLOADS_DIR", Path(self.directory.name) / "nested" / "uploads"),
            patch.object(main, "load_model", return_value=(FakeModel(), None)),
            patch.object(main.database, "init_database"),
            patch.object(main.database, "check_connection"),
            patch.object(main.database, "add_prediction", return_value=42),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)
        main.DATABASE_AVAILABLE = False
        main.DATABASE_RETRY_AT = 0
        self.client = self.enterContext(TestClient(main.app))

    def assert_no_uploads(self):
        self.assertFalse(list(Path(self.directory.name).rglob("upload_*")))

    def test_predict_real_image_decode_and_cleanup(self):
        response = self.client.post("/predict", files={"file": ("rice.png", png(), "image/png")})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json(), {"predicted_grade": "Premium", "confidence": 80.0, "history_saved": True})
        entry = main.database.add_prediction.call_args.args[0]
        self.assertIsNone(entry["image_path"])
        self.assert_no_uploads()

    def test_missing_model_is_503(self):
        with patch.object(main, "model", None):
            response = self.client.post("/predict", files={"file": ("rice.png", png())})
        self.assertEqual(response.status_code, 503)
        self.assert_no_uploads()

    def test_corrupt_and_empty_uploads_are_400(self):
        for body in (b"not an image", b""):
            with self.subTest(body=body):
                response = self.client.post("/predict", files={"file": ("rice.png", body)})
                self.assertEqual(response.status_code, 400)
                self.assert_no_uploads()

    def test_temporary_request_read_failure_is_retryable_and_recovers(self):
        class UnreadableSpool(io.BytesIO):
            def read(self, size=-1):
                raise OSError("temporary disk read failed")
        with patch("app.middleware.SpooledTemporaryFile", side_effect=lambda **options: UnreadableSpool()):
            response = self.client.post("/predict", files={"file": ("rice.png", png())})
            self.assertEqual(response.status_code, 503)
            self.assertEqual(response.headers["Retry-After"], "2")
        self.assertEqual(self.client.post("/predict", files={"file": ("rice.png", png())}).status_code, 200)
        self.assert_no_uploads()

    def test_oversized_file_and_declared_request_are_413(self):
        response = self.client.post("/predict", files={"file": ("rice.jpg", b"x" * (main.MAX_UPLOAD_BYTES + 1))})
        self.assertEqual(response.status_code, 413)
        self.assert_no_uploads()
        response = self.client.post("/predict", content=b"x", headers={"Content-Length": str(main.MAX_UPLOAD_BYTES * 10)})
        self.assertEqual(response.status_code, 413)
        self.assert_no_uploads()

    def test_chunked_request_is_bounded_before_multipart_parser(self):
        def chunks():
            for _ in range(17):
                yield b"x" * 1024 * 1024
        response = self.client.post("/predict", content=chunks(), headers={"Content-Type": "multipart/form-data; boundary=test"})
        self.assertEqual(response.status_code, 413)
        self.assert_no_uploads()

    def test_inference_failure_and_invalid_probabilities_are_contained(self):
        for output in (
            np.array([[np.nan, 0.5, 0.5]]), np.array([[1.2, -0.1, -0.1]]),
            np.array([[0.1, 0.1]]), np.array([[0.5 + 1j, 0.5 - 1j, 0]]),
            np.array([[True, False, False]]),
        ):
            with self.subTest(output=output), patch.object(main, "model", return_value=output):
                response = self.client.post("/predict", files={"file": ("rice.png", png())})
                self.assertEqual(response.status_code, 500)
                self.assert_no_uploads()
        with patch.object(main, "classify_image", side_effect=RuntimeError("inference failed")):
            self.assertEqual(self.client.post("/predict", files={"file": ("rice.png", png())}).status_code, 500)
        self.assert_no_uploads()
        self.assertEqual(self.client.get("/health").status_code, 200)
        main.database.add_prediction.assert_not_called()

    def test_database_failure_does_not_lose_prediction_or_crash_server(self):
        with patch.object(main.database, "add_prediction", side_effect=OSError("database offline")):
            response = self.client.post("/predict", files={"file": ("rice.png", png())})
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json()["history_saved"])
        self.assert_no_uploads()
        self.assertEqual(self.client.get("/health").status_code, 200)

    def test_database_recovers_after_startup_failure(self):
        main.DATABASE_AVAILABLE = False
        main.DATABASE_RETRY_AT = 0
        with patch.object(main.database, "init_database", side_effect=OSError("offline")):
            self.assertEqual(self.client.get("/ready").status_code, 503)
        main.DATABASE_RETRY_AT = 0
        self.assertEqual(self.client.get("/ready").status_code, 200)

    def test_busy_database_is_retryable_without_marking_it_offline(self):
        with patch.object(main.database, "list_predictions", side_effect=main.database.DatabaseBusyError("Database is busy")):
            response = self.client.get("/history")
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.headers["Retry-After"], "2")
        self.assertTrue(main.DATABASE_AVAILABLE)

    def test_parallel_database_recovery_does_not_wait_on_a_worker_lock(self):
        main.DATABASE_AVAILABLE = False
        with main.database_lock:
            self.assertFalse(main.init_database())
        main.database.init_database.assert_called_once()  # only the lifespan call

    def test_liveness_remains_available_when_worker_threads_are_full(self):
        async def scenario():
            limiter = anyio.to_thread.current_default_thread_limiter()
            original_tokens = limiter.total_tokens
            limiter.total_tokens = 1
            await limiter.acquire()
            try:
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=main.app), base_url="http://test") as client:
                    response = await asyncio.wait_for(client.get("/health"), timeout=1)
                    self.assertEqual(response.status_code, 200)
            finally:
                limiter.release()
                limiter.total_tokens = original_tokens
        asyncio.run(scenario())

    def test_trailing_slash_prediction_keeps_the_normal_image_limit(self):
        body = png() + b"padding" * 10000
        response = self.client.post("/predict/", files={"file": ("rice.png", body)})
        self.assertEqual(response.status_code, 200, response.text)
        self.assert_no_uploads()

    def test_ready_checks_components_and_health_remains_live(self):
        self.assertEqual(self.client.get("/ready").status_code, 200)
        with patch.object(main, "model", None):
            self.assertEqual(self.client.get("/ready").status_code, 503)
            self.assertEqual(self.client.get("/health").status_code, 200)
        with patch.object(main.database, "check_connection", side_effect=OSError("offline")):
            self.assertEqual(self.client.get("/ready").status_code, 503)

    def test_history_rejects_invalid_fields(self):
        for entry in ({"confidence": -1}, {"confidence": 101}, {"confidence": "NaN"}, {"imagePath": {"nested": True}}, {"createdAt": "invalid"}, {"predictedGrade": "x" * 101}):
            with self.subTest(entry=entry):
                self.assertEqual(self.client.post("/history", json=entry).status_code, 422)
        main.database.add_prediction.assert_not_called()
        response = self.client.post("/history", content='{"confidence": NaN}', headers={"Content-Type": "application/json"})
        self.assertEqual(response.status_code, 422)
        self.assertIn("detail", response.json())

    def test_history_normalizes_timestamp_and_bounds_request(self):
        response = self.client.post("/history", json={"predictedGrade": "Premium", "confidence": 90, "createdAt": "2026-10-21T08:00:00+08:00"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(main.database.add_prediction.call_args.args[0]["created_at"], "2026-10-21T00:00:00+00:00")
        self.assertEqual(self.client.post("/history", content=b"x" * (65536 + 1)).status_code, 413)
        self.assertEqual(self.client.get("/history?limit=201").status_code, 422)

    def test_invalid_metrics_json_does_not_crash(self):
        path = Path(self.directory.name) / "metrics.json"
        for body in ('{"accuracy":NaN}', '{"accuracy":1e999}', '[]', '{broken', '\ufeff{}'):
            path.write_text(body, encoding="utf-8")
            with patch.object(main, "METRICS_PATH", path):
                response = self.client.get("/metrics")
                self.assertEqual(response.status_code, 200)
                self.assertIsNone(response.json()["accuracy"])

    def test_static_spa_and_api_routes(self):
        directory = Path(self.directory.name) / "static"
        directory.mkdir()
        (directory / "index.html").write_text("<html>Rice app</html>", encoding="utf-8")
        with patch.object(main, "STATIC_DIR", directory):
            self.assertIn("Rice app", self.client.get("/").text)
            self.assertIn("Rice app", self.client.get("/scan").text)
            self.assertEqual(self.client.get("/assets/missing.js").status_code, 404)
            self.assertEqual(self.client.get("/history/unknown").status_code, 404)
            self.assertEqual(self.client.get("/health").json()["status"], "ok")

    def test_busy_predictions_are_rejected_while_health_responds(self):
        started, release = threading.Event(), threading.Event()

        def blocked_decode(path):
            started.set()
            if not release.wait(5):
                raise RuntimeError("test timed out")
            return np.zeros((224, 224, 3), dtype=np.uint8)

        async def scenario():
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=main.app), base_url="http://test") as client:
                first = asyncio.create_task(client.post("/predict", files={"file": ("rice.png", png())}))
                try:
                    self.assertTrue(await asyncio.to_thread(started.wait, 3))
                    self.assertEqual((await client.get("/health")).status_code, 200)
                    busy = await client.post("/predict", files={"file": ("rice.png", png())})
                    self.assertEqual(busy.status_code, 503)
                    self.assertEqual(busy.headers["Retry-After"], "2")
                finally:
                    release.set()
                self.assertEqual((await first).status_code, 200)

        with patch.object(main, "load_inference_image", side_effect=blocked_decode):
            asyncio.run(scenario())
        self.assert_no_uploads()

    def test_model_contract_rejects_mismatched_labels_or_input(self):
        self.assertIsNone(main.model_rejection(FakeModel(), main.CLASS_NAMES))
        self.assertIsNotNone(main.model_rejection(FakeModel(), list(reversed(main.CLASS_NAMES))))
        invalid = FakeModel()
        invalid.input_shape = (None, 128, 128, 3)
        self.assertIsNotNone(main.model_rejection(invalid, main.CLASS_NAMES))


class RealModelTests(unittest.TestCase):
    def test_bundled_model_runs_through_predict_endpoint(self):
        # Use the shipped weights, decoder, model loader and response path. The
        # database alone is isolated so verification cannot alter real history.
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(main, "UPLOADS_DIR", Path(directory) / "uploads"), \
                patch.object(main.database, "init_database"), \
                patch.object(main.database, "add_prediction", return_value=1):
            main.DATABASE_AVAILABLE = False
            main.DATABASE_RETRY_AT = 0
            with TestClient(main.app) as client:
                self.assertIsNotNone(main.model, main.MODEL_LOAD_ERROR)
                response = client.post("/predict", files={"file": ("serving-check.png", png())})
                self.assertEqual(response.status_code, 200, response.text)
                self.assertIn(response.json()["predicted_grade"], main.CLASS_NAMES)
                self.assertGreaterEqual(response.json()["confidence"], 0)
                self.assertLessEqual(response.json()["confidence"], 100)
                self.assertTrue(response.json()["history_saved"])
            self.assertFalse(list(Path(directory).rglob("upload_*")))


class ModelLoadingTests(unittest.TestCase):
    def test_artifact_permission_failure_does_not_stop_the_server(self):
        unavailable = Mock(spec=Path)
        unavailable.is_file.side_effect = PermissionError("model volume is not readable")
        with patch.object(main, "MODEL_PATH", unavailable):
            model, message = main.load_model()
        self.assertIsNone(model)
        self.assertIn("permissions", message)

    def test_startup_refuses_a_model_that_fails_real_inference(self):
        with tempfile.TemporaryDirectory() as directory:
            model_path = Path(directory) / "rice.keras"
            model_path.write_bytes(b"stubbed weight file")
            names_path = Path(directory) / "class_names.json"
            names_path.write_text('["Premium","Well-Milled","Poor-Quality-Rice-Mix"]', encoding="utf-8")
            with patch.object(main, "MODEL_PATH", model_path), patch.object(main, "CLASS_NAMES_PATH", names_path):
                for probabilities in (np.array([[np.nan, 0.5, 0.5]]), np.array([[1.5, -0.5, 0]])):
                    class InvalidModel(FakeModel):
                        def __call__(self, image, training=False):
                            return probabilities
                    with patch.object(main.tf.keras.models, "load_model", return_value=InvalidModel()):
                        model, message = main.load_model()
                        self.assertIsNone(model)
                        self.assertIn("startup inference", message)

    def test_missing_corrupt_and_pointer_model_artifacts_are_not_served(self):
        with tempfile.TemporaryDirectory() as directory:
            model_path = Path(directory) / "rice.keras"
            names_path = Path(directory) / "class_names.json"
            with patch.object(main, "MODEL_PATH", model_path), patch.object(main, "CLASS_NAMES_PATH", names_path):
                self.assertIsNone(main.load_model()[0])
                model_path.write_bytes(b"invalid model")
                self.assertIsNotNone(main.load_model()[1])
                names_path.write_text('["Premium","Well-Milled","Poor-Quality-Rice-Mix"]', encoding="utf-8")
                self.assertIsNotNone(main.load_model()[1])
                model_path.write_bytes(b"version https://git-lfs.github.com/spec/v1\noid sha256:test")
                self.assertIn("Git LFS", main.load_model()[1])


class UploadCancellationTests(unittest.IsolatedAsyncioTestCase):
    async def test_cancelled_upload_is_closed_and_removed(self):
        class CancelledFile:
            filename = "rice.png"
            reads = 0
            closed = False

            async def read(self, size):
                self.reads += 1
                if self.reads == 1:
                    return b"partial image"
                raise asyncio.CancelledError

            async def close(self):
                self.closed = True

        with tempfile.TemporaryDirectory() as directory, patch.object(main, "UPLOADS_DIR", Path(directory)):
            file = CancelledFile()
            with self.assertRaises(asyncio.CancelledError):
                await main.save_upload(file)
            self.assertTrue(file.closed)
            self.assertFalse(list(Path(directory).iterdir()))

    async def test_close_failure_also_removes_completed_upload(self):
        class CloseFailureFile:
            filename = "rice.png"
            reads = 0

            async def read(self, size):
                self.reads += 1
                return b"image bytes" if self.reads == 1 else b""

            async def close(self):
                raise asyncio.CancelledError

        with tempfile.TemporaryDirectory() as directory, patch.object(main, "UPLOADS_DIR", Path(directory)):
            with self.assertRaises(asyncio.CancelledError):
                await main.save_upload(CloseFailureFile())
            self.assertFalse(list(Path(directory).iterdir()))

    async def test_body_deadline_does_not_reset_after_each_chunk(self):
        async def downstream(scope, receive, send):
            self.fail("An expired multipart upload must not reach the parser.")

        middleware = main.RequestLimitsMiddleware(downstream)
        received = []
        calls = 0

        async def receive():
            nonlocal calls
            calls += 1
            return {"type": "http.request", "body": b"x", "more_body": True}

        async def send(message):
            received.append(message)

        # Time advances only at explicit body deadline checks. No wall-clock wait.
        clock = iter((0, 0, 31))
        class FakeLoop:
            def time(self):
                return next(clock)

        async def direct_wait(awaitable, timeout):
            return await awaitable

        scope = {"type": "http", "method": "POST", "path": "/predict", "headers": []}
        with patch("app.middleware.asyncio.get_running_loop", return_value=FakeLoop()), \
                patch("app.middleware.asyncio.wait_for", side_effect=direct_wait):
            await middleware(scope, receive, send)
        self.assertEqual(calls, 1)
        self.assertEqual(received[0]["status"], 408)


if __name__ == "__main__":
    unittest.main()
