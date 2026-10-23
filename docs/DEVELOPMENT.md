# Development notes

For Railway deployment, use [RAILWAY.md](RAILWAY.md). The root Dockerfile builds
the React app and Python API together; MySQL runs as a separate service.

## Layout

```text
backend/
  app/          FastAPI server, MySQL history access, shared paths
  ml/           dataset scanning, CNN, group-aware 5-fold evaluation
  data/dataset/ local training photographs, grouped by grade and source batch
  storage/      temporary uploads; old local SQLite file is not the current DB
  artifacts/    model bundle and local training results
  scripts/      development launchers, production entry point, deployment smoke
  tests/        API, database, startup, and ML regression tests
  docs/         TRAINING_CODE_GUIDE.md
mobile_app/     Flutter client
my-react-app/   React web client, served by the API in the production image
docs/           development and deployment instructions
```

`backend/app/paths.py` defines shared paths. `MODEL_DIR`, `DATASET_DIR`, and
`STORAGE_DIR` environment variables can override their default locations.
`STORAGE_DIR/uploads` holds only temporary inference input; uploads are deleted
when processing completes, including failed requests.

## Dataset and saved model

The 2026-10-23 local audit found 375 readable JPG photographs in 15 non-empty batch
folders: 125 per grade, with five batches of 25 images in each grade.
The scanner checks image integrity and duplicate content; the collection
record still needs source/vendor, collection, and grade-verification evidence to
establish that the batches represent independent physical samples.

The required deployment bundle is:

```text
backend/artifacts/model/rice_cnn_model.keras
backend/artifacts/model/class_names.json
backend/artifacts/model/metrics.json
```

A compatible three-class model exists in this checkout. Its saved group-aware
5-fold evaluation reports **80.53% accuracy**, **83.48% macro precision**,
**80.53% macro recall**, and **78.02% macro F1**, across 375 images (generated
2026-10-23). Accuracy varies from 41.33% to 100% across folds, with a 22.80
percentage-point sample standard deviation. [Detailed fold results and bundle
hashes](model-evaluation/2026-10-23.json) are preserved with the source.
Verify sample independence and grade labels and improve evaluation before relying
on the grades; serving checks do not establish grading reliability.

The grade is the CNN's argmax and confidence is that class's softmax score,
expressed as a percentage. Training evaluation and serving use the same
`ml.image_preprocessing.load_inference_image` crop and resize. There is no
rice/non-rice detector: an unrelated photograph can still receive a rice grade.

The deployment image contains the saved model, labels, and evaluation metrics.
Raw photographs, fold checkpoints, and generated plots remain local and must be
backed up separately. Do not delete the deployable model bundle unless you intend
to retrain or restore it.

## Python setup and commands

Use Python 3.12, matching Docker and CI. From the repository root on Windows:

```powershell
py -3.12 -m venv backend/.venv
backend/.venv/Scripts/python.exe -m pip install -r backend/requirements-dev.txt
```

`requirements.txt` installs the API runtime. `requirements-training.txt` adds the
training, evaluation, and HEIC conversion dependencies. `requirements-dev.txt`
also includes HTTPX for API regression tests. Docker and CI apply `constraints.txt`
explicitly to keep the validated dependencies reproducible; a local constrained
install can add `-c backend/constraints.txt` to the command above. Linux x86-64 uses TensorFlow CPU
2.21.0; other supported platforms use TensorFlow 2.21.0.

Configure a reachable MySQL server before running the API. Use `MYSQL_URL` or the
`MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DATABASE`
variables. Railway's corresponding `MYSQLHOST`, `MYSQLPORT`, `MYSQLUSER`,
`MYSQLPASSWORD`, and `MYSQLDATABASE` names are also accepted. Keep secrets outside
Git. The existing `backend/storage/rice_grader.db` is a legacy SQLite file, not the
MySQL history database, and is not migrated automatically.

Run the development API from the repository root:

```powershell
backend/scripts/run_backend.bat
```

Or run the production entry point from `backend`:

```powershell
.venv/Scripts/python.exe -m scripts.start_server
```

It listens at `0.0.0.0` using `PORT` (default 8000), with one worker and bounded
connection concurrency. If MySQL is unavailable at startup, the process remains
live and later requests can retry the database connection.

