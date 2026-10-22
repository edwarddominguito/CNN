import asyncio
import hashlib
import json
import logging
import math
import os
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from threading import Lock
from uuid import uuid4

from app import database

# Bound TensorFlow's CPU thread allocation on small hosting instances. Launchers
# select the Python environment; importing this app must never replace a process.
os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
os.environ.setdefault("TF_NUM_INTRAOP_THREADS", "1")
os.environ.setdefault("TF_NUM_INTEROP_THREADS", "1")
os.environ.setdefault("OMP_NUM_THREADS", "1")

import numpy as np
import tensorflow as tf
from fastapi import Depends, FastAPI, File, Header, HTTPException, Query, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from ml.image_preprocessing import CLASS_NAMES, IMAGE_SIZE, load_inference_image
from pydantic import BaseModel, ConfigDict, Field
from starlette.concurrency import run_in_threadpool

from app.middleware import RateLimiter, RateLimitMiddleware, RequestLimitsMiddleware
from app.paths import BACKEND_DIR, MODEL_DIR, UPLOADS_DIR

MODEL_PATH = MODEL_DIR / "rice_cnn_model.keras"
CLASS_NAMES_PATH = MODEL_DIR / "class_names.json"
METRICS_PATH = MODEL_DIR / "metrics.json"
STATIC_DIR = BACKEND_DIR / "static"

MAX_UPLOAD_BYTES = 15 * 1024 * 1024
UPLOAD_CHUNK_BYTES = 1024 * 1024
IMAGE_SUFFIXES = {".bmp", ".gif", ".jpeg", ".jpg", ".png", ".webp"}
# Each app installation sends a random X-Client-Id. History is stored and matched
# by its SHA-256, so the table holds no ID that could be replayed to the API.
CLIENT_ID_PATTERN = r"^[A-Za-z0-9_-]{32,128}$"
# Load failures name artifact files and repair steps. The server log keeps those;
# clients only learn that grading is unavailable.
MODEL_UNAVAILABLE = "The classifier is not available right now. Please try again later."
# Fields train_5fold.py writes into metrics.json and /metrics forwards unchanged.
METRIC_FIELDS = (
    "accuracy", "precision", "recall", "f1_score",
    "accuracy_std", "precision_std", "recall_std", "f1_score_std",
    "per_class", "evaluation_method", "folds", "evaluation_images", "generated_at",
)

logger = logging.getLogger("rice_backend")
model_lock = Lock()
database_lock = Lock()
DATABASE_AVAILABLE = False
DATABASE_RETRY_AT = 0.0
model = None
MODEL_LOAD_ERROR = None


@asynccontextmanager
async def lifespan(application):
    global model, MODEL_LOAD_ERROR
    model, MODEL_LOAD_ERROR = await run_in_threadpool(load_model)
    await run_in_threadpool(init_database)
    yield


def per_minute(name, default):
    """A requests-per-minute limit from the environment. 0 turns the limit off."""
    value = os.getenv(name, "").strip() or str(default)
    if not (value.isascii() and value.isdigit()):
        raise RuntimeError(f"{name} must be a whole number of requests per minute (0 turns it off).")
    return int(value)


# Counted per caller IP (app.middleware.client_address) before a body is read.
# Generous enough for several people testing from one shared network.
RATE_LIMITS = {
    path: RateLimiter(limit)
    for path, limit in (
        ("/predict", per_minute("PREDICT_RATE_LIMIT_PER_MINUTE", 30)),
        ("/history", per_minute("HISTORY_RATE_LIMIT_PER_MINUTE", 60)),
    )
    if limit
}

app = FastAPI(title="Rice CNN Backend", lifespan=lifespan)
app.add_middleware(RequestLimitsMiddleware, max_upload_bytes=MAX_UPLOAD_BYTES)
app.add_middleware(RateLimitMiddleware, limiters=RATE_LIMITS)
# The React client is served from this origin and the mobile apps are not
# browsers, so neither needs CORS. Loopback origins keep Flutter web runs
# (mobile_app/run_chrome.bat, on a random localhost port) working. A web client
# hosted anywhere else must be listed in CORS_ORIGINS.
app.add_middleware(
    CORSMiddleware,
    allow_origins=[origin.strip() for origin in os.getenv("CORS_ORIGINS", "").split(",") if origin.strip()],
    allow_origin_regex=r"http://(localhost|127\.0\.0\.1)(:\d{1,5})?",
    allow_credentials=False,
    allow_methods=["GET", "POST", "DELETE"],
    allow_headers=["Content-Type", "X-Client-Id"],
)


