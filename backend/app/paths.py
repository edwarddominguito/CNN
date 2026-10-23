"""Where things live on disk. One definition per folder, imported by app/ and ml/.

Only the paths more than one module needs are here. Everything else stays a local
constant in the file that uses it, so this stays a short list rather than a
configuration layer.
"""

import os
from pathlib import Path

# app/paths.py -> app/ -> backend/
BACKEND_DIR = Path(__file__).resolve().parents[1]

# Collected photographs. Read-only input: training and scanning never write here.
DATASET_DIR = Path(os.getenv("DATASET_DIR", str(BACKEND_DIR / "data" / "dataset"))).resolve()

# Written by training, read by the API. Safe to delete and regenerate.
MODEL_DIR = Path(os.getenv("MODEL_DIR", str(BACKEND_DIR / "artifacts" / "model"))).resolve()
RESULTS_DIR = BACKEND_DIR / "artifacts" / "results"

# Temporary uploads, written by the server and deleted after each prediction.
# Prediction history lives in MySQL (app/database.py), not here.
STORAGE_DIR = Path(os.getenv("STORAGE_DIR", str(BACKEND_DIR / "storage"))).resolve()
UPLOADS_DIR = STORAGE_DIR / "uploads"
