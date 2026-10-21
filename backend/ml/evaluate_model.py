"""Scoring one fold, and turning five folds into the numbers the apps display.

Every score here comes from an evaluation fold the model never trained on. Training
accuracy is deliberately never reported as a result.
"""

import json
from datetime import datetime, timezone
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from sklearn.metrics import accuracy_score, classification_report, confusion_matrix

from ml.image_preprocessing import CLASS_NAMES, load_inference_image
from ml.train_model import save_atomically

# The four headline scores, in the order the dashboards show them.
HEADLINE_METRICS = ("accuracy", "precision", "recall", "f1_score")


def evaluate_fold(model, image_paths, actual_labels, class_names: list, batch_size=32) -> dict:
    """Score one untouched evaluation fold exactly the way POST /predict answers.

    Every image goes through image_preprocessing.load_inference_image, the same
    single deterministic crop the API uses, and the grade is the CNN's argmax. So
    these scores measure the inference rule the app actually demonstrates.

    Macro averaging treats every grade equally, so a rare grade cannot be hidden by
    a common one. zero_division=0 keeps a grade that was never predicted at 0
    instead of crashing.
    """
    if len(image_paths) == 0 or len(image_paths) != len(actual_labels):
        raise ValueError("Evaluation requires a non-empty image list with one label per image.")
    if batch_size < 1:
        raise ValueError("Evaluation batch size must be at least one.")
    label_ids = range(len(class_names))
    # Keep only one small batch in memory rather than stacking the entire test
    # set. A larger future dataset must not exhaust RAM during evaluation.
    predictions = []
    for start in range(0, len(image_paths), batch_size):
        images = np.stack([
            load_inference_image(path) for path in image_paths[start:start + batch_size]
        ])
        probabilities = np.asarray(model.predict(images, verbose=0))
        real_dtype = (np.issubdtype(probabilities.dtype, np.floating)
                      or np.issubdtype(probabilities.dtype, np.integer))
        if (probabilities.shape != (len(images), len(class_names)) or not real_dtype
                or not np.isfinite(probabilities).all()):
            raise ValueError("The model returned invalid evaluation probabilities.")
        if (np.any(probabilities < 0) or np.any(probabilities > 1)
                or not np.allclose(probabilities.sum(axis=1), 1, atol=0.01)):
            raise ValueError("The model output is not a probability distribution.")
        predictions.extend(np.argmax(probabilities, axis=1).tolist())
    predicted_labels = np.asarray(predictions)

    report = classification_report(
        actual_labels,
        predicted_labels,
        labels=label_ids,
        target_names=class_names,
        output_dict=True,
        zero_division=0,
    )
    matrix = confusion_matrix(actual_labels, predicted_labels, labels=label_ids)

    return {
        "accuracy": float(accuracy_score(actual_labels, predicted_labels)),
        "precision": float(report["macro avg"]["precision"]),
        "recall": float(report["macro avg"]["recall"]),
        "f1_score": float(report["macro avg"]["f1-score"]),
        "per_class": {
            name: {
                "precision": float(report[name]["precision"]),
                "recall": float(report[name]["recall"]),
                "f1_score": float(report[name]["f1-score"]),
                "support": int(report[name]["support"]),
            }
            for name in class_names
        },
        "confusion_matrix": matrix.tolist(),
    }


def find_best_epoch(history) -> int:
    """The epoch with the lowest validation loss, ignoring any NaN epochs."""
    losses = np.asarray(history.history["val_loss"], dtype=float)
    usable = np.flatnonzero(np.isfinite(losses))
    if len(usable) == 0:
        raise RuntimeError("Training produced no usable validation loss.")
    return int(usable[np.argmin(losses[usable])]) + 1


def mean_and_deviation(fold_results: list, key: str) -> tuple:
    """Mean and sample standard deviation (ddof=1) of one metric across folds."""
    values = np.array([result[key] for result in fold_results], dtype=float)
    deviation = float(values.std(ddof=1)) if len(values) > 1 else 0.0
    return float(values.mean()), deviation