@app.exception_handler(RequestValidationError)
async def validation_error_handler(request, error):
    # Do not echo arbitrary input bytes or non-finite JSON numbers into an error
    # response; those can themselves make JSON serialization fail.
    return JSONResponse({"detail": [
        {key: item[key] for key in ("type", "loc", "msg") if key in item}
        for item in error.errors()
    ]}, status_code=422)


def read_json(path, fallback):
    """Read a JSON file, or fall back if it is missing, damaged or unreadable.

    ValueError covers both json.JSONDecodeError and the UnicodeDecodeError a
    non-UTF-8 file raises. Missing or damaged metadata must not stop the server.
    """
    try:
        # JSON NaN/Infinity are accepted by Python but cannot be sent as JSON by
        # Starlette. Treat damaged metric values as unavailable.
        return json.loads(
            path.read_text(encoding="utf-8"),
            parse_constant=lambda value: None,
            parse_float=lambda value: safe_float(value, None),
        )
    except FileNotFoundError:
        return fallback
    except (OSError, ValueError, RecursionError):
        logger.exception("Could not read JSON file: %s", path)
        return fallback


def init_database():
    global DATABASE_AVAILABLE, DATABASE_RETRY_AT
    if DATABASE_AVAILABLE:
        return True
    # Only one request retries a failed connection; other requests return 503
    # promptly instead of occupying every worker while waiting for this lock.
    if not database_lock.acquire(blocking=False):
        return False
    try:
        if DATABASE_AVAILABLE:
            return True
        if time.monotonic() < DATABASE_RETRY_AT:
            return False
        try:
            database.init_database()
            DATABASE_AVAILABLE = True
        except Exception:
            DATABASE_RETRY_AT = time.monotonic() + 5
            logger.exception("Prediction history database is unavailable.")
        return DATABASE_AVAILABLE
    finally:
        database_lock.release()


def model_rejection(loaded_model, saved_names):
    """Say why this model must not be served, or None when it is safe to serve.

    The output count alone is not enough: two different three-class models can mean
    three different things by index 0. So the label order saved beside the model has
    to match the configured grades exactly, or every answer would carry the wrong
    grade name. An unreadable output shape is refused rather than assumed to fit.
    """
    if saved_names != CLASS_NAMES:
        return (
            f"artifacts/model/class_names.json is {saved_names}, but this backend "
            f"is configured "
            f"for {CLASS_NAMES}. Retrain with train_5fold.py."
        )

    try:
        outputs = int(loaded_model.output_shape[-1])
    except (AttributeError, IndexError, TypeError, ValueError):
        return "The model's output shape could not be read, so its labels cannot be checked."

    if outputs != len(CLASS_NAMES) or tuple(loaded_model.output_shape) != (None, len(CLASS_NAMES)):
        return (
            f"The model predicts {outputs} class(es) but {len(CLASS_NAMES)} grades are "
            "configured. Retrain with train_5fold.py."
        )
    try:
        input_shape = tuple(loaded_model.input_shape)
    except (AttributeError, TypeError):
        return "The model input shape could not be read. Retrain the model."
    if input_shape != (None, *IMAGE_SIZE, 3):
        return "The model input must be a 224 by 224 RGB image. Retrain the model."
    return None


