"""Dataset scanning and image loading, shared by training and the FastAPI server.

Both paths must see the same kind of picture. load_inference_image() is the one
official rule - a single centre square crop covering 65% of the shorter edge - and
POST /predict and the evaluation fold both go through it. Training takes random
square crops around that size, which is itself an augmentation. Training on whole
squashed frames while serving zoomed crops would make the measured accuracy
describe a model the API never actually runs.
"""

import hashlib
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
    "Poor-Quality-Rice-Mix",
]

IMAGE_SIZE = (224, 224)
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png"}
# Decode only one full phone photo at a time. AUTOTUNE can hold many 12-25 MP
# originals in memory, which is unsafe on a small training/deployment machine.
DATA_PIPELINE_PARALLELISM = 1
MAX_IMAGE_PIXELS = 25_000_000

# One batch folder is one physical rice sample, and a new batch folder is created
# only when another independent sample is collected. Photos of one sample are never
# spread over several batch folders: that would hand the same rice to two folds.
#
# An empty batch folder is a placeholder for a sample not yet collected. It is
# reported, never counted as a group, and never reaches the fold builder.
#
# The collection target is 25-30 valid unique images per independent batch. It is
# advice for the person holding the camera, not a hard CNN requirement and not a
# rule the scanner enforces: a batch outside it is reported and still used.
TARGET_IMAGES_PER_BATCH = (25, 30)

# Square side as a fraction of the shorter edge.
PREDICTION_CROP_SCALE = 0.65
# Training samples around the prediction scale so the model sees that zoom level.
TRAIN_CROP_MIN = 0.50
TRAIN_CROP_MAX = 0.80


class DatasetError(ValueError):
    """The dataset cannot be split into leakage-free folds."""


class ScannedDataset(NamedTuple):
    """Every usable image, plus the batch group that keeps the folds honest."""

    paths: np.ndarray
    labels: np.ndarray
    groups: np.ndarray
    class_names: list  # grades that have images to train on
    reserved: list  # grades still waiting to be photographed
    batches: dict  # grade -> {batch name: image count}, empty batches included
    problems: list  # (reason, path) for every file that could not be used

    def usable_batches(self, class_name: str) -> list:
        """Batch folders holding at least one image. Only these are real groups."""
        return [name for name, count in self.batches.get(class_name, {}).items() if count]

    def empty_batches(self, class_name: str) -> list:
        """Placeholder folders waiting for a sample. Never counted as groups."""
        return [
            name for name, count in self.batches.get(class_name, {}).items() if not count
        ]


def load_rgb_image(image_path):
    """Fully decode one bounded, orientation-corrected RGB still image."""
    with Image.open(image_path) as source:
        if source.width * source.height > MAX_IMAGE_PIXELS:
            raise ValueError(
                f"Image dimensions exceed the {MAX_IMAGE_PIXELS:,} pixel limit."
            )
        if source.format not in {"JPEG", "PNG", "WEBP"}:
            raise ValueError("Only JPEG, PNG and WebP images are supported.")
        if getattr(source, "n_frames", 1) != 1:
            raise ValueError("Animated or multiple-frame images are not supported.")
        # load() catches truncated JPEG files that Pillow's verify() can accept.
        source.load()
        return ImageOps.exif_transpose(source).convert("RGB")


def load_inference_image(image_path):
    """The one 224x224 RGB picture every official prediction is made from.

    POST /predict and the evaluation fold in evaluate_model.py both call this, so
    a reported score always describes the behaviour the app demonstrates. Nothing
    here is random or averaged: one centre crop, decoded and resized one way.

    EXIF orientation is applied, because a phone writes a sideways photo with a
    rotation flag rather than rotated pixels.
    """
    image = load_rgb_image(image_path)

    width, height = image.size
    side = max(1, int(min(width, height) * PREDICTION_CROP_SCALE))
    left = (width - side) // 2
    top = (height - side) // 2
    crop = image.crop((left, top, left + side, top + side))

    # The filter is named rather than left to a library default, so the same file
    # always produces the same pixels. Pillow scales the filter to the resize
    # factor, so shrinking a large crop is already anti-aliased.
    return np.array(crop.resize(IMAGE_SIZE, Image.Resampling.BILINEAR), dtype=np.uint8)


def is_image(path: Path) -> bool:
    return path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS


def image_is_readable(path: Path) -> bool:
    """Open the file once up front so a corrupt image cannot crash training later."""
    try:
        with load_rgb_image(path):
            pass
        return True
    except (OSError, ValueError, Image.DecompressionBombError):
        return False


