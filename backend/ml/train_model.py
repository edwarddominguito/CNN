"""The CNN itself: architecture, augmentation, callbacks, and the final model.

Import this from train_5fold.py. Running it directly does nothing useful, because a
single train/validation split cannot measure this dataset honestly - there are only
a handful of physical rice samples per grade, so one split would hide most of the
variation that the grouped five-fold run reports.
"""

import json
from pathlib import Path

import numpy as np
import tensorflow as tf

from ml.image_preprocessing import IMAGE_SIZE, make_dataset

# model_calibration.py looks this layer up by name when it builds the support
# embedding cache. Renaming it silently disables that cache.
EMBEDDING_LAYER_NAME = "rice_embedding"

EARLY_STOPPING_PATIENCE = 5
REDUCE_LR_PATIENCE = 2


def build_augmentation() -> tf.keras.Sequential:
    """Moderate augmentation, kept inside the model.

    Keras runs these layers only when training=True, so validation and evaluation
    images pass through untouched and the saved model needs no special handling.
    """
    return tf.keras.Sequential(
        [
            tf.keras.layers.RandomRotation(0.04),
            tf.keras.layers.RandomZoom(0.08),
            tf.keras.layers.RandomTranslation(0.04, 0.04),
            tf.keras.layers.RandomContrast(0.10),
        ],
        name="rice_augmentation",
    )


def build_model(num_classes: int) -> tf.keras.Model:
    """MobileNetV2 transfer learning, with preprocessing baked into the model.

    Keeping the rescaling inside means FastAPI can hand the model a plain RGB array
    and cannot accidentally normalise it differently from training.
    """
    if num_classes < 2:
        raise ValueError("A classifier needs at least two grades to train on.")

    backbone = tf.keras.applications.MobileNetV2(
        input_shape=(*IMAGE_SIZE, 3), include_top=False, weights="imagenet"
    )
    # The dataset is small, so the pretrained features stay frozen.
    backbone.trainable = False

    inputs = tf.keras.Input(shape=(*IMAGE_SIZE, 3), name="rice_image")
    x = build_augmentation()(inputs)
    x = tf.keras.layers.Rescaling(1 / 127.5, offset=-1.0, name="mobilenet_preprocess")(x)
    x = backbone(x, training=False)
    x = tf.keras.layers.GlobalAveragePooling2D()(x)
    x = tf.keras.layers.Dropout(0.35)(x)
    x = tf.keras.layers.Dense(128, activation="relu", name=EMBEDDING_LAYER_NAME)(x)
    x = tf.keras.layers.Dropout(0.25)(x)
    outputs = tf.keras.layers.Dense(
        num_classes, activation="softmax", name="grade_probabilities"
    )(x)

    model = tf.keras.Model(inputs, outputs, name="rice_mobilenet_v2")
    model.compile(
        optimizer=tf.keras.optimizers.Adam(),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )
    return model


def build_callbacks(checkpoint_path: Path) -> list:
    """Stop when validation loss stops improving, and keep the best weights."""
    checkpoint_path.parent.mkdir(parents=True, exist_ok=True)
    return [
        tf.keras.callbacks.EarlyStopping(
            monitor="val_loss",
            patience=EARLY_STOPPING_PATIENCE,
            restore_best_weights=True,
        ),
        tf.keras.callbacks.ReduceLROnPlateau(
            monitor="val_loss", factor=0.2, patience=REDUCE_LR_PATIENCE, min_lr=1e-7
        ),
        tf.keras.callbacks.ModelCheckpoint(
            filepath=checkpoint_path, monitor="val_loss", save_best_only=True
        ),
    ]


def compute_class_weights(labels, num_classes: int) -> dict:
    """Weight rarer grades higher so a common grade cannot hide them."""
    counts = np.bincount(labels, minlength=num_classes)
    return {
        index: len(labels) / (num_classes * int(count))
        for index, count in enumerate(counts)
        if count > 0
    }


def start_fresh_model(num_classes: int, seed: int) -> tf.keras.Model:
    """Clear Keras state and build an untrained model.

    Every fold calls this, so no fold can inherit weights from the fold before it.
    """
    tf.keras.backend.clear_session()
    tf.keras.utils.set_random_seed(seed)
    return build_model(num_classes)


def save_atomically(path: Path, write) -> None:
    """Write to a .pending file first, so a crash cannot leave the API half a file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    pending = path.with_suffix(f".pending{path.suffix}")
    write(pending)
    pending.replace(path)


def train_deployment_model(scanned, best_epochs, batch_size: int, seed: int, model_path: Path):
    """Train the model FastAPI will serve, using every image in the dataset.

    The epoch count is the median best epoch from the five folds, because there is no
    validation set left to early-stop on. No accuracy is claimed for this model: the
    five-fold numbers are the honest measurement.
    """
    epochs = max(1, int(np.median(best_epochs)))
    print(f"\nTraining the deployment model on all {len(scanned.paths)} images "
          f"for {epochs} epoch(s).")

    model = start_fresh_model(len(scanned.class_names), seed)
    model.fit(
        make_dataset(scanned.paths, scanned.labels, batch_size, True, seed),
        epochs=epochs,
        class_weight=compute_class_weights(scanned.labels, len(scanned.class_names)),
        verbose=2,
    )

    model_path = Path(model_path)
    model_dir = model_path.parent
    save_atomically(model_path, model.save)
    save_atomically(
        model_dir / "class_names.json",
        lambda target: target.write_text(
            json.dumps(scanned.class_names, indent=2), encoding="utf-8"
        ),
    )
    print(f"Saved deployment model: {model_path}")
    print(f"Saved class order: {model_dir / 'class_names.json'}")

    save_calibration_cache(model, scanned, model_dir / "support_embeddings.npz")
    return model


def save_calibration_cache(model, scanned, output_path=None) -> None:
    """Write artifacts/model/support_embeddings.npz: one embedding per image.

    A research side artifact, not part of serving. POST /predict reports the CNN's
    own class and confidence, so nothing in main.py reads this file. Imported here
    rather than at the top so a problem building it can never stop the model from
    being saved.
    """
    try:
        from ml.model_calibration import save_support_embeddings

        samples = list(zip(scanned.labels.tolist(), scanned.paths.tolist()))
        kwargs = {"output_path": output_path} if output_path is not None else {}
        count = save_support_embeddings(model, scanned.class_names, samples=samples, **kwargs)
        print(f"Saved {count} support embedding(s) (not used by /predict).")
    except Exception as error:
        print(f"Warning: could not build the support embedding cache: {error}")


if __name__ == "__main__":
    raise SystemExit(
        "train_model.py holds the model code and is imported by train_5fold.py.\n"
        "Run the training with:\n"
        "  .\\.venv\\Scripts\\python.exe -m ml.train_5fold --epochs 30"
    )
