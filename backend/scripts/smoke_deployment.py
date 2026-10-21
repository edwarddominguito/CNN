"""Check a running deployment over HTTP using only the Python standard library.

The default checks are read-only. --exercise-prediction submits one synthetic PNG
and records one test prediction in that deployment's history; use it in CI/staging.
This verifies serving and response contracts, not model accuracy.
"""

import argparse
import json
import math
import struct
import time
import urllib.error
import urllib.request
import zlib
from html.parser import HTMLParser
from urllib.parse import urlsplit


def request(base_url, path, *, data=None, headers=None, timeout=10):
    req = urllib.request.Request(base_url + path, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return response.status, response.headers, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.headers, error.read()


def get_json(base_url, path):
    status, _, body = request(base_url, path)
    if status != 200:
        raise RuntimeError(f"{path} returned HTTP {status}.")
    return json.loads(body)


class WebAssets(HTMLParser):
    """Read the local JavaScript and CSS referenced by the built Vite page."""

    def __init__(self):
        super().__init__()
        self.assets = {}

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag == "script":
            source = attributes.get("src")
            kind = "javascript"
        elif tag == "link" and "stylesheet" in (attributes.get("rel") or "").split():
            source = attributes.get("href")
            kind = "css"
        else:
            return
        if not source:
            return
        parsed = urlsplit(source)
        if not parsed.scheme and not parsed.netloc and parsed.path.startswith("/assets/"):
            self.assets[source] = kind


def check_web_client(base_url):
    status, headers, body = request(base_url, "/")
    if status != 200 or "text/html" not in headers.get("Content-Type", "") or b"<html" not in body.lower():
        raise RuntimeError("The built React application is not being served at /.")
    page = WebAssets()
    page.feed(body.decode("utf-8"))
    if "javascript" not in page.assets.values():
        raise RuntimeError("The web page does not reference a local application JavaScript bundle.")
    for path, kind in page.assets.items():
        status, headers, body = request(base_url, path)
        content_type = headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        allowed = {"text/css"} if kind == "css" else {"text/javascript", "application/javascript"}
        if status != 200 or not body or content_type not in allowed:
            raise RuntimeError(f"The web {kind} asset {path} is missing or has an invalid content type.")
    for path in ("/assets/__deployment_smoke_missing__.js", "/predict/__deployment_smoke_missing__"):
        if request(base_url, path)[0] != 404:
            raise RuntimeError(f"Missing resource {path} must return HTTP 404.")


def wait_until_ready(base_url, wait_seconds):
    deadline = time.monotonic() + wait_seconds
    last_problem = "not contacted"
    while True:
        try:
            status, _, _ = request(base_url, "/ready")
            if status == 200:
                return
            last_problem = f"HTTP {status}"
        except (OSError, urllib.error.URLError) as error:
            last_problem = type(error).__name__
        if time.monotonic() >= deadline:
            raise RuntimeError(f"/ready did not become ready: {last_problem}.")
        time.sleep(min(2, max(0, deadline - time.monotonic())))


def synthetic_png():
    """A small valid image for a serving smoke test, with no dataset dependency."""
    def chunk(kind, data):
        return (
            struct.pack("!I", len(data))
            + kind
            + data
            + struct.pack("!I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    size = 64
    pixels = b"".join(
        b"\x00"
        + b"".join(bytes((160 + (x + y) % 80, 150 + x % 80, 120 + y % 80)) for x in range(size))
        for y in range(size)
    )
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack("!IIBBBBB", size, size, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(pixels))
        + chunk(b"IEND", b"")
    )


def exercise_prediction(base_url, classes):
    previous_ids = {row.get("id") for row in get_json(base_url, "/history?limit=200")}
    boundary = "rice-deployment-smoke"
    body = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="file"; filename="deployment-smoke.png"\r\n'
        "Content-Type: image/png\r\n\r\n"
    ).encode() + synthetic_png() + f"\r\n--{boundary}--\r\n".encode()
    status, _, response = request(
        base_url,
        "/predict",
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        timeout=60,
    )
    if status != 200:
        raise RuntimeError(f"/predict returned HTTP {status}.")
    result = json.loads(response)
    if result.get("predicted_grade") not in classes:
        raise RuntimeError("/predict returned an unknown class.")
    confidence = result.get("confidence")
    if isinstance(confidence, bool) or not isinstance(confidence, (int, float)):
        raise RuntimeError("/predict confidence is not a number.")
    if not math.isfinite(confidence) or not 0 <= confidence <= 100:
        raise RuntimeError("/predict confidence is outside 0..100.")
    if result.get("history_saved") is not True:
        raise RuntimeError("/predict did not confirm that its history entry was saved.")
    history = get_json(base_url, "/history?limit=200")
    if not any(
        row.get("id") not in previous_ids
        and row.get("predictedGrade") == result["predicted_grade"]
        and row.get("confidence") == confidence
        for row in history
    ):
        raise RuntimeError("The prediction was not readable from persisted history.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="Deployment URL, such as http://127.0.0.1:8000")
    parser.add_argument("--wait", type=int, default=0, help="Seconds to wait for /ready")
    parser.add_argument("--exercise-prediction", action="store_true")
    args = parser.parse_args()
    base_url = args.url.rstrip("/")
    if not base_url.startswith(("http://", "https://")):
        parser.error("--url must start with http:// or https://")
    if args.wait < 0:
        parser.error("--wait must be nonnegative")

    wait_until_ready(base_url, args.wait)
    if get_json(base_url, "/health").get("status") != "ok":
        raise RuntimeError("/health did not report ok.")
    metrics = get_json(base_url, "/metrics")
    if not metrics.get("model_available") or not metrics.get("database_available"):
        raise RuntimeError("The model or history database is unavailable.")
    classes = metrics.get("classes")
    if not isinstance(classes, list) or not classes:
        raise RuntimeError("/metrics did not return the model classes.")
    history = get_json(base_url, "/history?limit=1")
    if not isinstance(history, list) or len(history) > 1:
        raise RuntimeError("/history returned an invalid page.")
    check_web_client(base_url)
    if args.exercise_prediction:
        exercise_prediction(base_url, classes)
    print("Deployment smoke checks passed" + (" (one synthetic prediction saved)." if args.exercise_prediction else "."))


if __name__ == "__main__":
    main()