def scan_batches(class_dir: Path, fingerprints=None) -> tuple:
    """Map every batch folder inside one grade to its readable images.

    Returns the batch map and a list of (reason, path) for files that were skipped,
    so one unreadable photo is reported by name instead of surfacing later as a
    TensorFlow decode error. A batch with no images maps to an empty list.
    """
    batches, problems = {}, []
    if fingerprints is None:
        fingerprints = {}
    if not class_dir.is_dir():
        return batches, problems

    for batch_dir in sorted(path for path in class_dir.iterdir() if path.is_dir()):
        images = []
        for path in sorted(batch_dir.rglob("*")):
            if not path.is_file():
                continue
            if not is_image(path):
                problems.append(("unsupported file type", path))
            else:
                try:
                    with load_rgb_image(path) as image:
                        digest = hashlib.sha256(str(image.size).encode("ascii"))
                        digest.update(image.tobytes())
                    previous = fingerprints.setdefault(digest.digest(), path)
                    if previous != path:
                        problems.append((f"duplicate image pixels (same as {previous})", path))
                    images.append(path)
                except (OSError, ValueError, Image.DecompressionBombError):
                    problems.append(("corrupt or unreadable image", path))
        batches[batch_dir.name] = images
    return batches, problems


def batch_status(count: int) -> str:
    """How one batch sits against the collection target. Advisory, never an error.

    EMPTY at 0, UNDER TARGET below the target, READY inside it and OVER TARGET
    above it. Only check_ready_for_training decides whether a run may start.
    """
    low, high = TARGET_IMAGES_PER_BATCH
    if count == 0:
        return "EMPTY"
    if count < low:
        return "UNDER TARGET"
    if count <= high:
        return "READY"
    return "OVER TARGET"


def scan_dataset(dataset_dir: Path) -> ScannedDataset:
    """Read the dataset folder and describe exactly what is there.

    This reports; it does not judge. Empty batch folders, grades with no photos yet
    and unreadable files are all recorded rather than raised, so the pre-flight can
    print a full picture. Whether that picture is good enough to train on is asked
    separately by check_ready_for_training.

    The group id combines grade and batch (for example Premium_batch_01), so one
    batch can never be counted under two different grades.
    """
    if not dataset_dir.is_dir():
        raise DatasetError(f"Dataset folder not found: {dataset_dir}")

    batches_per_class = {}
    fingerprints = {}
    trainable, reserved, problems = [], [], []

    for class_name in CLASS_NAMES:
        class_dir = dataset_dir / class_name
        batches, batch_problems = scan_batches(class_dir, fingerprints)
        batches_per_class[class_name] = batches
        problems.extend(batch_problems)

        # An image sitting directly in the grade folder belongs to no sample, so it
        # would be silently left out of every fold. Reported, and refused by the
        # training check rather than quietly ignored.
        problems.extend(
            ("image outside any batch folder", path)
            for path in sorted(class_dir.glob("*"))
            if is_image(path)
        )

        # A grade with no images has simply not been collected yet. Only a batch
        # holding at least one image counts as collected.
        (trainable if any(batches.values()) else reserved).append(class_name)

    known_classes = set(CLASS_NAMES)
    for folder in sorted(dataset_dir.iterdir()):
        if folder.is_dir() and folder.name not in known_classes:
            problems.append(("unrecognized grade folder", folder))

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
        batches={
            class_name: {name: len(images) for name, images in batches.items()}
            for class_name, batches in batches_per_class.items()
        },
        problems=problems,
    )


def describe_dataset(scanned: ScannedDataset) -> None:
    """Print what was collected: every grade, its batches, and anything unusable.

    This is the dataset report, not the training decision. Nothing here stops a run;
    check_ready_for_training does that.
    """
    for class_name in CLASS_NAMES:
        batches = scanned.batches.get(class_name, {})
        usable = scanned.usable_batches(class_name)
        empty = scanned.empty_batches(class_name)

        print(f"\n{class_name}")
        if not batches:
            print("  no batch folders yet")
            continue

        for name, count in sorted(batches.items()):
            print(f"  {name}: {count} images  {batch_status(count)}")
        print(f"  usable batches: {len(usable)}   empty future batches: {len(empty)}")
        print(f"  images: {sum(batches.values())}")

    print("\nSummary")
    print(f"  total images: {len(scanned.paths)}")
    print(f"  usable groups: {len(set(scanned.groups.tolist()))}")
    print(f"  grades with images: {', '.join(scanned.class_names) or 'none'}")
    print(f"  grades not collected yet: {', '.join(scanned.reserved) or 'none'}")
    low, high = TARGET_IMAGES_PER_BATCH
    print(f"  collection target: {low}-{high} valid unique images per batch "
          "(advisory, not a hard CNN requirement)")

    if scanned.problems:
        print(f"\nUnusable files ({len(scanned.problems)}):")
        for reason, path in scanned.problems:
            print(f"  {reason}: {path}")
    print()


