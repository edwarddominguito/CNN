# Training Code Guide

How the rice grading model is trained, measured, and served.

## The four training files

| File | Responsibility |
|---|---|
| `train_5fold.py` | **Controller.** Reads the command line, builds the folds, runs each fold, prints the summary, saves the final model. |
| `image_preprocessing.py` | **Data.** Finds images, validates the dataset, loads and crops pictures, builds the `tf.data` pipeline. Also used by FastAPI. |
| `train_model.py` | **Model.** Architecture, augmentation, callbacks, class weights, and the deployment model. |
| `evaluate_model.py` | **Scoring.** Accuracy, macro precision/recall/F1, per-class scores, confusion matrices, mean and standard deviation. |

Two supporting files are not part of training but depend on it:

- `model_calibration.py` — nudges a prediction toward the nearest training images it recognises. **Still in use:** `main.py` imports it, and `train_model.py` refreshes its cache after training.
- `main.py` — the FastAPI server. It loads the model this pipeline saves.

## Dataset structure

```
dataset/
  Premium/               Well-Milled/           Regular-Milled/        Poor-Quality-Rice-Mix/
    batch_01/ .. batch_05/   batch_01/ .. batch_05/   batch_01/ .. batch_05/   batch_01/ .. batch_05/
```

Only `.jpg`, `.jpeg`, and `.png` files are read. `README.md` and any other file is ignored.

**One batch folder = one physical rice sample.** Every photo of that sample goes in
that one folder, even if you changed the angle or the lighting. Never copy a photo
into a second batch.

A grade with **no images at all** is reported as *reserved* and skipped, so you can
add grades over time. A grade with images spread over **fewer than five** batches is
an error, because there would be no way to give all five folds an unseen batch of it.

## How batch grouping prevents data leakage

Two photos of the same rice sample look almost identical. If one lands in training
and the other in evaluation, the model can score well by recognising that exact
sample instead of learning what the grade looks like. The reported accuracy would be
inflated and would not survive contact with new rice.

Each image is tagged with a group id combining grade and batch:

```
Premium_batch_01     Regular-Milled_batch_03
```

`StratifiedGroupKFold` never splits a group, so a whole batch always stays on one
side of every split. `train_5fold.check_folds()` then proves it before any model is
built: it fails immediately if two splits of a fold share a batch, or if a split is
missing a grade.

## How five-fold cross-validation works

The 15 batches are divided into 5 folds. For each fold:

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
**five square crops covering 65% of the shorter edge**, predicts on each, and averages.

So training mirrors that geometry:

- **Training:** random square crop between 50% and 80% of the shorter edge, at a
  random position. The randomness is itself an augmentation.
- **Validation and evaluation:** fixed centre crop at exactly 65% — the same crop
  FastAPI takes.

If training used the whole squashed photo while the API used zoomed crops, the model
would be measured on pictures it never sees in production. Both paths now go through
`image_preprocessing.load_image()` and `load_prediction_crops()`, which use the same
`PREDICTION_CROP_SCALE`.

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
        ├── evaluate_model.save_dashboard_metrics()  → model/metrics.json
        └── train_model.train_deployment_model()   all images, median best epoch
              └── save_calibration_cache()         → model/support_embeddings.npz
```

## Command

Run from the `backend` folder:

```powershell
.\.venv\Scripts\python.exe train_5fold.py --dataset dataset --epochs 30 --batch-size 32
```

Options: `--dataset`, `--epochs`, `--batch-size`, `--seed`, `--output-model`,
`--results-dir`.

Use the Python inside `.venv`. The system `pip` points at a different Python version.

## Output locations

| Path | Contents |
|---|---|
| `model/rice_cnn_model.keras` | The model FastAPI serves |
| `model/class_names.json` | Label order — index 0 is the first name |
| `model/metrics.json` | Cross-validated scores, served at `/metrics` |
| `model/support_embeddings.npz` | Calibration cache |
| `model/cross_validation/fold_N.keras` | Per-fold checkpoints |
| `results/5fold/cross_validation.json` | Full per-fold results |
| `results/5fold/summary.txt` | Mean ± standard deviation |
| `results/5fold/confusion_fold_N.png` | Per-fold confusion matrix |
| `results/5fold/confusion_overall.png` | All five folds combined |

Files are written through a `.pending` file and then renamed, so an interrupted run
cannot leave the API reading half a file.

## How FastAPI loads the final model

At startup `main.py`:

1. Reads `model/class_names.json` for the label order.
2. Loads `model/rice_cnn_model.keras`.
3. **Checks that the model's output count matches the number of labels.** If they
   disagree it refuses to serve the model, because it would otherwise return
   confident predictions under the wrong grade names.
4. Loads `model/support_embeddings.npz` for calibration, falling back to raw model
   output if it is missing.

On `POST /predict` it saves the upload, builds the five crops, averages the
predictions, applies calibration, stores the result in SQLite, and returns the grade
and confidence. `GET /metrics` serves `model/metrics.json` to the dashboards.

The final model is trained on **all** images for the median best epoch from the five
folds. No separate accuracy is claimed for it — the five-fold numbers are the honest
measurement.