def load_model():
    """Load the trained model, or explain why there is nothing to serve.

    Never raises, so a missing or incompatible model cannot stop the server from
    starting - /predict then answers 503 rather than inventing a grade.
    """
    try:
        model_exists = MODEL_PATH.is_file()
        labels_exist = CLASS_NAMES_PATH.is_file()
    except OSError:
        logger.exception("Could not inspect the model artifacts.")
        return None, "The trained model artifacts are unavailable. Check their location and permissions."

    if not model_exists:
        logger.warning("No CNN model found. /predict will answer 503 until one exists.")
        return None, None

    if not labels_exist:
        message = (
            "artifacts/model/class_names.json is missing, so the model's label order "
            "cannot be "
            "checked. Retrain with train_5fold.py."
        )
        logger.error(message)
        return None, message

    try:
        with MODEL_PATH.open("rb") as weights:
            if weights.read(43).startswith(b"version https://git-lfs.github.com/spec/v1"):
                message = "The model is a Git LFS pointer. Include the actual model weights."
                logger.error(message)
                return None, message
        loaded_model = tf.keras.models.load_model(MODEL_PATH, compile=False)
    except Exception:
        logger.exception("Could not load the CNN model.")
        return None, "Could not load the trained model. Check the backend logs and model artifacts."

    try:
        rejection = model_rejection(loaded_model, read_json(CLASS_NAMES_PATH, None))
    except Exception:
        logger.exception("Could not validate the CNN model.")
        return None, "Could not validate the model's input, output and labels."
    if rejection:
        # Serving a model whose labels do not line up with the configured grades
        # would return confident, wrongly named answers: worse than no model.
        logger.error(rejection)
        return None, rejection

    try:
        # A valid shape is insufficient: damaged weights or incompatible layers
        # can still produce NaNs or fail only when first called. Readiness must
        # reflect the ability to run inference, not just deserialize a file.
        validated_probabilities(loaded_model, np.zeros((*IMAGE_SIZE, 3), dtype=np.uint8))
    except Exception:
        logger.exception("The CNN model failed its startup inference check.")
        return None, "The trained model could not complete its startup inference check."

    print(f"CNN model loaded for {', '.join(CLASS_NAMES)}.")
    return loaded_model, None


def safe_float(value, default=0.0):
    try:
        value = float(value)
        return value if math.isfinite(value) else default
    except (TypeError, ValueError):
        return default


def db_call(action, detail):
    global DATABASE_AVAILABLE, DATABASE_RETRY_AT
    if not init_database():
        raise HTTPException(status_code=503, detail="Prediction history is unavailable.")
    try:
        return action()
    except database.DatabaseBusyError as error:
        raise HTTPException(status_code=503, detail=str(error), headers={"Retry-After": "2"}) from error
    except Exception as error:
        DATABASE_AVAILABLE = False
        DATABASE_RETRY_AT = time.monotonic() + 5
        logger.exception(detail)
        raise HTTPException(status_code=503, detail=detail) from error


def save_history(result, image_path=None, client_hash=None):
    try:
        return db_call(lambda: database.add_prediction(
            {
                "predicted_grade": result.get("predicted_grade") or "Unknown",
                "confidence": safe_float(result.get("confidence")),
                "image_path": str(image_path) if image_path else None,
                "note": result.get("note"),
                "error": result.get("error"),
                "created_at": datetime.now(timezone.utc).isoformat(),
                "client_hash": client_hash,
            }
        ), "Could not save prediction history.")
    except HTTPException:
        return None
    except Exception:
        logger.exception("Could not save prediction history.")
        return None


def upload_path(filename):
    suffix = Path(filename or "").suffix.lower()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    if suffix not in IMAGE_SUFFIXES:
        suffix = ".jpg"

    return UPLOADS_DIR / f"upload_{stamp}_{uuid4().hex}{suffix}"


def remove_upload(path):
    try:
        path.unlink(missing_ok=True)
    except OSError:
        logger.exception("Could not remove temporary upload: %s", path)


async def save_upload(file):
    """Stream the upload to disk, enforcing the size cap. Cleans up on any failure."""
    path = None
    total = 0
    try:
        UPLOADS_DIR.mkdir(parents=True, exist_ok=True)
        path = upload_path(file.filename)
        with path.open("wb") as buffer:
            while chunk := await file.read(UPLOAD_CHUNK_BYTES):
                total += len(chunk)
                if total > MAX_UPLOAD_BYTES:
                    raise HTTPException(
                        status_code=413,
                        detail="Image is too large. Maximum upload size is 15 MB.",
                    )
                buffer.write(chunk)
    except HTTPException:
        if path:
            remove_upload(path)
        raise
    except asyncio.CancelledError:
        if path:
            remove_upload(path)
        raise
    except Exception as error:
        if path:
            remove_upload(path)
        logger.exception("Could not save uploaded image.")
        raise HTTPException(status_code=500, detail="Could not save uploaded image.") from error
    finally:
        try:
            await file.close()
        except BaseException:
            if path:
                remove_upload(path)
            raise

    if total == 0:
        remove_upload(path)
        raise HTTPException(status_code=400, detail="Uploaded file is empty.")
    return path


def has_image_signature(header):
    """True when these leading bytes start a JPEG, PNG or WebP file."""
    return header.startswith((b"\xff\xd8\xff", b"\x89PNG\r\n\x1a\n")) or (
        header.startswith(b"RIFF") and header[8:12] == b"WEBP"
    )