def describe_shortfall(class_name: str, usable: list, empty: list, folds: int) -> str:
    """Say how far one grade is from having a non-empty batch per fold."""
    batch_word = "batch" if len(usable) == 1 else "batches"
    message = (
        f"{class_name} has {len(usable)} non-empty independent {batch_word}.\n"
        f"{folds} are required for grouped {folds}-fold cross-validation."
    )
    if empty:
        return message + f"\nCollect images for {', '.join(sorted(empty))} before training."
    return message + (
        f"\nCreate {folds - len(usable)} more batch folder(s) for {class_name} and "
        f"photograph a new independent sample into each."
    )


def check_ready_for_training(scanned: ScannedDataset, folds: int) -> None:
    """Refuse to train unless the dataset can actually support grouped folds.

    Three things have to hold: every grade has photos, every grade has at least one
    non-empty batch per fold, and no image sits outside a batch folder. A batch is a
    group, never a fold - more batches than folds is good, fewer means some fold
    would be handed a sample the model already trained on.
    """
    if folds < 2:
        raise DatasetError("Grouped cross-validation needs at least two folds.")
    problems = [f"{name} has no images." for name in scanned.reserved]

    for class_name in scanned.class_names:
        usable = scanned.usable_batches(class_name)
        if len(usable) < folds:
            problems.append(
                describe_shortfall(
                    class_name, usable, scanned.empty_batches(class_name), folds
                )
            )

    stray = [path for reason, path in scanned.problems if reason.startswith("image outside")]
    if stray:
        listed = "\n".join(f"  {path}" for path in stray)
        problems.append(
            f"{len(stray)} image(s) sit outside any batch folder and would be left "
            f"out of every fold:\n{listed}\n"
            "Move each one into the batch folder for the sample it was photographed from."
        )

    integrity = [
        (reason, path) for reason, path in scanned.problems
        if reason.startswith(("duplicate image pixels", "unrecognized grade folder"))
    ]
    if integrity:
        listed = "\n".join(f"  {reason}: {path}" for reason, path in integrity)
        problems.append(
            "Dataset integrity problems must be reviewed before training:\n" + listed
        )

    if problems:
        raise DatasetError("\n\n".join(problems))


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
    def decode(value):
        filename = value.item() if isinstance(value, np.ndarray) else value
        if not training:
            return load_inference_image(filename)
        with load_rgb_image(filename) as source:
            return np.asarray(source, dtype=np.uint8)

    # Use the same Pillow decoder for training, validation and serving, including
    # EXIF rotation. TensorFlow's JPEG decoder ignores that phone orientation tag.
    image = tf.numpy_function(decode, [path], tf.uint8)
    if not training:
        return tf.ensure_shape(tf.cast(image, tf.float32), [*IMAGE_SIZE, 3]), label
    image = tf.ensure_shape(image, [None, None, 3])

    if training:
        scale = tf.random.uniform([], TRAIN_CROP_MIN, TRAIN_CROP_MAX)
        vertical = tf.random.uniform([], 0.0, 1.0)
        horizontal = tf.random.uniform([], 0.0, 1.0)
    image = square_crop(image, scale, vertical, horizontal)
    image = tf.image.resize(image, IMAGE_SIZE, antialias=True)
    return tf.clip_by_value(image, 0.0, 255.0), label


def make_dataset(paths, labels, batch_size: int, training: bool, seed: int):
    """Build a tf.data pipeline. Only training data is shuffled."""
    # An empty split would otherwise reach Keras as a dataset that yields nothing,
    # which fails much later with an error that says nothing about the cause.
    if len(paths) == 0:
        raise DatasetError("Cannot build a dataset from zero images.")
    if len(paths) != len(labels):
        raise DatasetError("Every image must have exactly one label.")
    if batch_size < 1:
        raise DatasetError("Batch size must be at least one.")

    dataset = tf.data.Dataset.from_tensor_slices((paths, labels))
    if training:
        dataset = dataset.shuffle(len(paths), seed=seed, reshuffle_each_iteration=True)

    dataset = dataset.map(
        lambda path, label: load_image(path, label, training),
        num_parallel_calls=DATA_PIPELINE_PARALLELISM,
    )
    return dataset.batch(batch_size).prefetch(1)
