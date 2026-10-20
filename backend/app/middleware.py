"""Bound request storage and reject excess predictions before decoding images."""

import asyncio
from tempfile import SpooledTemporaryFile
from threading import BoundedSemaphore

from starlette.responses import JSONResponse


class RequestLimitsMiddleware:
    def __init__(self, app, max_upload_bytes=15 * 1024 * 1024):
        self.app = app
        self.max_upload_bytes = max_upload_bytes
        # One model per worker, one image being decoded/inferred at a time.
        # Reject rather than queue large multipart bodies in memory or on disk.
        self.prediction_slot = BoundedSemaphore(1)

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)

        prediction = scope["path"] == "/predict" and scope["method"] == "POST"
        acquired = prediction and self.prediction_slot.acquire(blocking=False)
        if prediction and not acquired:
            return await JSONResponse(
                {"detail": "The classifier is busy. Please try again shortly."},
                status_code=503,
                headers={"Retry-After": "2"},
            )(scope, receive, send)

        try:
            # Multipart overhead gets a separate allowance; the endpoint still
            # enforces the exact 15 MiB file limit. Other writes have a 64 KiB cap.
            limit = self.max_upload_bytes + 64 * 1024 if prediction else 64 * 1024
            headers = dict(scope.get("headers", []))
            length = headers.get(b"content-length")
            if length is not None:
                try:
                    length = int(length)
                    if length < 0:
                        raise ValueError
                except ValueError:
                    return await JSONResponse(
                        {"detail": "Invalid Content-Length header."}, status_code=400
                    )(scope, receive, send)
                if length > limit:
                    return await self.too_large(scope, receive, send)

            # Validate chunked bodies too, before Starlette's multipart parser
            # creates temp files. Spool above 1 MiB and always close on failure.
            with SpooledTemporaryFile(max_size=1024 * 1024) as body:
                size = 0
                deadline = asyncio.get_running_loop().time() + 30
                while True:
                    try:
                        remaining = deadline - asyncio.get_running_loop().time()
                        if remaining <= 0:
                            raise TimeoutError
                        message = await asyncio.wait_for(receive(), timeout=remaining)
                    except TimeoutError:
                        return await JSONResponse(
                            {"detail": "Request body timed out."}, status_code=408
                        )(scope, receive, send)
                    if message["type"] == "http.disconnect":
                        return
                    chunk = message.get("body", b"")
                    size += len(chunk)
                    if size > limit:
                        return await self.too_large(scope, receive, send)
                    body.write(chunk)
                    if not message.get("more_body", False):
                        break
                body.seek(0)
                replay_complete = False

                async def replay():
                    nonlocal replay_complete
                    if replay_complete:
                        return await receive()
                    chunk = body.read(64 * 1024)
                    more = body.tell() < size
                    replay_complete = not more
                    return {"type": "http.request", "body": chunk, "more_body": more}

                await self.app(scope, replay, send)
        finally:
            if acquired:
                self.prediction_slot.release()

    async def too_large(self, scope, receive, send):
        await JSONResponse(
            {"detail": "Request is too large. Images must be at most 15 MB."},
            status_code=413,
        )(scope, receive, send)
