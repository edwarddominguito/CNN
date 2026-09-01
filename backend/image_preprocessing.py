"""Dataset scanning and image loading, shared by training and the FastAPI server.

Both paths must see the same kind of picture. The API averages five square crops
covering 65% of the shorter edge, so training takes random square crops around that
size and validation takes the matching centre crop. Training on whole squashed
frames while serving zoomed crops would make the measured accuracy describe a model
the API never actually runs.
"""

from pathlib import Path
from typing import NamedTuple

import numpy as np
import tensorflow as tf
from PIL import Image, ImageOps

# The single place the grade order is defined. Every other file imports it, so the
# label a model learns and the label the apps display can never drift apart.
CLASS_NAMES = [
    "Premium",
    "Well-Milled",
    "Regular-Milled",
    "Poor-Quality-Rice-Mix",
]

IMAGE_SIZE = (224, 224)
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png"}
AUTOTUNE = tf.data.AUTOTUNE

# One batch folder is one physical rice sample. Five per grade means every fold can
# be handed a whole batch the model has never seen.
MIN_BATCHES_PER_CLASS = 5
MIN_TRAINABLE_CLASSES = 2

# Square side as a fraction of the shorter edge.
PREDICTION_CROP_SCALE = 0.65
# Training samples around the prediction scale so the model sees that zoom level.
TRAIN_CROP_MIN = 0.50
TRAIN_CROP_MAX = 0.80
PREDICTION_CROP_ANCHORS = [(0.5, 0.5), (0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)]


class DatasetError(ValueError):
    """The dataset cannot be split into leakage-free folds."""


class ScannedDataset(NamedTuple):
    """Every usable image, plus the batch group that keeps the folds honest."""

    paths: np.ndarray
    labels: np.ndarray
    groups: np.ndarray
    class_names: list  # grades that had enough images to train on
    reserved: list  # grades still waiting to be photographed


def load_prediction_crops(image_path):
    """Return one 224x224 RGB crop per anchor, de-duplicated, as a stacked array.

    Used by FastAPI and by the calibrator. Training mirrors this geometry.
    """
    with Image.open(image_path) as source:
        image = ImageOps.exif_transpose(source).convert("RGB")

    width, height = image.size
    size = max(1, int(min(width, height) * PREDICTION_CROP_SCALE))

    boxes = []
    for x_anchor, y_anchor in PREDICTION_CROP_ANCHORS:
        left = int((width - size) * x_anchor)
        top = int((height - size) * y_anchor)
        box = (left, top, left + size, top + size)
        if box not in boxes:
            boxes.append(box)

    return np.stack([np.array(image.crop(box).resize(IMAGE_SIZE)) for box in boxes])


def is_image(path: Path) -> bool:
    return path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS


def image_is_readable(path: Path) -> bool:
    """Open the file once up front so a corrupt image cannot crash training later."""
    try:
        with Image.open(path) as image:
            image.verify()
        return True
    except (OSError, ValueError):
        print(f"Skipping unreadable image: {path}")
        return False


def scan_batches(class_dir: Path) -> dict:
    """Map every batch folder inside one grade to its readable images."""
    if not class_dir.is_dir():
        return {}

    batches = {}
    for batch_dir in sorted(path for path in class_dir.iterdir() if path.is_dir()):
        images = [path for path in sorted(batch_dir.rglob("*")) if is_image(path)]
        batches[batch_dir.name] = [path for path in images if image_is_readable(path)]
    return batches


def check_one_class(class_dir: Path, class_name: str, batches: dict) -> tuple:
    """Decide whether one grade is trainable, reserved, or a mistake to report.

    A grade with no images at all has simply not been photographed yet, so it is
    reserved and the run continues. A grade whose images sit in too few batches is a
    mistake: there is no way to give all five folds an unseen batch of it.
    """
    problems = []

    loose_images = [path for path in class_dir.glob("*") if is_image(path)]
    if loose_images:
        problems.append(
            f"{class_name} has {len(loose_images)} image(s) directly in its folder. "
            f"Move them into a batch folder such as {class_name}/batch_01."
        )

    total_images = sum(len(images) for images in batches.values())
    filled_batches = sum(1 for images in batches.values() if images)

    if total_images == 0:
        return "reserved", problems
    if filled_batches < MIN_BATCHES_PER_CLASS:
        problems.append(
            f"{class_name} has {total_images} image(s) in {filled_batches} non-empty "
            f"batch folder(s), but {MIN_BATCHES_PER_CLASS} are required. Spread the "
            f"images over more batches, or empty the folder to reserve the grade."
        )
        return "problem", problems
    return "trainable", problems


