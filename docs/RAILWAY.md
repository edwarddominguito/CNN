# Deploying the rice classifier on Railway

The root `Dockerfile` builds the React client and serves it from the FastAPI
backend on one domain. It uses Python 3.12, Node 24 for the web build, a CPU
TensorFlow runtime, and one API worker. The deployment never trains a model or
downloads a dataset at startup.

## Files that must reach GitHub

Commit the application changes and these three files together:

```text
backend/artifacts/model/rice_cnn_model.keras
backend/artifacts/model/class_names.json
backend/artifacts/model/metrics.json
```

The primary model is about 11.6 MB in this checkout. `.gitignore` permits these
deployment files while keeping training photographs, fold checkpoints, obsolete
support embeddings, generated plots, local databases, and uploaded images out of
Git. `.dockerignore` also excludes those files from the production image. Keep a
separate backup of the original photographs and collection records: deployment
weights cannot recreate the training dataset.

After committing, this command must succeed from the repository root:

```powershell
git ls-files --error-unmatch backend/artifacts/model/rice_cnn_model.keras backend/artifacts/model/class_names.json backend/artifacts/model/metrics.json
```

If a required artifact is missing from the GitHub checkout, Docker intentionally
fails its `COPY` step. Restore the matching model bundle, or train locally using
`backend/requirements-training.txt` and `python -m ml.train_5fold` from `backend`.
Do not rename a different model or edit labels to bypass a compatibility failure.

## Railway setup

1. Create a Railway project with a **MySQL** service. Keep its database volume and
   configure backups in Railway; prediction history lives in MySQL.
2. Add an application service from this GitHub repository. Use the **repository
   root** as the source directory so Railway detects the root `Dockerfile`. Leave
   custom build and start commands empty; the image supplies both.
3. In the application's Variables, add a reference to the MySQL service's private
   connection URL. For a database service named `MySQL`, the reference is:

   ```text
   MYSQL_URL=${{MySQL.MYSQL_URL}}
   ```

   Use Railway's variable reference picker if your database has another service
   name. The API also accepts `MYSQLHOST`, `MYSQLPORT`, `MYSQLUSER`,
   `MYSQLPASSWORD`, `MYSQLDATABASE`, and their existing `MYSQL_HOST`, `MYSQL_PORT`,
   `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DATABASE` forms. Use one complete
   configuration consistently and keep passwords in Railway variables.
4. Set the deployment **Healthcheck Path** to `/ready`, with the default
   300-second timeout. `/ready` returns 503 until the compatible model and history
   database are usable; `/health` is only a liveness endpoint and can return 200
   while a component is unavailable.
5. Set the restart policy to **On Failure**, with a finite retry limit such as 10.
   Generate a public domain for the application after the deployment is ready.
   The entry point listens on Railway's injected `PORT` at `0.0.0.0`; no fixed
   port variable or separate React service is needed.

As checked on 2026-10-21, Railway's legacy `railway.toml` and `railway.json`
configuration is deprecated and unavailable for new services. This repository
uses Docker discovery and the dashboard settings above. Railway's replacement
`.railway/railway.ts` workflow requires a separate CLI plan/apply and is not
automatically applied by a GitHub deployment. See the official
[Dockerfile](https://docs.railway.com/builds/dockerfiles),
[MySQL](https://docs.railway.com/databases/mysql),
[healthcheck](https://docs.railway.com/deployments/healthchecks), and
[configuration](https://docs.railway.com/infrastructure-as-code) documentation.

## Clients and storage

The built React app calls the API on the same HTTPS domain. Leave `VITE_API_URL`
unset for this layout. If the web client is hosted separately, set `VITE_API_URL`
to the API's HTTPS URL **before building** the web client and set the backend's
`CORS_ORIGINS` to the exact allowed browser origins, separated by commas.

Build the Flutter release with the public application URL:

```powershell
flutter build apk --dart-define=API_BASE_URL=https://YOUR-APP.up.railway.app
```

Run that command from `mobile_app`. Production mobile clients need an HTTPS URL;
localhost and Android emulator addresses are only useful for development.

The API removes temporary prediction uploads after processing, so an application
volume is not required for the default layout. The old local
`backend/storage/rice_grader.db` is not a deployed database and is not migrated to
MySQL automatically. `MODEL_DIR` and `STORAGE_DIR` can override artifact and
temporary-storage locations when explicitly needed. Mounting over the model
directory hides the model bundled in the image; provision all matching artifacts
before starting if you choose that arrangement. Railway volumes appear at runtime
and are mounted as root; a writable volume used by this non-root image needs
appropriate permissions or Railway's documented `RAILWAY_RUN_UID=0` setting.
See [Railway volumes](https://docs.railway.com/volumes).

## Verify before using the deployment

The GitHub Actions workflow runs backend regression tests, web lint/tests/build,
and a production Docker build with a temporary MySQL database. It then checks
readiness, the served web page, history reads, and a real model prediction on a
synthetic PNG. This checks serving behavior, not grading accuracy.

On 2026-10-21, local package constraints and `pip check` passed, and all production
pins resolved as Python 3.12 Linux wheels. An isolated local MySQL 8.0 database
also passed real HTTP checks with the bundled model and built React client:
synthetic and original 3024x4032 JPEG predictions, saved history, UTC timestamp
normalization, history ordering, the composite index, web assets, and history
persistence across an API process restart. The temporary database and API were
shut down afterward; the existing local database service was not modified.

Docker was not installed in the local environment, so the actual Linux container
build and MySQL 8.4 CI workflow still need their first successful run. No Railway
deployment has been performed here.

Read-only verification of your deployed service uses only standard Python:

```powershell
python backend/scripts/smoke_deployment.py --url https://YOUR-APP.up.railway.app --wait 180
```

For staging, append `--exercise-prediction` to submit one synthetic image and save
one test history entry. Test real rice photographs separately, verify that a
prediction appears in history, redeploy, and confirm the history survives.

If Docker is installed, you can build the same image locally:

```powershell
docker build --tag rice-cnn:local .
docker run --rm -p 8000:8000 --env-file .env rice-cnn:local
```

The runtime `.env` must contain connection settings for a reachable MySQL server;
inside Docker, `localhost` points to the container itself. Environment files and
passwords must stay out of Git and the image.

## Operational limits

One worker and one active prediction limit memory growth under simultaneous
uploads. Excess work receives a retryable error rather than accumulating image
buffers. TensorFlow threads default to one, and Uvicorn limits concurrent
connections to 32. Choose the service memory limit from observed peak startup and
prediction usage, with headroom; a successful local check cannot guarantee a
particular Railway plan will have sufficient memory.

For one concrete reference, the local Windows API process reached a peak working
set of about **600 MiB** after startup and a 12.2-megapixel JPEG prediction. This
excludes the separate MySQL service. A 512 MiB memory limit is below that observed
peak; measure the Linux container under representative load before choosing its
production memory budget, because Windows and Linux usage can differ.

Railway's deployment healthcheck does not continuously monitor a running service.
Monitor its logs and memory, and use an external uptime check on `/ready` if
continuous readiness monitoring is required. Protect history data using an
appropriate access layer before offering the application to untrusted users;
the API currently exposes history operations to its clients without user login.

When `/ready` fails, inspect `/health`, `/metrics`, and deployment logs. A missing
or incompatible model requires replacing the matching artifacts and redeploying.
A database failure requires fixing its connection variables or availability.
Increasing the healthcheck timeout does not repair either configuration problem.
