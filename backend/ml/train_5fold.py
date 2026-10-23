"""Group-aware five-fold cross-validation for the rice grade classifier.

Check the dataset without training anything:

    .\\.venv\\Scripts\\python.exe -m ml.train_5fold --check-only

Run this to measure the model and to produce the file FastAPI serves:

    .\\.venv\\Scripts\\python.exe -m ml.train_5fold --epochs 30

Every image belongs to a batch folder standing for one physical rice sample, and a
whole batch always stays on one side of a split. Without that rule two photos of the
same rice could land in training and evaluation, and the reported accuracy would
mostly measure memorisation.

This file is the controller. The model lives in train_model.py, the data pipeline in
image_preprocessing.py, and the scoring in evaluate_model.py.
"""

import argparse
import gc
import sys
import time
from pathlib import Path

try:
    from app.paths import BACKEND_DIR, DATASET_DIR, MODEL_DIR, RESULTS_DIR
    from scripts.python_env import use_local_venv
except ModuleNotFoundError as error:
    # "python ml/train_5fold.py" puts ml/ on the import path instead of backend/, so
    # the sibling packages are invisible. Running it as a module fixes that.
    raise SystemExit(
        f"Cannot import '{error.name}'. Run this from the backend folder as a "
        "module:\n"
        r"  .\.venv\Scripts\python.exe -m ml.train_5fold --check-only"
    ) from error

use_local_venv()

try:
    import numpy as np
    import tensorflow as tf
    from sklearn.model_selection import StratifiedGroupKFold
except ModuleNotFoundError as error:
    sys.exit(
        f"Missing Python package '{error.name}'. Install the requirements with:\n"
        r"  .\.venv\Scripts\python.exe -m pip install -r requirements-training.txt"
    )

from ml import evaluate_model, train_model
from ml.image_preprocessing import (
    DatasetError,
    check_ready_for_training,
    describe_dataset,
    make_dataset,
    scan_dataset,
)

OUTER_FOLDS = 5
# The development half of each fold is split 3:1 into training and validation.
INNER_FOLDS = 4
SPLIT_NAMES = ("training", "validation", "evaluation")


def build_folds(scanned, seed: int) -> list:
    """Create five folds of (training, validation, evaluation) row numbers.

    StratifiedGroupKFold keeps each batch whole and each fold balanced by grade. The
    outer split holds one fifth back for evaluation; the inner split then carves a
    validation set out of the remaining four fifths, so the evaluation fold is never
    involved in early stopping.
    """
    outer = StratifiedGroupKFold(n_splits=OUTER_FOLDS, shuffle=True, random_state=seed)
    folds = []

    try:
        outer_splits = outer.split(scanned.paths, scanned.labels, scanned.groups)
        for number, (development, evaluation) in enumerate(outer_splits, start=1):
            inner = StratifiedGroupKFold(
                n_splits=INNER_FOLDS, shuffle=True, random_state=seed + number
            )
            inner_splits = inner.split(
                scanned.paths[development],
                scanned.labels[development],
                scanned.groups[development],
            )
            train_rows, validation_rows = next(inner_splits)
            folds.append(
                (development[train_rows], development[validation_rows], evaluation)
            )
    except ValueError as error:
        raise DatasetError(
            f"Could not build {OUTER_FOLDS} balanced folds: {error}\n"
            "Every grade has enough batches, but they are too uneven in size to "
            "balance. Even the images out per batch as you collect more samples."
        ) from error

    check_folds(folds, scanned)
    return folds


def check_folds(folds: list, scanned) -> None:
    """Prove there is no leakage before a single model is built.

    Confirms no batch is shared between two splits of a fold, and that every split
    still contains all the grades being trained.
    """
    grade_count = len(scanned.class_names)

    for number, splits in enumerate(folds, start=1):
        for left in range(len(splits)):
            for right in range(left + 1, len(splits)):
                shared = set(scanned.groups[splits[left]]) & set(scanned.groups[splits[right]])
                if shared:
                    raise DatasetError(
                        f"Fold {number}: {SPLIT_NAMES[left]} and {SPLIT_NAMES[right]} "
                        f"share batch(es) {', '.join(sorted(shared))}."
                    )

        for rows, split_name in zip(splits, SPLIT_NAMES):
            if len(set(scanned.labels[rows].tolist())) != grade_count:
                raise DatasetError(
                    f"Fold {number}: the {split_name} split is missing at least one grade. "
                    "Add more batches so every grade can appear in every split."
                )


def fold_dataset(scanned, rows, args, training: bool):
    """The tf.data pipeline for one split. Only the training split is augmented."""
    return make_dataset(
        scanned.paths[rows], scanned.labels[rows], args.batch_size, training, args.seed
    )


