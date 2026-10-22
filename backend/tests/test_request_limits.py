import asyncio
import io
import threading
import unittest
from unittest.mock import patch

from starlette.responses import JSONResponse

from app.middleware import RateLimiter, RateLimitMiddleware, RequestLimitsMiddleware, client_address


class RateLimiterTests(unittest.TestCase):
    def test_sliding_window_allows_the_limit_then_reports_the_wait(self):
        now = [0.0]
        limiter = RateLimiter(2, window=60, clock=lambda: now[0])
        self.assertEqual(limiter.retry_after("a"), 0)
        now[0] = 10
        self.assertEqual(limiter.retry_after("a"), 0)
        self.assertEqual(limiter.retry_after("a"), 50)
        self.assertEqual(limiter.retry_after("b"), 0)  # callers are counted separately
        now[0] = 60.5  # the first request has left the window
        self.assertEqual(limiter.retry_after("a"), 0)
        self.assertEqual(limiter.retry_after("a"), 10)

    def test_memory_is_bounded_by_dropping_the_least_recent_caller(self):
        limiter = RateLimiter(1, max_callers=2, clock=lambda: 0.0)
        for caller in ("a", "b", "a", "c"):
            limiter.retry_after(caller)
        self.assertEqual(list(limiter.callers), ["a", "c"])

    def test_client_address_prefers_railway_header_and_groups_ipv6(self):
        def scope(real_ip=None, peer="10.0.0.5"):
            headers = [(b"x-real-ip", real_ip.encode())] if real_ip else []
            return {"client": (peer, 1234), "headers": headers}

        self.assertEqual(client_address(scope("198.51.100.7")), "198.51.100.7")
        self.assertEqual(client_address(scope()), "10.0.0.5")
        self.assertEqual(client_address(scope("not an address")), "10.0.0.5")
        self.assertEqual(client_address(scope("::ffff:198.51.100.7")), "198.51.100.7")
        self.assertEqual(client_address(scope("2001:db8:1:2:aaaa::1")), client_address(scope("2001:db8:1:2:bbbb::9")))
        self.assertEqual(client_address(scope("2001:db8:1:2::1")), "2001:db8:1:2::/64")
        self.assertNotEqual(client_address(scope("2001:db8:1:3::1")), client_address(scope("2001:db8:1:2::1")))
        self.assertEqual(client_address({"client": ("testclient", 50000), "headers": []}), "testclient")


class RateLimitMiddlewareTests(unittest.IsolatedAsyncioTestCase):
    async def test_excess_request_is_refused_without_reading_its_body(self):
        reached = []
        async def downstream(scope, receive, send):
            reached.append(scope["path"])
            await JSONResponse({"ok": True})(scope, receive, send)
        middleware = RateLimitMiddleware(downstream, {"/predict": RateLimiter(1)})

        async def call(path):
            sent = []
            async def receive():
                self.fail("A refused request must not have its body read.")
            async def send(message):
                sent.append(message)
            await middleware({"type": "http", "method": "POST", "path": path, "headers": [], "client": ("192.0.2.1", 1)}, receive, send)
            return sent

        self.assertEqual((await call("/predict"))[0]["status"], 200)
        refused = await call("/predict/")
        self.assertEqual(refused[0]["status"], 429)
        self.assertIn((b"retry-after", b"60"), refused[0]["headers"])
        self.assertEqual((await call("/health"))[0]["status"], 200)
        self.assertEqual(reached, ["/predict", "/health"])


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
