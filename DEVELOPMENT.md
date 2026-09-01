# Development Notes

Everything here used to be printed on the app's About screen. It describes how the
project is built and run, which is developer information — not something a person
grading rice needs to see — so it lives here instead.

## Layout

```
backend/      FastAPI server, CNN training, dataset and trained model
mobile_app/   Flutter app (Android, and desktop/web for testing)
```

## Backend

Trained model file:

```
backend/model/rice_cnn_model.keras
```

Companion files written next to it by training:

```
backend/model/class_names.json    the grade order the model learned
backend/model/metrics.json        5-fold cross-validation scores served at /metrics
```

Dataset:

```
backend/dataset/<Grade>/<batch folder>/<photos>
```

One batch folder is one physical rice sample. Five batches per grade are needed so
every cross-validation fold can be given a whole batch the model has never seen.

## Commands

Train (writes the model, class names and metrics):

```
backend\.venv\Scripts\python.exe backend\train_5fold.py --dataset dataset
```

Run the API server on port 8000:

```
backend\run_backend.bat
```

Run the Flutter app:

```
cd mobile_app
flutter run
```

Check the app before committing:

```
cd mobile_app
flutter analyze
flutter test
```

## API addresses

The app tries these in order until one answers. They are set in one place —
`mobile_app/lib/services/api_config.dart` — and are never shown in the UI.

| Platform | Address |
| --- | --- |
| Android emulator | `http://10.0.2.2:8000` |
| Desktop, web, iOS simulator | `http://127.0.0.1:8000`, then `http://localhost:8000` |

To run on a real phone over Wi-Fi, put the computer's IPv4 address first in
`ApiConfig._localhost`, for example `http://192.168.1.10:8000`.

## Endpoints used by the app

| Method | Path | Used by |
| --- | --- | --- |
| POST | `/predict` | Scan screen — returns `predicted_grade` and `confidence` (0–100) |
| GET/POST/DELETE | `/history` | History screen |
| GET | `/` and `/health` | Reachability checks (not called by the Flutter app) |
| GET | `/metrics` | Model availability and 5-fold scores, read by `run_backend.ps1` |

The About screen is static text: it does not call the backend.

## Known limitations

- With no trained model present, `/predict` returns a hard-coded demo result
  (`Demo Result: Well-Milled`, 91.25%), and saves it to the history like a real
  answer. The app shows the backend's note explaining this, but the number
  itself is invented by the backend.
- The deployed model has **three** outputs, not four. `model/class_names.json`
  lists `Premium`, `Well-Milled` and `Regular-Milled`; `Poor-Quality-Rice-Mix`
  has no images in `dataset/`, so it is reserved and cannot be predicted. The
  About screen still lists it as a supported grade.
- There is no rice / non-rice detector. Every photo is assigned one of the
  trained grades, however far it is from being rice.
- Nothing deletes `backend/uploads/`. Every prediction leaves a copy of the
  image there, and no part of the app reads that folder.
