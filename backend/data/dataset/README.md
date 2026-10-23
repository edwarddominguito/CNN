# Grouped Rice Dataset

## Verified local inventory, 2026-10-23

The local dataset has **375 JPEG photos in 15 populated batch folders**:

- Premium: 125 photos; five batches of 25 photos each.
- Well-Milled: 125 photos; five batches of 25 photos each.
- Poor-Quality-Rice-Mix: 125 photos; five batches of 25 photos each.

All 375 images fully decoded as RGB JPEGs during the audit. The newest 25 HEIC
uploads in `Poor-Quality-Rice-Mix/batch_05` were converted in place. No identical
file hashes or exact RGB pixel duplicates were found. The largest image contains
12,192,768 pixels.
The saved 2026-10-23 training run evaluated all 375 images in grouped five-fold
cross-validation, using 225 training, 75 validation and 75 evaluation images per
fold. The manifest describes the earlier file audit; its null `grouped_folds`
field means that audit did not itself generate folds.

These checks prove file integrity and folder separation. They cannot establish
that batches came from different physical samples or that a grade was correctly
verified. Source, date and grade-verification fields in `collection_record.csv`
still need the collector's evidence; no missing metadata has been invented.
`dataset_manifest.json` records filenames, byte sizes and SHA-256 hashes without
including the photographs themselves.

The current saved model's grouped five-fold results report **80.53% mean accuracy
and 78.02% macro F1** on these 375 images. Fold accuracies range from 41.33% to
100%, so performance varies substantially across held-out batches. The
[preserved evaluation record](../../../docs/model-evaluation/2026-10-23.json)
includes the detailed folds and matching deployment bundle hashes. File
conversion alone did not train a model; these results come from the subsequent
training run. Deployment success does not establish reliable grading.

## Classification scope

This dataset trains a classifier for rice **grades**, not rice varieties. The three
grades are fixed in `ml/image_preprocessing.py` (`CLASS_NAMES`):

```text
Premium   Well-Milled   Poor-Quality-Rice-Mix
```

Regular-Milled Rice was removed from the classification scope because sufficient
independent samples could not be consistently obtained from the selected
markets/suppliers during final dataset collection.

A product or variety name may be recorded in `collection_record.csv` as metadata.
It must never become a model output class.

## One sample, one batch

**One physical rice source = one batch folder.**

```text
backend/data/dataset/
  Premium/
    batch_01/   <- physical Premium sample 1
    batch_02/   <- physical Premium sample 2
    batch_03/
    batch_04/
    batch_05/
  Well-Milled/
    batch_01/ ... batch_05/
  Poor-Quality-Rice-Mix/
    batch_01/ ... batch_05/
```

Every photo of one sample stays in that sample's folder, however much the angle or
lighting changed between shots. Never split one sample across several batch folders
and never copy an image into a second batch: a batch is never divided across folds,
so splitting one sample is what puts the same rice on both sides of an evaluation
split and turns the reported accuracy into memorisation.

A grade with one batch folder is a correct, honest state. Do not pad it out.

### Filling a batch

All current batches are populated. Add a new batch only for a newly collected
independent sample. Do not move photos out of an existing batch to fill it, and
do not copy images between batches.

An empty batch folder is inert: the scanner reports it, never counts it as a group,
and never lets it reach the fold builder.

## How many images

| | |
|---|---|
| **Collection target** | 25–30 valid unique images per independent batch |
| **Training requirement** | at least 5 genuinely independent non-empty batches per grade |

These are two different things. 25–30 images per batch is the project collection
target, not a hard CNN requirement. It is advice for the person holding the camera:
the scanner reports every batch against it and then uses the batch anyway. Nothing
crashes over an image count, and a batch of 25–29 images does not need topping up.

| Valid unique images in a batch | Status |
|---|---|
| 0 | EMPTY |
| 1–24 | UNDER TARGET |
| 25–30 | READY |
| more than 30 | OVER TARGET |

Longer term, roughly 8–10 independent batches per grade at 25–30 images each gives
about 200–300 images per grade. That is a collection goal, not a number hard-coded
anywhere in the model.

## Taking the photos

- One physical sample per batch, start to finish.
- Rearrange the grains between shots; do not fire off near-identical frames.
- Consistent lighting, plain background, roughly constant camera distance.
- Grains clearly visible and in focus; avoid heavy overlap and blur.
- Mostly top-down.
- Never generate synthetic images to reach a count.
- Only single-frame `.jpg`, `.jpeg` and `.png` images up to 25 million pixels are
  read. EXIF phone orientation is applied consistently in training and prediction.
  Convert phone HEIC photos to JPG first
  (`scripts/convert_heic_dataset.py` can do it) and keep only the JPG in the batch
  folder: a HEIC left beside its JPG is the same photo twice.

Unreadable images are fully decoded during scanning so a truncated JPEG cannot
crash a later TensorFlow step. Exact RGB pixel duplicates, unknown grade folders
and misplaced photos must be reviewed before training starts. Dataset checks
never silently relabel or delete a photograph.

## Reporting

`ml/train_5fold.py` prints the dataset before it trains anything:

```text
Premium
  batch_01: 29 images  READY
  batch_02: 18 images  UNDER TARGET
  batch_03: 0 images  EMPTY
  batch_04: 32 images  OVER TARGET
  usable batches: 3   empty future batches: 1
  images: 79
```

It also lists the totals, the number of usable groups, the 25–30 collection target,
and every file it could not use, each by full path: corrupt images, unsupported file
types (such as HEIC), and images sitting outside any batch folder.

A grade with no images is reported as not yet collected, and training refuses to run
until it has some. It stays a research class and is shown in the apps as a reserved
grade; it is never dropped from the objective and its images are never fabricated.

## Grouped five-fold cross-validation

A batch is a **group**, not a fold. The five folds are generated in code by
`StratifiedGroupKFold` — there are no `fold_1/ ... fold_5/` folders and one sample is
never spread across folds.

Every grade needs at least five **non-empty** independent batches, so each fold can
be handed a whole sample the model has not seen. Having *more* than five batches is
good: it makes the groups richer, and the run still uses five folds. Ten batches
means ten groups across five folds, never ten-fold cross-validation.

With fewer than five, `ml/train_5fold.py` stops before building any model and says what
is missing:

```text
Premium has 3 non-empty independent batches.
5 are required for grouped 5-fold cross-validation.
Collect images for batch_04, batch_05 before training.
```

The fix is to collect more independent samples. Never invent batches, duplicate
images, split one sample across folders, or switch to plain image-level KFold.

## Collection record

`collection_record.csv` documents where each batch came from. Add a row whenever you
create a batch folder.

## Running

From `backend`, using Python 3.12 and the training requirements:

```powershell
.\.venv\Scripts\python.exe -m pip install -r requirements-training.txt
.\.venv\Scripts\python.exe -m ml.train_5fold --check-only
.\.venv\Scripts\python.exe -m ml.train_5fold --epochs 30 --batch-size 32
```

The system `pip` points to Python 3.14 on this computer, so use the Python inside
`.venv` for all backend package and training commands.

## Railway deployment

The photos total approximately **0.70 GiB** and are intentionally excluded from
Git and the deployment image. Railway inference uses the saved model and needs
no dataset or retraining at startup. The required runtime files under
`backend/artifacts/model/` are included by the repository ignore rules:

- `rice_cnn_model.keras`
- `class_names.json`
- `metrics.json`

Fold checkpoints, support embeddings and training reports remain local research
outputs. Keep a separate backup of the source photos and preserve their batch
structure when transferring them to a training machine. A Git clone contains the
dataset documentation and manifest, not the original photographs.