def load_upload(path):
    """Decode an upload with the official preprocessing, if it is a supported type.

    Pillow recognises JPEG, PNG and WebP by these same leading bytes, so no valid
    image is turned away here. Any other upload never reaches Pillow, which would
    otherwise offer it to parsers for formats the API does not accept.
    """
    with path.open("rb") as upload:
        if not has_image_signature(upload.read(12)):
            raise ValueError("The upload is not a JPEG, PNG or WebP file.")
    return load_inference_image(path)


def validated_probabilities(loaded_model, image):
    probabilities = np.asarray(loaded_model(image[np.newaxis], training=False))
    if not (np.issubdtype(probabilities.dtype, np.floating) or np.issubdtype(probabilities.dtype, np.integer)):
        raise ValueError("Model probabilities must be real numbers.")
    if probabilities.shape != (1, len(CLASS_NAMES)) or not np.all(np.isfinite(probabilities)):
        raise ValueError("Model returned invalid class probabilities.")
    probabilities = probabilities[0]
    if np.any(probabilities < 0) or np.any(probabilities > 1) or not np.isclose(probabilities.sum(), 1, atol=0.01):
        raise ValueError("Model output is not a probability distribution.")
    return probabilities


def classify_image(image):
    """The official prediction rule: the CNN's own class and its softmax score.

    Nothing adjusts, averages or overrides this. evaluate_model.evaluate_fold takes
    the argmax of the same model over the same crop, so a cross-validated score
    describes exactly what this function returns.

    The lock keeps TensorFlow to one prediction at a time. This is called from a
    worker thread, because running it on the event loop would make the whole
    server stop answering for as long as a prediction takes.
    """
    with model_lock:
        # A direct inference call avoids building a tf.data thread pool for every
        # uploaded image and respects training=False for dropout/batch norm.
        probabilities = validated_probabilities(model, image)

    index = int(np.argmax(probabilities))
    return index, float(probabilities[index])


@app.get("/")
def home():
    if (STATIC_DIR / "index.html").is_file():
        return FileResponse(STATIC_DIR / "index.html")
    return {"message": "Rice CNN backend is running."}


@app.get("/health")
async def health_check():
    return {"status": "ok", "model_available": model is not None, "database_available": DATABASE_AVAILABLE}


@app.get("/ready")
def readiness_check():
    try:
        db_call(database.check_connection, "Prediction history is unavailable.")
        database_available = True
    except HTTPException:
        database_available = False
    ready = model is not None and database_available
    return JSONResponse({
        "status": "ready" if ready else "not_ready",
        "model_available": model is not None,
        "database_available": database_available,
    }, status_code=200 if ready else 503)


@app.get("/metrics")
def metrics():
    saved = read_json(METRICS_PATH, {})
    if not isinstance(saved, dict):
        saved = {}

    # Configured grades are what this backend is set up to recognise. Trained grades
    # are what a loaded, compatible model can actually predict - an empty list while
    # there is no model, so nothing claims to be trained before training happens.
    trained = CLASS_NAMES if model is not None else []

    if MODEL_LOAD_ERROR:
        message = "The model is not being served. The server log records why."
    elif model is None:
        message = "No trained model yet. Run train_5fold.py to create one."
    elif saved.get("evaluation_method"):
        method = str(saved["evaluation_method"]).lower()
        message = f"Model is loaded. Scores come from {method}."
    elif saved:
        message = "Model is loaded with saved evaluation metrics."
    else:
        message = "Model is loaded. Run train_5fold.py to record evaluation metrics."

    return {
        "model_available": model is not None,
        "classes": CLASS_NAMES,
        "trained_classes": trained,
        "class_status": [
            {
                "name": name,
                "trained": name in trained,
                "status": "trained" if name in trained else "not_trained",
            }
            for name in CLASS_NAMES
        ],
        "database_available": DATABASE_AVAILABLE,
        "model_load_error": "The trained model could not be loaded." if MODEL_LOAD_ERROR else None,
        # False until train_5fold.py records a run. Every METRIC_FIELDS value is
        # then null, so an absent metrics.json reports "not evaluated" rather than
        # scores from an older dataset. No score is ever substituted.
        "evaluation_available": bool(saved),
        **{key: saved.get(key) for key in METRIC_FIELDS},
        "message": message,
    }


def hash_client_id(client_id):
    return hashlib.sha256(client_id.encode("ascii")).hexdigest()


