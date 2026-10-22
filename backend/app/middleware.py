"""Bound request storage and reject excess predictions before decoding images."""

import asyncio
import ipaddress
import math
import time
from collections import OrderedDict, deque
from tempfile import SpooledTemporaryFile
from threading import BoundedSemaphore

from starlette.responses import JSONResponse
from starlette.concurrency import run_in_threadpool
from starlette.exceptions import HTTPException

STORAGE_ERROR_DETAIL = "Temporary upload storage is unavailable. Please try again later."
TOO_MANY_REQUESTS_DETAIL = "Too many requests. Please wait a moment and try again."


def client_address(scope):
    """The caller's IP address, as the rate limits count callers.

    Railway's edge sets X-Real-IP to the client's address and replaces any copy the
    client sent; local runs have no edge, so the socket peer is used. IPv6 callers
    are counted per /64, the block one device or home network receives, so cycling
    through addresses inside it does not reset a limit.
    """
    peer = (scope.get("client") or ("unknown",))[0]
    forwarded = dict(scope.get("headers", [])).get(b"x-real-ip", b"").decode("latin-1").strip()
    for candidate in (forwarded, peer):
        try:
            address = ipaddress.ip_address(candidate)
            if address.version == 6 and address.ipv4_mapped:
                address = address.ipv4_mapped
            if address.version == 6:
                return str(ipaddress.IPv6Network((address, 64), strict=False))
            return str(address)
        except ValueError:
            continue
    return peer


class RateLimiter:
    """Allow `limit` requests per caller in any `window` seconds (a sliding window).

    One API worker serves the app, so this process sees every request. Only the
    most recently active callers are remembered, bounding memory however many
    addresses send requests.
    """

    def __init__(self, limit, window=60.0, max_callers=4096, clock=time.monotonic):
        self.limit = limit
        self.window = window
        self.max_callers = max_callers
        self.clock = clock
        self.callers = OrderedDict()  # caller -> times of its allowed requests

    def retry_after(self, caller):
        """Count one request: 0 if it may proceed, else whole seconds to wait."""
        now = self.clock()
        times = self.callers.pop(caller, None) or deque()
        while times and times[0] <= now - self.window:
            times.popleft()
        self.callers[caller] = times  # re-inserted as the most recently active
        if len(times) >= self.limit:
            return max(1, math.ceil(times[0] + self.window - now))
        times.append(now)
        while len(self.callers) > self.max_callers:
            self.callers.popitem(last=False)
        return 0


class RateLimitMiddleware:
    """Refuse a caller's excess requests to a limited path before reading any body."""

    def __init__(self, app, limiters):
        self.app = app
        # Path -> RateLimiter. Looked up per request, so tests can swap entries.
        self.limiters = limiters

    async def __call__(self, scope, receive, send):
        limiter = self.limiters.get(scope["path"].rstrip("/")) if scope["type"] == "http" else None
        if limiter is not None:
            wait = limiter.retry_after(client_address(scope))
            if wait:
                return await JSONResponse(
                    {"detail": TOO_MANY_REQUESTS_DETAIL},
                    status_code=429,
                    headers={"Retry-After": str(wait)},
                )(scope, receive, send)
        await self.app(scope, receive, send)


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

        prediction = scope["path"].rstrip("/") == "/predict" and scope["method"] == "POST"
        acquired = prediction and self.prediction_slot.acquire(blocking=False)
        if prediction and not acquired:
            return await JSONResponse(
                {"detail": "The classifier is busy. Please try again shortly."},
                status_code=503,
                headers={"Retry-After": "2"},
            )(scope, receive, send)

        downstream_started = False
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
                    if size > 1024 * 1024:
                        await run_in_threadpool(body.write, chunk)
                    else:
                        body.write(chunk)
                    if not message.get("more_body", False):
                        break
                if size > 1024 * 1024:
                    await run_in_threadpool(body.seek, 0)
                else:
                    body.seek(0)
                replay_complete = False

                async def replay():
                    nonlocal replay_complete
                    if replay_complete:
                        return await receive()
                    try:
                        if size > 1024 * 1024:
                            chunk = await run_in_threadpool(body.read, 64 * 1024)
                        else:
                            chunk = body.read(64 * 1024)
                    except OSError as error:
                        # This runs inside Starlette's request parser, whose
                        # exception handler preserves this retryable status.
                        raise HTTPException(
                            status_code=503, detail=STORAGE_ERROR_DETAIL,
                            headers={"Retry-After": "2"},
                        ) from error
                    more = body.tell() < size
                    replay_complete = not more
                    return {"type": "http.request", "body": chunk, "more_body": more}

                downstream_started = True
                await self.app(scope, replay, send)
        except OSError:
            if downstream_started:
                raise
            # Disk exhaustion/permissions must not leak a temporary handle or
            # strand the classifier slot. A later request can recover normally.
            return await JSONResponse(
                {"detail": STORAGE_ERROR_DETAIL},
                status_code=503,
                headers={"Retry-After": "2"},
            )(scope, receive, send)
        finally:
            if acquired:
                self.prediction_slot.release()

    async def too_large(self, scope, receive, send):
        await JSONResponse(
            {"detail": "Request is too large. Images must be at most 15 MB."},
            status_code=413,
        )(scope, receive, send)
