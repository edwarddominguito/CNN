# Grouped Rice Dataset

`train_5fold.py` creates its own leakage-safe training, validation, and evaluation
splits. Organize original images by class and independent rice source:

```text
dataset/
  Premium/
    batch_01/
    batch_02/
    batch_03/
    batch_04/
    batch_05/
  Well-Milled/
    batch_01/
    ...
  Regular-Milled/
    batch_01/
    ...
  Poor-Quality-Rice-Mix/
    batch_01/
    ...
```

A batch is one physical rice source or one prepared sample. Keep every photo of
that sample in the same batch, even when the camera angle or lighting changes, and
never copy an image between batches. A batch is never split across folds, so this
is what stops the model being scored on a sample it already trained on.

Each grade is then either:

- **Trained** — it has at least five non-empty batch folders, so every fold can be
  given a batch the model has not seen.
- **Reserved** — it has no images at all. Training skips it and the apps show it as
  a reserved grade. Add five non-empty batches and it joins the model on the next
  run, with no code change.

A grade with images spread over fewer than five batches is an error, because there
is no way to give every fold an unseen batch. Either spread the images over more
batches or empty the folders to reserve the grade.

Install and run from `backend`:

```powershell
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe train_5fold.py --dataset dataset --epochs 30 --batch-size 32
```

The system `pip` points to Python 3.14 on this computer, so use the Python inside
`.venv` for all backend package and training commands.
