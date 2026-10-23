# Training Code Guide

How the rice grading model is trained, measured, and served.

All training code lives in `backend/ml/`, the FastAPI server in `backend/app/`.
Paths shared by both are defined once in `backend/app/paths.py`.

## The four training files

| File | Responsibility |
|---|---|
| `ml/train_5fold.py` | **Controller.** Reads the command line, builds the folds, runs each fold, prints the summary, saves the final model. |
| `ml/image_preprocessing.py` | **Data.** Finds images, validates the dataset, loads and crops pictures, builds the `tf.data` pipeline. Also used by FastAPI. |
| `ml/train_model.py` | **Model.** Architecture, augmentation, callbacks, class weights, and the deployment model. |
| `ml/evaluate_model.py` | **Scoring.** Accuracy, macro precision/recall/F1, per-class scores, confusion matrices, mean and standard deviation. |

Two supporting files are not part of training but depend on it:

- `ml/model_calibration.py` — builds `artifacts/model/support_embeddings.npz`, one embedding per training image. **Not part of serving:** `app/main.py` does not import it. `ml/train_model.py` still writes the file as a research side artifact.
- `app/main.py` — the FastAPI server. It loads the model this pipeline saves.

## Dataset structure

```
backend/data/dataset/
  Premium/               Well-Milled/           Poor-Quality-Rice-Mix/
    batch_01/ .. batch_05/   batch_01/ .. batch_05/   batch_01/ .. batch_05/
```

Only `.jpg`, `.jpeg`, and `.png` files are read. `README.md` and any other file is ignored.

**One batch folder = one physical rice sample.** Every photo of that sample goes in
that one folder, even if you changed the angle or the lighting. Never copy a photo
into a second batch.

A grade with **no images at all** is reported as *reserved*, and training stops
until every configured grade has photos. Each grade needs at least five non-empty
batches so all five folds can receive an unseen batch of it.

The pre-flight also reports each batch against the project collection target of
25–30 valid unique images: `EMPTY` (0), `UNDER TARGET` (1–24), `READY` (25–30) or
`OVER TARGET` (more than 30). That status is advisory, not a hard CNN requirement —
a batch outside the range is still used and never stops a run.

## How batch grouping prevents data leakage

Two photos of the same rice sample look almost identical. If one lands in training
and the other in evaluation, the model can score well by recognising that exact
sample instead of learning what the grade looks like. The reported accuracy would be
inflated and would not survive contact with new rice.

Each image is tagged with a group id combining grade and batch:

```
Premium_batch_01     Well-Milled_batch_03
```

`StratifiedGroupKFold` never splits a group, so a whole batch always stays on one
side of every split. `ml/train_5fold.check_folds()` then proves it before any model is
built: it fails immediately if two splits of a fold share a batch, or if a split is
missing a grade.

## How five-fold cross-validation works

The batches are divided into 5 folds — so each grade needs at least 5 non-empty
batches before a run can start. For each fold:

1. Four fifths of the batches become the **development** set; one fifth is held back
   as the **evaluation** set and is not touched during training.
2. The development set is split again (group-aware) into **training** and
   **validation**.
3. A brand new CNN is built. `clear_session()` and a per-fold seed guarantee no fold
   inherits weights from the previous one.
4. Training uses augmentation. Validation drives early stopping and the learning-rate
   schedule.
5. The model is scored **once** on the untouched evaluation fold.

Because each batch is evaluated in exactly one fold, every image gets scored exactly
once across the five runs. The final result is the **mean and sample standard
deviation** (`np.std(..., ddof=1)`) of the five folds. Training accuracy is never
reported as a result.

## Preprocessing must match FastAPI

This is the subtle one. FastAPI does not send the whole photo to the model. It cuts
**one centre square crop covering 65% of the shorter edge**.

The reported score has to describe that exact behaviour, so there is a single
function — `ml/image_preprocessing.load_inference_image()` — and both the API and the
evaluation fold call it. Same decoder (Pillow), same EXIF handling, same centre crop,
same resize filter, one crop, no averaging.

