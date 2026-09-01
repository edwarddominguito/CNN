import json
import logging
import math
from datetime import datetime, timezone
from pathlib import Path
from threading import Lock
from uuid import uuid4

import database
from python_env import use_local_venv

use_local_venv()

import numpy as np
import tensorflow as tf
from fastapi import Body, FastAPI, File, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from image_preprocessing import CLASS_NAMES as DEFAULT_CLASS_NAMES
from image_preprocessing import load_prediction_crops
from model_calibration import PredictionCalibrator
from starlette.concurrency import run_in_threadpool


BASE_DIR = Path(__file__).resolve().parent
MODEL_DIR = BASE_DIR / "model"
UPLOAD_DIR = BASE_DIR / "uploads"
MODEL_PATH = MODEL_DIR / "rice_cnn_model.keras"
CLASS_NAMES_PATH = MODEL_DIR / "class_names.json"
METRICS_PATH = MODEL_DIR / "metrics.json"

MAX_UPLOAD_BYTES = 15 * 1024 * 1024
UPLOAD_CHUNK_BYTES = 1024 * 1024
IMAGE_SUFFIXES = {".bmp", ".gif", ".jpeg", ".jpg", ".png", ".webp"}
# Fields train_5fold.py writes into metrics.json and /metrics forwards to the apps.
METRIC_FIELDS = (
    "accuracy", "precision", "recall", "f1_score",
    "accuracy_std", "precision_std", "recall_std", "f1_score_std",
    "per_class", "evaluation_method", "folds", "evaluation_images", "generated_at",
)

logger = logging.getLogger("rice_backend")
model_lock = Lock()
app = FastAPI(title="Rice CNN Backend")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


def read_json(path, fallback):
    """Read a JSON file, or fall back if it is missing, damaged or unreadable.

    ValueError covers both json.JSONDecodeError and the UnicodeDecodeError a
    non-UTF-8 file raises. This runs at import time, so an unhandled error here
    would stop the server from starting at all.
    """
    if not path.exists():
        return fallback
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        logger.exception("Could not read JSON file: %s", path)
        return fallback


def load_class_names():
    names = read_json(CLASS_NAMES_PATH, DEFAULT_CLASS_NAMES)
    if isinstance(names, list) and names and all(isinstance(n, str) and n for n in names):
        return names

    logger.error("Invalid class names file. Falling back to defaults.")
    return DEFAULT_CLASS_NAMES


def init_database():
    try:
        database.init_database()
        return True
    except Exception:
        logger.exception("Prediction history database is unavailable.")
        return False


def class_count_mismatch(loaded_model):
    """Describe a model whose output count disagrees with class_names.json, else None."""
    try:
        outputs = int(loaded_model.output_shape[-1])
    except (AttributeError, IndexError, TypeError):
        return None

    if outputs == len(CLASS_NAMES):
        return None

    return (
        f"The model predicts {outputs} class(es) but class_names.json lists "
        f"{len(CLASS_NAMES)} ({', '.join(CLASS_NAMES)}). Retrain with train_5fold.py "
        "so the labels match the model."
    )


def load_model():
    """Load the trained model plus its calibrator. Never raises: falls back to demo mode."""
    if not MODEL_PATH.exists():
        print("No CNN model found yet. Using demo prediction only.")
        return None, None, None

    try:
        loaded_model = tf.keras.models.load_model(MODEL_PATH)
    except Exception as error:
        logger.exception("Could not load CNN model. Using demo prediction only.")
        return None, None, str(error)

    mismatch = class_count_mismatch(loaded_model)
    if mismatch:
        # Serving a model whose outputs do not line up with the label list would
        # return confident, wrongly named grades, which is worse than no model.
        logger.error(mismatch)
        return None, None, mismatch

    try:
        calibrator = PredictionCalibrator(loaded_model, CLASS_NAMES)
    except Exception:
        logger.exception("Prediction calibration is unavailable. Using raw model output.")
        calibrator = None

    print("CNN model loaded successfully.")
    print(
        "Prediction calibration loaded successfully."
        if calibrator and calibrator.available
        else "No prediction calibration cache found."
    )
    return loaded_model, calibrator, None


CLASS_NAMES = load_class_names()
DATABASE_AVAILABLE = init_database()
model, calibrator, MODEL_LOAD_ERROR = load_model()


def safe_float(value, default=0.0):
    try:
        value = float(value)
        return value if math.isfinite(value) else default
    except (TypeError, ValueError):
        return default


def db_call(action, detail):
    if not DATABASE_AVAILABLE:
        raise HTTPException(status_code=503, detail="Prediction history is unavailable.")
    try:
        return action()
    except Exception as error:
        logger.exception(detail)
        raise HTTPException(status_code=503, detail=detail) from error


def save_history(result, image_path=None):
    if not DATABASE_AVAILABLE:
        return None

    try:
        return database.add_prediction(
            {
                "predicted_grade": result.get("predicted_grade") or "Unknown",
                "confidence": safe_float(result.get("confidence")),
                "image_path": str(image_path) if image_path else None,
                "note": result.get("note"),
                "error": result.get("error"),
                "created_at": datetime.now(timezone.utc).isoformat(),
            }
        )
    except Exception:
        logger.exception("Could not save prediction history.")
        return None


