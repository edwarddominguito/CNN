# Grouped Rice Dataset

## Verified local inventory, 2026-11-17

The active dataset contains **700 readable JPEG photos in 28 batch folders**:
Premium and Well-Milled each contain 250 photos in ten batches; Poor-Quality-Rice-Mix
contains 200 photos in eight batches. Every batch contains 25 photos. The current
`dataset_manifest.json` lists the files, byte sizes, SHA-256 hashes and integrity
audit. Collection provenance and physical sample independence remain unverified.

The saved model metrics generated on 16 November report **75.76% mean accuracy
and 70.00% macro F1** across 700 images using grouped five-fold evaluation. This
publication does not retrain the model. The inventories below describe historical
snapshots; the current manifest describes the 700-image publication.

The active photographs are versioned with Git LFS. Install Git LFS before cloning,
or run `git lfs install` followed by `git lfs pull` in an existing checkout. CI and
Railway inference use the saved model and do not need to download the photographs.

## Verified local inventory, 2026-11-08

The active dataset contains **450 readable JPEG photos in 18 batch folders**:
150 photos per grade, with six batches of 25 each. The 75 new HEIC photos in the
three `batch_06` folders were converted to full-resolution RGB JPEGs at quality
95 with chroma subsampling disabled. Orientation and available ICC profiles were
preserved. The previous 375 JPEGs were left unchanged. Every image is single-frame
and below the 25-million-pixel limit.

The exact 75 HEIC originals are archived outside the active dataset at
`backend/dataset_backups/<run>/originals/<grade>/batch_06/`, with a conversion
manifest in the same run folder. Only the JPEG versions remain in the active
batches, so the original and converted image cannot both enter training.

The latest saved grouped five-fold evaluation reports **78.20% mean accuracy**
on 450 images, using the pre-conversion dataset of 375 JPEGs and 75 HEICs. JPEG
conversion itself does not retrain or re-evaluate that model. The historical
`dataset_manifest.json` and the 23 October evaluation below remain snapshots of
375 images. Folder names alone do not verify physical sample independence or
grade provenance.

## Verified local inventory, 2026-10-23

The 23 October snapshot had **375 JPEG photos in 15 populated batch folders**:

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

The saved 23 October model's grouped five-fold results report **80.53% mean accuracy
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
    batch_06/
  Well-Milled/
    batch_01/ ... batch_06/
  Poor-Quality-Rice-Mix/
    batch_01/ ... batch_06/
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
- Prefer JPEG for the active dataset. Convert new phone HEIC/HEIF photos using
  `scripts.convert_dataset_heic` as shown below; the command archives originals
  outside the dataset and leaves one active JPEG per photograph.
- Single-frame `.jpg`, `.jpeg`, `.png`, `.webp`, `.heic` and `.heif` dataset images
  up to 25 million pixels are read, including uppercase extensions. EXIF phone
  orientation is applied consistently in training and prediction. Native HEIC/HEIF
  decoding remains a fallback through the training requirements; a missing decoder
  is reported and blocks training with installation instructions. Do not manually
  leave a HEIC beside its converted JPG: lossy conversion means exact-pixel
  duplicate checks cannot reliably identify that pair as the same photograph.

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
types, missing optional decoders, and images sitting outside any batch folder.

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
.\.venv\Scripts\python.exe -m scripts.convert_dataset_heic
.\.venv\Scripts\python.exe -m scripts.convert_dataset_heic --apply
.\.venv\Scripts\python.exe -m ml.train_5fold --check-only
.\.venv\Scripts\python.exe -m ml.train_5fold --epochs 30 --batch-size 32
```

The conversion command without `--apply` prints a read-only plan. `--apply`
creates and validates the JPEGs, archives the exact HEIC/HEIF originals outside
the active dataset, and records the operation in a conversion manifest. It does
not trim batch counts, overwrite the previous JPEGs, or train the model.

The system `pip` points to Python 3.14 on this computer, so use the Python inside
`.venv` for all backend package and training commands.

## Railway deployment

The active photographs are stored in Git LFS; archived originals and local backups
remain excluded from Git. All dataset images stay outside the deployment image.
Railway inference uses the saved model and needs
no dataset or retraining at startup. The required runtime files under
`backend/artifacts/model/` are included by the repository ignore rules:

- `rice_cnn_model.keras`
- `class_names.json`
- `metrics.json`

Fold checkpoints, support embeddings and training reports remain local research
outputs. Keep a separate backup of the source photos and preserve their batch
structure when transferring them to a training machine. A clone with Git LFS
installed downloads the active photographs. A checkout without LFS contains only
pointer files; run `git lfs pull` before scanning or training that checkout.