def run_one_fold(number: int, splits, scanned, args) -> dict:
    """Train a brand new model on one fold and score it on the untouched split."""
    train_rows, validation_rows, evaluation_rows = splits
    sizes = ", ".join(
        f"{name} {len(rows)} image(s)/{len(set(scanned.groups[rows]))} batch(es)"
        for name, rows in zip(SPLIT_NAMES, splits)
    )
    print(f"\nFold {number} of {OUTER_FOLDS}: {sizes}")

    grade_count = len(scanned.class_names)
    # A fresh model per fold, so no fold can inherit the previous fold's weights.
    model = train_model.start_fresh_model(grade_count, args.seed + number)

    started = time.perf_counter()
    history = model.fit(
        fold_dataset(scanned, train_rows, args, True),
        validation_data=fold_dataset(scanned, validation_rows, args, False),
        epochs=args.epochs,
        callbacks=train_model.build_callbacks(
            MODEL_DIR / "cross_validation" / f"fold_{number}.keras"
        ),
        class_weight=train_model.compute_class_weights(
            scanned.labels[train_rows], grade_count
        ),
        verbose=2,
    )

    # The evaluation split is scored straight from its image paths, not through the
    # tf.data pipeline, so it goes through the same deterministic crop POST /predict
    # uses. Validation above keeps using the pipeline; it only drives early stopping.
    result = evaluate_model.evaluate_fold(
        model,
        scanned.paths[evaluation_rows],
        scanned.labels[evaluation_rows],
        scanned.class_names,
    )
    result.update(
        {
            "fold": number,
            "best_epoch": evaluate_model.find_best_epoch(history),
            "seconds": round(time.perf_counter() - started, 1),
            **{
                f"{name}_images": int(len(rows))
                for name, rows in zip(SPLIT_NAMES, splits)
            },
        }
    )

    # Release the fold's model before the next one is built.
    del model, history
    gc.collect()
    return result


def run(args) -> None:
    tf.keras.utils.set_random_seed(args.seed)
    dataset_dir = resolve_path(args.dataset)
    results_dir = resolve_path(args.results_dir)
    model_path = resolve_path(args.output_model)

    if model_path.suffix.lower() != ".keras":
        raise ValueError("--output-model must end with .keras")

    scanned = scan_dataset(dataset_dir)
    describe_dataset(scanned)
    check_ready_for_training(scanned, OUTER_FOLDS)
    folds = build_folds(scanned, args.seed)
    print(f"Dataset is ready for grouped {OUTER_FOLDS}-fold cross-validation.")
    if args.check_only:
        return

    fold_results = []
    for number, splits in enumerate(folds, start=1):
        result = run_one_fold(number, splits, scanned, args)
        fold_results.append(result)

        evaluate_model.save_fold_results(fold_results, results_dir, OUTER_FOLDS)
        evaluate_model.save_confusion_matrix(
            result["confusion_matrix"],
            scanned.class_names,
            results_dir / f"confusion_fold_{number}.png",
            f"Fold {number} confusion matrix",
        )
        print(
            f"Fold {number} result: accuracy={result['accuracy']:.4f}, "
            f"macro F1={result['f1_score']:.4f}, best epoch={result['best_epoch']}"
        )

    print("\n" + evaluate_model.save_fold_results(fold_results, results_dir, OUTER_FOLDS))
    evaluate_model.save_confusion_matrix(
        np.sum([result["confusion_matrix"] for result in fold_results], axis=0),
        scanned.class_names,
        results_dir / "confusion_overall.png",
        "All five evaluation folds combined",
    )

    # The detailed evaluation results are already preserved under results_dir.
    # Keep the currently served model's metrics untouched if final training fails.
    train_model.train_deployment_model(
        scanned,
        [result["best_epoch"] for result in fold_results],
        args.batch_size,
        args.seed,
        model_path,
    )
    evaluate_model.save_dashboard_metrics(
        fold_results, scanned, model_path.parent / "metrics.json"
    )
    print(f"Saved dashboard metrics: {model_path.parent / 'metrics.json'}")
    print("No accuracy is claimed for the deployment model; the folds are the measurement.")


def resolve_path(path: Path) -> Path:
    """Paths are read relative to backend/, wherever the script was launched from."""
    return path if path.is_absolute() else BACKEND_DIR / path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Train and measure the rice classifier with group-aware 5-fold CV."
    )
    parser.add_argument("--dataset", type=Path, default=DATASET_DIR)
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument(
        "--output-model", type=Path, default=MODEL_DIR / "rice_cnn_model.keras"
    )
    parser.add_argument("--results-dir", type=Path, default=RESULTS_DIR / "5fold")
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Run the dataset pre-flight and stop, without training anything.",
    )

    args = parser.parse_args()
    if args.epochs < 1 or args.batch_size < 1:
        parser.error("--epochs and --batch-size must be 1 or more.")
    return args


def main() -> int:
    args = parse_args()
    try:
        run(args)
    except DatasetError as error:
        # The dataset report has already been printed; keep the error after it.
        sys.stdout.flush()
        print(
            f"\nThe dataset is not ready for grouped {OUTER_FOLDS}-fold "
            f"cross-validation:\n\n{error}\n\n"
            "One batch folder is one physical rice sample. Photograph a new independent\n"
            "sample into each empty batch folder; never split one sample across folders\n"
            "and never copy images between them. Nothing was trained and nothing was "
            "changed.",
            file=sys.stderr,
        )
        return 2
    except (OSError, RuntimeError, ValueError) as error:
        print(f"\nTraining stopped safely: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
