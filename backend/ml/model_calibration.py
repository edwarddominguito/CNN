"""Nearest-training-sample lookup, kept as a research side tool.

This is NOT part of the official prediction rule. POST /predict reports the CNN's
own class and softmax confidence and nothing else, so a cosine similarity to a
stored training image can never rename a grade or stand in for a probability.
train_model.py still writes artifacts/model/support_embeddings.npz after training;
nothing in
main.py reads it.
"""

from pathlib import Path
from zipfile import BadZipFile

import numpy as np
import tensorflow as tf

from app.paths import BACKEND_DIR, DATASET_DIR, MODEL_DIR
from ml.image_preprocessing import IMAGE_EXTENSIONS, load_inference_image


SUPPORT_EMBEDDINGS_PATH = MODEL_DIR / "support_embeddings.npz"

EMBEDDING_LAYER_NAME = "rice_embedding"
SUPPORT_TOP_K = 7
SUPPORT_MIN_SIMILARITY = 0.94
SUPPORT_MIN_VOTE_SHARE = 0.57

EMPTY_SUPPORT = {
    "embeddings": np.empty((0, 0), dtype=np.float32),
    "labels": np.empty((0,), dtype=np.int32),
    "paths": np.empty((0,), dtype=str),
}


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


def class_image_paths(class_names, dataset_dir=DATASET_DIR):
    """Yield (label, path) per image, at any batch depth under the class folder."""
    for label, class_name in enumerate(class_names):
        class_dir = dataset_dir / class_name
        if not class_dir.is_dir():
            continue

        yield from (
            (label, path)
            for path in sorted(class_dir.rglob("*"))
            if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS
        )


def relative_to_backend(path):
    """Store a tidy relative path when possible, but never fail over a path outside."""
    try:
        return str(path.relative_to(BACKEND_DIR))
    except ValueError:
        return str(path)


def save_support_embeddings(
    model, class_names, samples=None, output_path=SUPPORT_EMBEDDINGS_PATH
):
    """Cache one embedding per training image so predictions can be calibrated.

    Pass `samples` as (label, path) pairs to pin the support set to an exact image
    list; otherwise every image under each class folder is scanned.
    """
    feature_model = make_feature_model(model)
    embeddings, labels, paths = [], [], []

    for label, image_path in class_image_paths(class_names) if samples is None else samples:
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


class PredictionCalibrator:
    def __init__(self, model, class_names):
        self.class_names = class_names
        self.feature_model = make_feature_model(model)
        self.support = load_support_embeddings(class_names) or dict(EMPTY_SUPPORT)

    @property
    def available(self):
        return len(self.support["labels"]) > 0

    def calibrate(self, crops, probabilities):
        """Nudge the raw prediction toward the nearest trained samples, when they agree."""
        raw_index = int(np.argmax(probabilities))
        raw = raw_index, float(probabilities[raw_index]), None
        if not self.available:
            return raw

        query = normalized_embedding(self.feature_model, crops)
        if self.support["embeddings"].shape[1] != query.shape[0]:
            return raw

        similarities = self.support["embeddings"] @ query
        top_count = min(SUPPORT_TOP_K, len(similarities))
        if top_count == 0:
            return raw

        top_indices = np.argsort(similarities)[-top_count:][::-1]

        scores = np.zeros(len(self.class_names), dtype=np.float32)
        winner_similarities = {}
        for index in top_indices:
            label = int(self.support["labels"][index])
            similarity = float(similarities[index])
            scores[label] += similarity
            winner_similarities.setdefault(label, []).append(similarity)

        support_index = int(np.argmax(scores))
        support_total = float(np.sum(scores))
        if support_total <= 0:
            return raw

        vote_share = float(scores[support_index] / support_total)
        top_similarity = float(similarities[top_indices[0]])
        nearest = {
            "calibrated": False,
            "nearest_grade": self.class_names[support_index],
            "nearest_similarity": round(top_similarity * 100, 2),
        }

        if vote_share < SUPPORT_MIN_VOTE_SHARE or top_similarity < SUPPORT_MIN_SIMILARITY:
            return raw_index, float(probabilities[raw_index]), nearest

        confidence = float(np.mean(winner_similarities[support_index]))
        return support_index, confidence, {**nearest, "calibrated": support_index != raw_index}