def summarize_folds(fold_results: list, planned_folds: int) -> str:
    """Readable summary of the folds run so far, for the console and a text file.

    An interrupted run must not leave a file that reads like a finished study, so
    a partial summary says so instead of quietly reporting a smaller fold count.
    """
    done = len(fold_results)
    lines = [f"Group-aware stratified {planned_folds}-fold cross-validation", ""]
    if done < planned_folds:
        lines[0] += f" - INCOMPLETE: {done} of {planned_folds} folds finished"
        lines.append("These numbers are a partial run. Do not report them.")
        lines.append("")

    for key in HEADLINE_METRICS:
        mean, deviation = mean_and_deviation(fold_results, key)
        label = key.replace("_", " ").title()
        lines.append(f"{label:10s}: {mean:.4f} +/- {deviation:.4f}")
    return "\n".join(lines) + "\n"


def write_json(path: Path, payload) -> None:
    content = json.dumps(payload, indent=2, allow_nan=False)
    save_atomically(path, lambda pending: pending.write_text(content, encoding="utf-8"))


def save_fold_results(fold_results: list, results_dir: Path, planned_folds: int) -> str:
    """Rewritten after every fold, so an interrupted run still leaves results."""
    write_json(results_dir / "cross_validation.json", fold_results)
    summary = summarize_folds(fold_results, planned_folds)
    (results_dir / "summary.txt").write_text(summary, encoding="utf-8")
    return summary


def save_confusion_matrix(matrix, class_names: list, path: Path, title: str) -> None:
    """Save one confusion matrix as a PNG for the written report."""
    matrix = np.asarray(matrix)
    figure, axis = plt.subplots(figsize=(7, 6))
    try:
        figure.colorbar(axis.imshow(matrix, cmap="Blues"), ax=axis)
        axis.set(
            title=title,
            xlabel="Predicted grade",
            ylabel="Actual grade",
            xticks=range(len(class_names)),
            yticks=range(len(class_names)),
            xticklabels=class_names,
            yticklabels=class_names,
        )
        plt.setp(axis.get_xticklabels(), rotation=30, ha="right")

        highest = matrix.max() if matrix.size else 0
        for (row, column), count in np.ndenumerate(matrix):
            shade = "white" if count > highest / 2 else "black"
            axis.text(column, row, count, ha="center", va="center", color=shade)

        figure.tight_layout()
        path.parent.mkdir(parents=True, exist_ok=True)
        figure.savefig(path, dpi=150)
    finally:
        plt.close(figure)


def average_per_class(fold_results: list, class_name: str, key: str) -> float:
    values = [result["per_class"][class_name][key] for result in fold_results]
    return round(float(np.mean(values)) * 100, 2)


def save_dashboard_metrics(fold_results: list, scanned, path: Path) -> None:
    """Write artifacts/model/metrics.json, which FastAPI serves at /metrics.

    Percent units and key names match what the Flutter and React apps already read,
    so the dashboards pick up cross-validated numbers without any frontend change.
    """
    trained = scanned.class_names
    summary = {key: mean_and_deviation(fold_results, key) for key in HEADLINE_METRICS}

    payload = {key: round(mean * 100, 2) for key, (mean, _) in summary.items()}
    payload.update(
        {f"{key}_std": round(deviation * 100, 2) for key, (_, deviation) in summary.items()}
    )
    payload.update(
        {
            "classes": trained,
            "all_classes": CLASS_NAMES,
            "trained_classes": trained,
            "reserved_classes": scanned.reserved,
            "class_status": [
                {
                    "name": name,
                    "trained": name in trained,
                    "status": "trained" if name in trained else "reserved",
                }
                for name in CLASS_NAMES
            ],
            "per_class": {
                name: {
                    key: average_per_class(fold_results, name, key)
                    for key in ("precision", "recall", "f1_score")
                }
                for name in trained
            },
            "evaluation_method": (
                f"Group-aware stratified {len(fold_results)}-fold cross-validation"
            ),
            "folds": len(fold_results),
            "evaluation_images": sum(
                result["evaluation_images"] for result in fold_results
            ),
            "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
    )
    write_json(path, payload)


if __name__ == "__main__":
    raise SystemExit(
        "evaluate_model.py holds the scoring code and is imported by train_5fold.py.\n"
        "Cross-validated results are written by:\n"
        "  .\\.venv\\Scripts\\python.exe -m ml.train_5fold --epochs 30"
    )
