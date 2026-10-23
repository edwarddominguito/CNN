# Rice Grade Classifier

A three-grade rice image classifier with a Flutter application, React web client,
FastAPI inference API, and MySQL prediction history. Supported grades are
Premium, Well-Milled, and Poor-Quality-Rice-Mix.

The production Docker image serves the React client and TensorFlow model from
one API service. MySQL runs separately. Training runs locally and is never part
of application startup.

## Development

Use Python 3.12, Node.js 24, and Flutter 3.41.6. From the repository root on Windows:

```powershell
py -3.12 -m venv backend/.venv
backend/.venv/Scripts/python.exe -m pip install -c backend/constraints.txt -r backend/requirements-dev.txt
```

Configure MySQL through environment variables, then start the API with
`backend/scripts/run_backend.bat`. See [development notes](docs/DEVELOPMENT.md)
for configuration, client startup, and test commands.

GitHub Actions checks backend regressions, React lint/tests/build, Flutter
analysis/tests/web build, and a production Docker image against MySQL with real
model inference. Device camera and gallery behavior still require device tests.

## Deployment

Follow [Railway deployment instructions](docs/RAILWAY.md). The three tracked
files in `backend/artifacts/model/` are required runtime assets. Local training
photographs, databases, uploads, environment files, and build outputs are excluded
from Git and the deployment image. Back up training photographs separately.

## Evaluation

The saved 23 October 2026 grouped five-fold evaluation reports 80.53% mean
accuracy across 375 images. Fold accuracies range from 41.33% to 100%; physical
sample independence and grade provenance remain unverified. The model has no
rice-versus-non-rice detector. See the [evaluation record and model bundle
hashes](docs/model-evaluation/2026-10-23.json) for the recorded evidence.
