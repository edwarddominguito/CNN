import json
from pathlib import Path

from python_env import use_local_venv

use_local_venv()

import tensorflow as tf


BASE_DIR = Path(__file__).resolve().parent
DATASET_DIR = BASE_DIR / "dataset"
TRAIN_DIR = DATASET_DIR / "train"
VALIDATION_DIR = DATASET_DIR / "validation"
MODEL_DIR = BASE_DIR / "model"
MODEL_PATH = MODEL_DIR / "rice_cnn_model.keras"
CLASS_NAMES_PATH = MODEL_DIR / "class_names.json"

CLASS_NAMES = [
    "Premium",
    "Well-Milled",
    "Regular-Milled",
    "Poor-Quality-Rice-Mix",
]

IMAGE_SIZE = (224, 224)
BATCH_SIZE = 32
EPOCHS = 15
SEED = 42
IMAGE_EXTENSIONS = {".bmp", ".gif", ".jpeg", ".jpg", ".png"}


def validate_split(split_dir):
    if not split_dir.exists():
        raise FileNotFoundError(f"Missing dataset folder: {split_dir}")

    missing_classes = [
        class_name for class_name in CLASS_NAMES if not (split_dir / class_name).exists()
    ]
    if missing_classes:
        raise FileNotFoundError(
            f"Missing class folders in {split_dir}: {', '.join(missing_classes)}"
        )

    empty_classes = []
    for class_name in CLASS_NAMES:
        class_dir = split_dir / class_name
        image_count = sum(
            1
            for path in class_dir.iterdir()
            if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS
        )

        if image_count == 0:
            empty_classes.append(class_name)

    if empty_classes:
        raise ValueError(
            f"No valid images found in {split_dir} for: {', '.join(empty_classes)}. "
            f"Add .jpg, .jpeg, .png, .bmp, or .gif images to every class folder."
        )


def build_model(num_classes):
    inputs = tf.keras.Input(shape=(*IMAGE_SIZE, 3))

    x = tf.keras.layers.RandomFlip("horizontal")(inputs)
    x = tf.keras.layers.RandomRotation(0.08)(x)
    x = tf.keras.layers.RandomZoom(0.08)(x)
    x = tf.keras.layers.Rescaling(1.0 / 255)(x)

    x = tf.keras.layers.Conv2D(32, 3, activation="relu", padding="same")(x)
    x = tf.keras.layers.MaxPooling2D()(x)
    x = tf.keras.layers.Conv2D(64, 3, activation="relu", padding="same")(x)
    x = tf.keras.layers.MaxPooling2D()(x)
    x = tf.keras.layers.Conv2D(128, 3, activation="relu", padding="same")(x)
    x = tf.keras.layers.MaxPooling2D()(x)

    x = tf.keras.layers.GlobalAveragePooling2D()(x)
    x = tf.keras.layers.Dropout(0.3)(x)
    outputs = tf.keras.layers.Dense(num_classes, activation="softmax")(x)

    model = tf.keras.Model(inputs, outputs)
    model.compile(
        optimizer="adam",
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )
    return model


def main():
    validate_split(TRAIN_DIR)
    validate_split(VALIDATION_DIR)
    MODEL_DIR.mkdir(exist_ok=True)

    train_dataset = tf.keras.utils.image_dataset_from_directory(
        TRAIN_DIR,
        class_names=CLASS_NAMES,
        image_size=IMAGE_SIZE,
        batch_size=BATCH_SIZE,
        seed=SEED,
    )
    validation_dataset = tf.keras.utils.image_dataset_from_directory(
        VALIDATION_DIR,
        class_names=CLASS_NAMES,
        image_size=IMAGE_SIZE,
        batch_size=BATCH_SIZE,
        seed=SEED,
    )

    autotune = tf.data.AUTOTUNE
    train_dataset = train_dataset.cache().shuffle(1000).prefetch(autotune)
    validation_dataset = validation_dataset.cache().prefetch(autotune)

    model = build_model(num_classes=len(CLASS_NAMES))
    callbacks = [
        tf.keras.callbacks.EarlyStopping(
            monitor="val_loss",
            patience=4,
            restore_best_weights=True,
        )
    ]

    model.fit(
        train_dataset,
        validation_data=validation_dataset,
        epochs=EPOCHS,
        callbacks=callbacks,
    )

    model.save(MODEL_PATH)
    with CLASS_NAMES_PATH.open("w", encoding="utf-8") as file:
        json.dump(CLASS_NAMES, file, indent=2)

    print(f"Saved model to {MODEL_PATH}")
    print(f"Saved class names to {CLASS_NAMES_PATH}")


if __name__ == "__main__":
    main()
