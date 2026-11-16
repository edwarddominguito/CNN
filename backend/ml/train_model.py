"""The CNN itself: architecture, augmentation, callbacks, fine-tuning, and the final model.

Import this from train_5fold.py. Running it directly does nothing useful, because a
single train/validation split cannot measure this dataset honestly - there are only
a handful of physical rice samples per grade, so one split would hide most of the
variation that the grouped five-fold run reports.
"""

import json
import os
import tempfile
from pathlib import Path

import numpy as np
import tensorflow as tf

from ml.image_preprocessing import IMAGE_SIZE, make_dataset

# model_calibration.py imports this name to find the layer whose output it
# caches as the support embeddings.
EMBEDDING_LAYER_NAME = "rice_embedding"

EARLY_STOPPING_PATIENCE = 5
REDUCE_LR_PATIENCE = 2

# Phase 1 trains only the new classifier head on the frozen backbone. 0.001 is Adam's
# own default, which this model has always trained with; it is written out so the
# fine-tuning rate below is visibly derived from it.
HEAD_LEARNING_RATE = 1e-3

# Optional Phase 2 (train_5fold.py --fine-tune), following TensorFlow's transfer
# learning tutorial: once the head has trained, unfreeze only the top of MobileNetV2
# and keep training at a learning rate ten times lower, the tutorial's own ratio.
# block_16 is the last inverted-residual block. From its first layer to the end of
# the backbone are 11 of the 154 layers: block_16 and the final 1x1 Conv_1, the
# smallest complete unit at the top that includes a spatial (depthwise) filter. Their
# four convolutions train; their BatchNormalization layers stay frozen (see below).
FINE_TUNE_FROM_LAYER = "block_16_expand"
FINE_TUNE_LEARNING_RATE = HEAD_LEARNING_RATE / 10
FINE_TUNE_EPOCHS = 10


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
    compile_model(model, HEAD_LEARNING_RATE)
    return model


def compile_model(model: tf.keras.Model, learning_rate: float) -> None:
    """The multiclass softmax setup shared by both training phases."""
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=learning_rate),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )


def find_backbone(model: tf.keras.Model) -> tf.keras.Model:
    """The pretrained MobileNetV2 inside the rice model."""
    for layer in model.layers:
        if layer.name.startswith("mobilenetv2"):
            return layer
    raise ValueError("The model has no MobileNetV2 backbone.")


def unfreeze_top_of_backbone(model: tf.keras.Model) -> list:
    """Phase 2: let the top of MobileNetV2 train too, at a lower learning rate.

    Call this only after Phase 1 has trained the classifier head with the backbone
    frozen. A randomly initialised head would send large gradients into the
    pretrained layers and destroy what they learned on ImageNet.

    Every layer before FINE_TUNE_FROM_LAYER stays frozen, and so does every
    BatchNormalization layer after it. The tutorial keeps BatchNormalization in
    inference mode by calling the backbone with training=False, as build_model does.
    In Keras 3 that is not enough here: model.fit passes training=True down to every
    nested layer, overriding it, and a trainable BatchNormalization layer would then
    update its moving mean and variance on these small batches. A frozen one always
    runs in inference mode, so its statistics stay the ImageNet ones.

    Returns the names of the backbone layers whose weights now train.
    """
    backbone = find_backbone(model)
    names = [layer.name for layer in backbone.layers]
    fine_tune_at = names.index(FINE_TUNE_FROM_LAYER)

    backbone.trainable = True
    for layer in backbone.layers[:fine_tune_at]:
        layer.trainable = False
    for layer in backbone.layers[fine_tune_at:]:
        if isinstance(layer, tf.keras.layers.BatchNormalization):
            layer.trainable = False

    # A change to `trainable` only takes effect once the model is compiled again.
    compile_model(model, FINE_TUNE_LEARNING_RATE)
    return [layer.name for layer in backbone.layers if layer.trainable_weights]


def count_trainable_parameters(model: tf.keras.Model) -> int:
    return int(sum(np.prod(weight.shape) for weight in model.trainable_weights))


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
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, filename = tempfile.mkstemp(
        prefix=f"{path.stem}.", suffix=f".pending{path.suffix}", dir=path.parent
    )
    os.close(descriptor)
    pending = Path(filename)
    try:
        write(pending)
        pending.replace(path)
    finally:
        # A failed Keras save can leave megabytes behind. Unique staging also
        # prevents two writers from replacing one another's in-progress file.
        try:
            pending.unlink(missing_ok=True)
        except OSError:
            pass


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


def save_calibration_cache(model, scanned, output_path) -> None:
    """Write artifacts/model/support_embeddings.npz: one embedding per image.

    A research side artifact, not part of serving. POST /predict reports the CNN's
    own class and confidence, so nothing in main.py reads this file. Imported here
    rather than at the top so a problem building it can never stop the model from
    being saved.
    """
    try:
        from ml.model_calibration import save_support_embeddings

        samples = list(zip(scanned.labels.tolist(), scanned.paths.tolist()))
        count = save_support_embeddings(model, scanned.class_names, samples, output_path)
        print(f"Saved {count} support embedding(s) (not used by /predict).")
    except Exception as error:
        print(f"Warning: could not build the support embedding cache: {error}")


if __name__ == "__main__":
    raise SystemExit(
        "train_model.py holds the model code and is imported by train_5fold.py.\n"
        "Run the training with:\n"
        "  .\\.venv\\Scripts\\python.exe -m ml.train_5fold --epochs 30"
    )