async def history_client(x_client_id: str = Header(pattern=CLIENT_ID_PATTERN)):
    """The requesting client's history key. A missing or malformed ID is a 422."""
    return hash_client_id(x_client_id)


@app.get("/history")
def get_history(limit: int = Query(default=50, ge=1, le=200), client_hash: str = Depends(history_client)):
    return db_call(
        lambda: database.list_predictions(client_hash, limit), "Could not read prediction history."
    )


class HistoryEntry(BaseModel):
    model_config = ConfigDict(populate_by_name=True, allow_inf_nan=False)
    predicted_grade: str = Field(default="Unknown", alias="predictedGrade", min_length=1, max_length=100)
    confidence: float = Field(default=0, ge=0, le=100)
    image_path: str | None = Field(default=None, alias="imagePath", max_length=2048)
    note: str | None = Field(default=None, max_length=4000)
    error: str | None = Field(default=None, max_length=4000)
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc), alias="createdAt")


@app.post("/history")
def add_history_entry(entry: HistoryEntry, client_hash: str = Depends(history_client)):
    created_at = entry.created_at
    if created_at.tzinfo is None:
        created_at = created_at.replace(tzinfo=timezone.utc)
    payload = {
        "predicted_grade": entry.predicted_grade,
        "confidence": entry.confidence,
        "image_path": entry.image_path,
        "note": entry.note,
        "error": entry.error,
        "created_at": created_at.astimezone(timezone.utc).isoformat(),
        "client_hash": client_hash,
    }
    entry_id = db_call(
        lambda: database.add_prediction(payload), "Could not save prediction history."
    )
    return {"id": entry_id, "saved": True}


@app.delete("/history")
def clear_history(client_hash: str = Depends(history_client)):
    db_call(lambda: database.clear_predictions(client_hash), "Could not clear prediction history.")
    return {"cleared": True}


@app.post("/predict")
@app.post("/predict/", include_in_schema=False)
async def predict(
    file: UploadFile = File(...),
    x_client_id: str | None = Header(default=None, pattern=CLIENT_ID_PATTERN),
):
    # Checked before the upload is written, so an unusable request leaves no file.
    if model is None:
        await file.close()
        raise HTTPException(status_code=503, detail=MODEL_UNAVAILABLE)

    image_path = await save_upload(file)

    try:
        try:
            image = await run_in_threadpool(load_upload, image_path)
        except Exception as error:
            logger.exception("Uploaded file could not be processed as an image.")
            raise HTTPException(
                status_code=400,
                detail="Could not read the image. Use a JPG, PNG or WEBP up to 25 megapixels.",
            ) from error

        try:
            index, confidence = await run_in_threadpool(classify_image, image)
        except Exception as error:
            logger.exception("Prediction failed.")
            raise HTTPException(
                status_code=500,
                detail="The backend could not process this image. Please try again.",
            ) from error

        result = {
            "predicted_grade": CLASS_NAMES[index],
            "confidence": round(confidence * 100, 2),
        }
        # History stores the result, not a path to an image nobody serves. Keeping
        # every uploaded photo would eventually fill Railway's ephemeral disk.
        # Without a client ID (the web page, older app builds) the entry is kept
        # for the record but belongs to no client, so no one can read it back.
        client_hash = hash_client_id(x_client_id) if x_client_id else None
        result["history_saved"] = await run_in_threadpool(
            save_history, result, client_hash=client_hash
        ) is not None
        return result
    finally:
        remove_upload(image_path)


@app.get("/{path:path}", include_in_schema=False)
def web_client(path: str):
    # Unknown API URLs must remain real 404 responses, never the SPA's HTML.
    if path.split("/", 1)[0] in {"predict", "history", "metrics", "health", "ready"}:
        raise HTTPException(status_code=404, detail="Not found.")
    directory = STATIC_DIR.resolve()
    candidate = (directory / path).resolve()
    if not candidate.is_relative_to(directory):
        raise HTTPException(status_code=404, detail="Not found.")
    if candidate.is_file():
        return FileResponse(candidate)
    if (directory / "index.html").is_file():
        # Missing assets should be 404 rather than JavaScript parser errors from
        # receiving index.html in place of an old cached bundle.
        if path.startswith("assets/") or Path(path).suffix:
            raise HTTPException(status_code=404, detail="Not found.")
        return FileResponse(directory / "index.html")
    raise HTTPException(status_code=404, detail="Not found.")
