"""Production entry point, including Railway's assigned HTTP port.

One worker holds one model in memory. Scaling workers multiplies TensorFlow's
memory footprint; tune resources using measured load before changing that.
"""

import os

import uvicorn


def main():
    raw_port = os.getenv("PORT", "8000")
    try:
        port = int(raw_port)
        if not 1 <= port <= 65535:
            raise ValueError
    except ValueError as error:
        raise SystemExit("PORT must be a number from 1 to 65535.") from error

    os.environ.setdefault("TF_NUM_INTRAOP_THREADS", "1")
    os.environ.setdefault("TF_NUM_INTEROP_THREADS", "1")
    os.environ.setdefault("OMP_NUM_THREADS", "1")
    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=port,
        workers=1,
        limit_concurrency=32,
        timeout_keep_alive=5,
        timeout_graceful_shutdown=30,
    )


if __name__ == "__main__":
    main()