- **Evaluation fold and `POST /predict`:** `load_inference_image()`. Identical.
- **Training:** random square crop between 50% and 80% of the shorter edge, at a
  random position, through the `tf.data` pipeline. The randomness is itself an
  augmentation, and it is deliberately *not* made deterministic.
- **Validation:** the `tf.data` pipeline with `training=False`. It only drives early
  stopping and the learning-rate schedule, never a reported number.

If training used the whole squashed photo while the API used zoomed crops, the model
would be measured on pictures it never sees in production.

## Execution flow

```
train_5fold.main()
  └── parse_args()
  └── run()
        ├── image_preprocessing.scan_dataset()     find + validate images
        ├── build_folds() → check_folds()          5 folds, proven leak-free
        ├── for each fold: run_one_fold()
        │     ├── train_model.start_fresh_model()  new CNN, cleared session
        │     ├── model.fit(...)                   augmented training data
        │     └── evaluate_model.evaluate_fold()   score the untouched fold
        ├── evaluate_model.save_fold_results()     after every fold
        ├── train_model.train_deployment_model()   all images, median best epoch
        │     └── save_calibration_cache()         → artifacts/model/support_embeddings.npz
        └── evaluate_model.save_dashboard_metrics()  → artifacts/model/metrics.json
```

## Command

The deployment metrics are published only after the final model trains and saves
successfully. A failed final training run preserves the previous metrics; detailed
fold results remain available under the results directory.

Run from the `backend` folder, as a module so the `ml` package resolves:

```powershell
.\.venv\Scripts\python.exe -m ml.train_5fold --epochs 30 --batch-size 32
```

Options: `--dataset`, `--epochs`, `--batch-size`, `--seed`, `--output-model`,
`--results-dir`.

Use the Python inside `.venv`. The system `pip` points at a different Python version.

## Output locations

All under `backend/`, and all regenerable — see `app/paths.py`.

| Path | Contents |
|---|---|
| `artifacts/model/rice_cnn_model.keras` | The model FastAPI serves |
| `artifacts/model/class_names.json` | Label order — index 0 is the first name |
| `artifacts/model/metrics.json` | Cross-validated scores, served at `/metrics` |
| `artifacts/model/support_embeddings.npz` | Support embedding cache, unused by `/predict` |
| `artifacts/model/cross_validation/fold_N.keras` | Per-fold checkpoints |
| `artifacts/results/5fold/cross_validation.json` | Full per-fold results |
| `artifacts/results/5fold/summary.txt` | Mean ± standard deviation |
| `artifacts/results/5fold/confusion_fold_N.png` | Per-fold confusion matrix |
| `artifacts/results/5fold/confusion_overall.png` | All five folds combined |

Files are written through a `.pending` file and then renamed, so an interrupted run
cannot leave the API reading half a file.

## How FastAPI loads the final model

At startup `app/main.py`:

1. Requires `artifacts/model/class_names.json` to exist and to list **exactly** the
   grades in `ml/image_preprocessing.CLASS_NAMES`, in the same order. Output count is not enough
   on its own: two different three-class models can mean different things by index 0.
2. Loads `artifacts/model/rice_cnn_model.keras`.
3. **Checks that the model's output count matches the number of labels.** If anything
   disagrees it refuses to serve the model, because it would otherwise return
   confident predictions under the wrong grade names.

On `POST /predict` it saves the upload, builds the one official crop, takes the CNN's
`argmax` as the grade and that class's softmax value as the confidence, stores the
result in MySQL, and returns it with a `history_saved` flag and the saved record's
`history_id` when persistence succeeds. Temporary uploads are
deleted after every completed request. Nothing adjusts or overrides the CNN. It answers
**503** with no usable model, **400** for an empty or unreadable upload, and **500**
if inference itself fails; failed predictions write no history row. Oversized files
return **413**, and excess simultaneous predictions receive a retryable **503**.

`GET /metrics` reports `classes` (the configured grades) and `trained_classes` (what a
loaded, compatible model can predict — empty when there is none). It serves
`artifacts/model/metrics.json`; until a run writes that file it answers
`evaluation_available: false` with every score `null`, so scores from an older dataset
are never reported as current.

The final model is trained on **all** images for the median best epoch from the five
folds. No separate accuracy is claimed for it — the five-fold numbers are the honest
measurement.