def upload_path(filename):
    suffix = Path(filename or "").suffix.lower()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    if suffix not in IMAGE_SUFFIXES:
        suffix = ".jpg"

    return UPLOAD_DIR / f"upload_{stamp}_{uuid4().hex}{suffix}"


async def save_upload(file):
    """Stream the upload to disk, enforcing the size cap. Cleans up on any failure."""
    path = None
    total = 0
    try:
        UPLOAD_DIR.mkdir(exist_ok=True)
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
            path.unlink(missing_ok=True)
        raise
    except Exception as error:
        if path:
            path.unlink(missing_ok=True)
        logger.exception("Could not save uploaded image.")
        raise HTTPException(status_code=500, detail="Could not save uploaded image.") from error
    finally:
        await file.close()

    if total == 0:
        path.unlink(missing_ok=True)
        raise HTTPException(status_code=400, detail="Uploaded file is empty.")
    return path


def failed_prediction(message, image_path=None):
    result = {"predicted_grade": "Prediction Failed", "confidence": 0, "error": message}
    save_history(result, image_path)
    return result


def calibrated_prediction(crops, probabilities):
    probabilities = np.asarray(probabilities, dtype=np.float32).reshape(-1)
    if probabilities.size == 0:
        raise ValueError("Model returned an empty prediction.")

    raw_index = int(np.argmax(probabilities))
    raw = raw_index, float(probabilities[raw_index]), None
    if calibrator is None:
        return raw

    try:
        return calibrator.calibrate(crops, probabilities)
    except Exception:
        logger.exception("Calibration failed. Using raw model output.")
        return raw


def classify_crops(crops):
    """Run the CNN on the five crops and average them into one answer.

    The lock keeps TensorFlow to one prediction at a time. This is called from a
    worker thread, because running it on the event loop would make the whole
    server stop answering for as long as a prediction takes.
    """
    with model_lock:
        probabilities = np.mean(model.predict(crops, verbose=0), axis=0)
        return calibrated_prediction(crops, probabilities)


@app.get("/")
def home():
    return {"message": "Rice CNN backend is running."}


@app.get("/health")
def health_check():
    return {"status": "ok"}


@app.get("/metrics")
def metrics():
    saved = read_json(METRICS_PATH, {})
    if not isinstance(saved, dict):
        saved = {}

    trained = set(CLASS_NAMES)
    if MODEL_LOAD_ERROR:
        message = f"The model is not being served: {MODEL_LOAD_ERROR}"
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
        "all_classes": DEFAULT_CLASS_NAMES,
        "trained_classes": CLASS_NAMES,
        "reserved_classes": [n for n in DEFAULT_CLASS_NAMES if n not in trained],
        "class_status": [
            {"name": n, "trained": n in trained, "status": "trained" if n in trained else "reserved"}
            for n in DEFAULT_CLASS_NAMES
        ],
        "database_available": DATABASE_AVAILABLE,
        "model_load_error": MODEL_LOAD_ERROR,
        # Passed straight through, so adding a field to metrics.json reaches the apps
        # without touching the API.
        **{key: saved.get(key) for key in METRIC_FIELDS},
        "message": message,
    }


@app.get("/history")
def get_history(limit: int = Query(default=50, ge=1, le=200)):
    return db_call(lambda: database.list_predictions(limit), "Could not read prediction history.")


@app.post("/history")
def add_history_entry(entry: dict = Body(...)):
    payload = {
        "predicted_grade": str(entry.get("predictedGrade") or "Unknown"),
        "confidence": safe_float(entry.get("confidence")),
        "image_path": entry.get("imagePath"),
        "note": entry.get("note"),
        "error": entry.get("error"),
        "created_at": str(entry.get("createdAt") or datetime.now(timezone.utc).isoformat()),
    }
    entry_id = db_call(
        lambda: database.add_prediction(payload), "Could not save prediction history."
    )
    return {"id": entry_id, "saved": True}


@app.delete("/history")
def clear_history():
    db_call(database.clear_predictions, "Could not clear prediction history.")
    return {"cleared": True}


@app.post("/predict")
async def predict(file: UploadFile = File(...)):
    image_path = await save_upload(file)

    if model is None:
        result = {
            "predicted_grade": "Demo Result: Well-Milled",
            "confidence": 91.25,
            "note": (
                "No trained CNN model yet. Run train_model.py after adding rice "
                "images to create backend/model/rice_cnn_model.keras."
            ),
        }
        save_history(result, image_path)
        return result

    try:
        crops = await run_in_threadpool(load_prediction_crops, image_path)
    except Exception:
        logger.exception("Uploaded file could not be processed as an image.")
        return failed_prediction(
            "Could not read the uploaded image. Please use a clear JPG or PNG file.", image_path
        )

    try:
        index, confidence, calibration = await run_in_threadpool(classify_crops, crops)
    except Exception:
        logger.exception("Prediction failed.")
        return failed_prediction(
            "The backend could not process this image. Try another image or restart the server.",
            image_path,
        )

    result = {
        "predicted_grade": CLASS_NAMES[index] if 0 <= index < len(CLASS_NAMES) else f"Class {index}",
        "confidence": round(safe_float(np.clip(confidence, 0, 1)) * 100, 2),
    }
    if calibration and calibration.get("calibrated"):
        result["note"] = "Adjusted using nearest trained rice samples."

    save_history(result, image_path)
    return result
