import json
import shutil
from datetime import datetime, timezone
from pathlib import Path

import database
from python_env import use_local_venv

use_local_venv()

import numpy as np
import tensorflow as tf
from fastapi.middleware.cors import CORSMiddleware
from fastapi import Body, FastAPI, UploadFile, File
from PIL import Image

BASE_DIR = Path(__file__).resolve().parent
MODEL_DIR = BASE_DIR / "model"
UPLOAD_DIR = BASE_DIR / "uploads"
MODEL_PATH = MODEL_DIR / "rice_cnn_model.keras"
CLASS_NAMES_PATH = MODEL_DIR / "class_names.json"

DEFAULT_CLASS_NAMES = [
    "Premium",
    "Well-Milled",
    "Regular-Milled",
    "Poor-Quality-Rice-Mix",
]

app = FastAPI(title="Rice CNN Backend")
database.init_database()

app.add_middleware(
    CORSMiddleware,
    allow_origins=[],
    allow_origin_regex=r"http://(localhost|127\.0\.0\.1)(:\d+)?",
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def load_class_names():
    if CLASS_NAMES_PATH.exists():
        with CLASS_NAMES_PATH.open("r", encoding="utf-8") as file:
            return json.load(file)

    return DEFAULT_CLASS_NAMES


CLASS_NAMES = load_class_names()

model = None

if MODEL_PATH.exists():
    model = tf.keras.models.load_model(MODEL_PATH)
    print("CNN model loaded successfully.")
else:
    print("No CNN model found yet. Using demo prediction only.")


def preprocess_image(image_path):
    image = Image.open(image_path).convert("RGB")
    image = image.resize((224, 224))

    image_array = np.array(image)
    image_array = np.expand_dims(image_array, axis=0)

    return image_array


@app.get("/")
def home():
    return {"message": "Rice CNN backend is running."}


@app.get("/health")
def health_check():
    return {"status": "ok"}


@app.get("/metrics")
def metrics():
    return {
        "model_available": model is not None,
        "classes": CLASS_NAMES,
        "accuracy": None,
        "precision": None,
        "recall": None,
        "f1_score": None,
        "message": (
            "No trained model metrics found yet."
            if model is None
            else "Model is loaded. Add evaluation metrics after running evaluate_model.py."
        ),
    }


@app.get("/history")
def get_history(limit: int = 50):
    return database.list_predictions(limit=limit)


@app.post("/history")
def add_history_entry(entry: dict = Body(...)):
    created_at = entry.get("createdAt") or datetime.now(timezone.utc).isoformat()
    prediction_entry = {
        "predicted_grade": entry.get("predictedGrade") or "Unknown",
        "confidence": float(entry.get("confidence") or 0),
        "image_path": entry.get("imagePath"),
        "note": entry.get("note"),
        "error": entry.get("error"),
        "created_at": created_at,
    }
    entry_id = database.add_prediction(prediction_entry)
    return {"id": entry_id, "saved": True}


@app.delete("/history")
def clear_history():
    database.clear_predictions()
    return {"cleared": True}


@app.post("/predict")
async def predict(file: UploadFile = File(...)):
    UPLOAD_DIR.mkdir(exist_ok=True)

    safe_filename = Path(file.filename or "upload.jpg").name
    file_path = UPLOAD_DIR / safe_filename

    with file_path.open("wb") as buffer:
        shutil.copyfileobj(file.file, buffer)

    if model is None:
        result = {
            "predicted_grade": "Demo Result: Well-Milled",
            "confidence": 91.25,
            "note": "No trained CNN model yet. Run train_model.py after adding rice images to create backend/model/rice_cnn_model.keras."
        }
        database.add_prediction(
            {
                "predicted_grade": result["predicted_grade"],
                "confidence": result["confidence"],
                "image_path": str(file_path),
                "note": result["note"],
                "error": None,
                "created_at": datetime.now(timezone.utc).isoformat(),
            }
        )
        return result

    image_array = preprocess_image(file_path)

    prediction = model.predict(image_array)
    predicted_index = int(np.argmax(prediction[0]))
    confidence = float(np.max(prediction[0])) * 100
    predicted_grade = (
        CLASS_NAMES[predicted_index]
        if predicted_index < len(CLASS_NAMES)
        else f"Class {predicted_index}"
    )

    result = {
        "predicted_grade": predicted_grade,
        "confidence": round(confidence, 2)
    }
    database.add_prediction(
        {
            "predicted_grade": result["predicted_grade"],
            "confidence": result["confidence"],
            "image_path": str(file_path),
            "note": None,
            "error": None,
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
    )
    return result
