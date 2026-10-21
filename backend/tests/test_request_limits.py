import asyncio
import io
import threading
import unittest
from unittest.mock import patch

from starlette.responses import JSONResponse

from app.middleware import RequestLimitsMiddleware


class RequestStorageTests(unittest.IsolatedAsyncioTestCase):
    async def request(self, middleware, path="/predict", body=b"image"):
        sent = []
        scope = {"type": "http", "method": "POST", "path": path, "headers": []}
        async def receive():
            return {"type": "http.request", "body": body, "more_body": False}
        async def send(message):
            sent.append(message)
        await middleware(scope, receive, send)
        return sent

    async def test_disk_unavailable_is_retryable_and_does_not_strand_prediction_slot(self):
        async def downstream(scope, receive, send):
            await receive()
            await JSONResponse({"ok": True})(scope, receive, send)
        middleware = RequestLimitsMiddleware(downstream)
        with patch("app.middleware.SpooledTemporaryFile", side_effect=OSError("disk full")):
            failed = await self.request(middleware)
            self.assertEqual(failed[0]["status"], 503)
        recovered = await self.request(middleware)
        self.assertEqual(recovered[0]["status"], 200)

    async def test_slow_spooled_disk_write_does_not_block_liveness(self):
        started, release = threading.Event(), threading.Event()
        class SlowFile(io.BytesIO):
            def write(self, data):
                if len(data) > 1024 * 1024:
                    started.set()
                    if not release.wait(5):
                        raise OSError("test disk timed out")
                return super().write(data)
        async def downstream(scope, receive, send):
            await JSONResponse({"ok": True})(scope, receive, send)
        middleware = RequestLimitsMiddleware(downstream)
        with patch("app.middleware.SpooledTemporaryFile", side_effect=lambda **options: SlowFile()):
            upload = asyncio.create_task(self.request(middleware, body=b"x" * (1024 * 1024 + 1)))
            try:
                self.assertTrue(await asyncio.to_thread(started.wait, 2))
                health = await asyncio.wait_for(self.request(middleware, path="/health", body=b""), timeout=1)
                self.assertEqual(health[0]["status"], 200)
            finally:
                release.set()
            self.assertEqual((await upload)[0]["status"], 200)


if __name__ == "__main__":
    unittest.main()
