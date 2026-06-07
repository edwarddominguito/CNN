import json
from pathlib import Path

from python_env import use_local_venv

use_local_venv()

import tensorflow as tf


BASE_DIR = Path(__file__).resolve().parent
TEST_DIR = BASE_DIR / "dataset" / "test"
MODEL_PATH = BASE_DIR / "model" / "rice_cnn_model.keras"
CLASS_NAMES_PATH = BASE_DIR / "model" / "class_names.json"

DEFAULT_CLASS_NAMES = [
    "Premium",
    "Well-Milled",
    "Regular-Milled",
    "Poor-Quality-Rice-Mix",
]

IMAGE_SIZE = (224, 224)
BATCH_SIZE = 32
IMAGE_EXTENSIONS = {".bmp", ".gif", ".jpeg", ".jpg", ".png"}


def load_class_names():
    if CLASS_NAMES_PATH.exists():
        with CLASS_NAMES_PATH.open("r", encoding="utf-8") as file:
            return json.load(file)

    return DEFAULT_CLASS_NAMES


def main():
    if not MODEL_PATH.exists():
        raise FileNotFoundError(f"Missing trained model: {MODEL_PATH}")
    if not TEST_DIR.exists():
        raise FileNotFoundError(f"Missing test dataset folder: {TEST_DIR}")

    class_names = load_class_names()
    missing_classes = [
        class_name for class_name in class_names if not (TEST_DIR / class_name).exists()
    ]
    if missing_classes:
        raise FileNotFoundError(
            f"Missing class folders in {TEST_DIR}: {', '.join(missing_classes)}"
        )

    empty_classes = []
    for class_name in class_names:
        class_dir = TEST_DIR / class_name
        image_count = sum(
            1
            for path in class_dir.iterdir()
            if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS
        )

        if image_count == 0:
            empty_classes.append(class_name)

    if empty_classes:
        raise ValueError(
            f"No valid test images found for: {', '.join(empty_classes)}. "
            f"Add .jpg, .jpeg, .png, .bmp, or .gif images to every test class folder."
        )

    model = tf.keras.models.load_model(MODEL_PATH)
    test_dataset = tf.keras.utils.image_dataset_from_directory(
        TEST_DIR,
        class_names=class_names,
        image_size=IMAGE_SIZE,
        batch_size=BATCH_SIZE,
        shuffle=False,
    )

    loss, accuracy = model.evaluate(test_dataset, verbose=1)
    print(f"Test loss: {loss:.4f}")
    print(f"Test accuracy: {accuracy:.4f}")

    true_labels = []
    predicted_labels = []

    for images, labels in test_dataset:
        predictions = model.predict(images, verbose=0)
        true_labels.extend(labels.numpy().tolist())
        predicted_labels.extend(tf.argmax(predictions, axis=1).numpy().tolist())

    matrix = tf.math.confusion_matrix(
        true_labels,
        predicted_labels,
        num_classes=len(class_names),
    ).numpy()

    print("Class order:")
    for index, class_name in enumerate(class_names):
        print(f"{index}: {class_name}")

    print("Confusion matrix:")
    print(matrix)


if __name__ == "__main__":
    main()
