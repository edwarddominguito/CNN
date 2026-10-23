"""An embedding cache of the training images, kept as a research side artifact.

This is NOT part of the official prediction rule. POST /predict reports the CNN's
own class and softmax confidence and nothing else, so a cosine similarity to a
stored training image can never rename a grade or stand in for a probability.
train_model.py still writes artifacts/model/support_embeddings.npz after training;
nothing in main.py reads it.
"""

from pathlib import Path
from zipfile import BadZipFile

import numpy as np
import tensorflow as tf

from app.paths import BACKEND_DIR, MODEL_DIR
from ml.image_preprocessing import load_inference_image
from ml.train_model import EMBEDDING_LAYER_NAME

SUPPORT_EMBEDDINGS_PATH = MODEL_DIR / "support_embeddings.npz"


def make_feature_model(model):
    try:
        output = model.get_layer(EMBEDDING_LAYER_NAME).output
    except ValueError:
        if len(model.layers) < 3:
            raise ValueError("Model does not contain enough layers for calibration.")
        output = model.layers[-3].output

    return tf.keras.Model(model.input, output)


def normalized_embedding(feature_model, crops):
    features = feature_model.predict(crops, verbose=0).mean(axis=0)
    norm = np.linalg.norm(features)
    return features if norm == 0 else features / norm


def relative_to_backend(path):
    """Store a tidy relative path when possible, but never fail over a path outside."""
    try:
        return str(path.relative_to(BACKEND_DIR))
    except ValueError:
        return str(path)


def save_support_embeddings(model, class_names, samples, output_path=SUPPORT_EMBEDDINGS_PATH):
    """Cache one embedding per training image, given as (label, path) pairs."""
    feature_model = make_feature_model(model)
    embeddings, labels, paths = [], [], []

    for label, image_path in samples:
        image_path = Path(image_path)
        try:
            image = load_inference_image(image_path)
        except (OSError, ValueError):
            # One unreadable image must not throw away the whole support set.
            continue

        embeddings.append(normalized_embedding(feature_model, image[np.newaxis]))
        labels.append(int(label))
        paths.append(relative_to_backend(image_path))

    if not embeddings:
        return 0

    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        output_path,
        embeddings=np.asarray(embeddings, dtype=np.float32),
        labels=np.asarray(labels, dtype=np.int32),
        paths=np.asarray(paths),
        class_names=np.asarray(class_names),
    )
    return len(embeddings)


def load_support_embeddings(class_names, path=SUPPORT_EMBEDDINGS_PATH):
    """Return the saved support set, or None if it is missing or unusable."""
    path = Path(path)
    if not path.exists():
        return None

    try:
        with np.load(path, allow_pickle=False) as data:
            saved_names = data.get("class_names")
            if saved_names is None or saved_names.tolist() != class_names:
                return None
            embeddings, labels, paths = data["embeddings"], data["labels"], data["paths"]
    except (OSError, KeyError, ValueError, TypeError, EOFError, BadZipFile):
        return None

    # Checks are ordered: each one assumes the previous passed.
    try:
        usable = (
            embeddings.ndim == 2
            and labels.ndim == paths.ndim == 1
            and len(embeddings) == len(labels) == len(paths)
            and (np.issubdtype(embeddings.dtype, np.floating)
                 or np.issubdtype(embeddings.dtype, np.integer))
            and np.issubdtype(labels.dtype, np.integer)
            and bool(np.all(np.isfinite(embeddings)))
            and not np.any(labels < 0)
            and not np.any(labels >= len(class_names))
        )
    except (TypeError, ValueError):
        return None
    if not usable:
        return None

    return {"embeddings": embeddings, "labels": labels, "paths": paths}