def scan_dataset(dataset_dir: Path) -> ScannedDataset:
    """Read the dataset folder and validate it before any model is built.

    The group id combines grade and batch (for example Premium_batch_01), so one
    batch can never be counted under two different grades.
    """
    if not dataset_dir.is_dir():
        raise DatasetError(f"Dataset folder does not exist: {dataset_dir}")

    batches_per_class = {}
    trainable, reserved, problems = [], [], []

    for class_name in CLASS_NAMES:
        class_dir = dataset_dir / class_name
        batches = scan_batches(class_dir)
        batches_per_class[class_name] = batches

        verdict, class_problems = check_one_class(class_dir, class_name, batches)
        problems.extend(class_problems)
        if verdict == "trainable":
            trainable.append(class_name)
        elif verdict == "reserved":
            reserved.append(class_name)

    if len(trainable) < MIN_TRAINABLE_CLASSES:
        problems.append(
            f"Only {len(trainable)} grade(s) have images, but at least "
            f"{MIN_TRAINABLE_CLASSES} are needed to train a classifier."
        )
    if problems:
        raise DatasetError("\n".join(f"- {problem}" for problem in problems))

    paths, labels, groups = [], [], []
    for label, class_name in enumerate(trainable):
        for batch_name, images in batches_per_class[class_name].items():
            for image_path in images:
                paths.append(str(image_path))
                labels.append(label)
                groups.append(f"{class_name}_{batch_name}")

    if len(set(paths)) != len(paths):
        raise DatasetError("The same image file appears more than once in the dataset.")

    return ScannedDataset(
        paths=np.array(paths),
        labels=np.array(labels, dtype=np.int32),
        groups=np.array(groups),
        class_names=trainable,
        reserved=reserved,
    )


def describe_dataset(scanned: ScannedDataset) -> None:
    """Print what will be trained, so a wrong dataset is obvious before training."""
    print(f"\nGrades to train: {', '.join(scanned.class_names)}")
    if scanned.reserved:
        print(f"Reserved grades (no images yet): {', '.join(scanned.reserved)}")

    for label, class_name in enumerate(scanned.class_names):
        selected = scanned.labels == label
        batch_count = len(set(scanned.groups[selected]))
        print(f"  {class_name}: {int(selected.sum())} image(s) in {batch_count} batch(es)")
    print(f"Total images: {len(scanned.paths)}\n")


def square_crop(image, scale, vertical_offset, horizontal_offset):
    """Cut a square whose side is `scale` of the shorter edge, at a relative offset."""
    shape = tf.shape(image)
    height, width = shape[0], shape[1]
    shorter_edge = tf.cast(tf.minimum(height, width), tf.float32)

    side = tf.maximum(tf.cast(shorter_edge * scale, tf.int32), 1)
    top = tf.cast(tf.cast(height - side, tf.float32) * vertical_offset, tf.int32)
    left = tf.cast(tf.cast(width - side, tf.float32) * horizontal_offset, tf.int32)
    return tf.image.crop_to_bounding_box(image, top, left, side, side)


def load_image(path, label, training: bool):
    """Decode one file and crop it the same way the API will crop it.

    Training randomises the crop size and position, which is itself an augmentation.
    Validation and evaluation take the fixed centre crop, matching the API exactly.
    """
    image = tf.io.decode_image(tf.io.read_file(path), channels=3, expand_animations=False)
    image = tf.ensure_shape(image, [None, None, 3])
    image = tf.cast(image, tf.float32)

    if training:
        scale = tf.random.uniform([], TRAIN_CROP_MIN, TRAIN_CROP_MAX)
        vertical = tf.random.uniform([], 0.0, 1.0)
        horizontal = tf.random.uniform([], 0.0, 1.0)
    else:
        scale = tf.constant(PREDICTION_CROP_SCALE)
        vertical = tf.constant(0.5)
        horizontal = tf.constant(0.5)

    image = square_crop(image, scale, vertical, horizontal)
    image = tf.image.resize(image, IMAGE_SIZE, antialias=True)
    return tf.clip_by_value(image, 0.0, 255.0), label


def make_dataset(paths, labels, batch_size: int, training: bool, seed: int):
    """Build a tf.data pipeline. Only training data is shuffled."""
    dataset = tf.data.Dataset.from_tensor_slices((paths, labels))
    if training:
        dataset = dataset.shuffle(len(paths), seed=seed, reshuffle_each_iteration=True)

    dataset = dataset.map(
        lambda path, label: load_image(path, label, training), num_parallel_calls=AUTOTUNE
    )
    return dataset.batch(batch_size).prefetch(AUTOTUNE)