At most four database operations hold connections at a time. Excess work gets a
retryable 503, and only one request retries database initialization after an
outage. `/health` remains responsive without an available worker thread. Model
startup also runs one bounded inference check before reporting it available.

Run backend tests and dataset preflight from `backend`:

```powershell
.venv/Scripts/python.exe -m unittest discover -s tests -v
.venv/Scripts/python.exe -m ml.train_5fold --check-only
```

Train locally only when the dataset passes validation:

```powershell
.venv/Scripts/python.exe -m ml.train_5fold
```

This writes matching model, class labels, and evaluation artifacts. The server
loads a model at startup; restart or redeploy after replacing it. Never train in
an API startup command.

## Clients

From `my-react-app`, run `npm ci`, `npm run dev` for development, and `npm run lint`,
`npm test`, and `npm run build` for checks. Production defaults to the current
browser origin; a separately hosted web client can set `VITE_API_URL` at build
time. Development API proxy behavior is configured in `vite.config.js`.

From `mobile_app`, use Flutter 3.41.6 (matching CI), then run
`flutter pub get --enforce-lockfile`, `flutter analyze`, and `flutter test`. CI
also builds a Flutter web release. Use `flutter run` for device testing.
Debug and release builds default to `https://cnn-production-c269.up.railway.app`.
To use another server, supply the address at build/run time instead of editing
source. Local development can use the computer's LAN address, desktop localhost,
or Android emulator `http://10.0.2.2:8000`:

```powershell
flutter run --dart-define=API_BASE_URL=http://YOUR-LAN-IP:8000
flutter build apk --dart-define=API_BASE_URL=https://YOUR-APP.up.railway.app
```

Release builds require HTTPS. For a separately hosted browser client, configure
backend `CORS_ORIGINS` with its exact allowed origin. Same-domain deployment does
not require cross-origin browser requests.

## HTTP behavior

- `GET /health` reports liveness and component state. It returns 200 even if the
  model or database is unavailable.
- `GET /ready` requires a compatible loaded model and usable MySQL history store;
  it returns 503 until both are available. Use it as the Railway healthcheck.
- `GET /metrics` reports model availability and saved evaluation scores. Missing
  evaluation data is reported as unavailable; scores are never invented. Why a
  model failed to load is written to the server log, not to responses.
- `POST /predict` returns `predicted_grade`, confidence in 0..100, and
  `history_saved`, plus the inserted `history_id` when storage succeeds so clients
  can associate a photo with the exact record. A false `history_saved` means
  inference succeeded but history persistence failed. An optional `X-Client-Id` header saves the result to that
  client's history; without it the result belongs to no client.
- `GET /history?limit=50`, `POST /history`, and `DELETE /history` operate on MySQL
  and require `X-Client-Id` (32-128 letters, digits, `-` or `_`). Each touches
  only the rows saved with that ID, stored as its SHA-256. History reads are
  capped at 200 entries per response.
- `GET /` serves the built React application when `backend/static` exists;
  otherwise it returns the API welcome response.

An unavailable model or busy inference slot returns 503. Oversized requests return
413. Empty/corrupt images return 400, invalid history data or a missing client ID
returns 422, and an unexpected inference failure returns 500. Uploads that do not
start with a JPEG, PNG or WebP signature are refused before any decoder runs.
More than 30 predictions or 60 history requests per minute from one IP return
429; `PREDICT_RATE_LIMIT_PER_MINUTE` and `HISTORY_RATE_LIMIT_PER_MINUTE` change
those limits, and 0 turns one off. Temporary files are removed on all
completed prediction paths. The API rejects invalid/nonfinite model outputs and
large decoded images instead of returning a fabricated grade.

Unavailable temporary upload storage returns a retryable 503. Large request
spooling runs outside the event loop, so slow disk writes do not block liveness
checks. The Flutter client preserves local history when a remote clear fails,
and serializes history updates so simultaneous saves cannot overwrite records.

History is separated per app installation by an anonymous client ID, not by user
accounts: reinstalling the app starts an empty history, and anyone holding an ID
can read or clear its history. Add user accounts before storing sensitive data.
To run as a least-privilege MySQL user, see [RAILWAY.md](RAILWAY.md). This
system remains a demonstration classifier with the accuracy limits above.
