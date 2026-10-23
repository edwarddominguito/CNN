# Rice Classifier — Update Report for 21 October 2026

> Historical snapshot. The Git state, test counts, endpoint behavior, dataset and
> model metrics below describe 21 October. For the current implementation use
> [development notes](DEVELOPMENT.md) and [model evaluation](model-evaluation/2026-10-23.json).

**Date:** 21 October 2026, Asia/Manila (UTC+08:00)
**Scope:** Current Flutter, MySQL, Railway deployment, and verification status. Source files and Git state were inspected for this report; existing test results are identified separately from fresh cloud checks.

## Current status

The Railway backend is reachable over HTTPS and reports that its CNN model and MySQL database are available. Flutter now defaults to that Railway endpoint. The Flutter change has passed analysis and tests locally, but has not been committed or pushed. The physical-phone classification test was deferred at the user's request.

Service connectivity is verified. A real classification from the Huawei phone and its saved cloud history record remain unverified.

## Completed updates

### Flutter API configuration

- Centralized configuration: `mobile_app/lib/services/api_config.dart`.
- Default server for debug and release builds: `https://cnn-production-c269.up.railway.app`.
- Removed automatic localhost and Android-emulator fallbacks.
- Retained the explicit `API_BASE_URL` build-time override and URL validation; release overrides must use HTTPS.
- Updated the existing configuration test in `mobile_app/test/api_service_test.dart` to cover the Railway default and invalid overrides.
- This latest change did not modify backend routes, MySQL credentials, the CNN, preprocessing, or class labels.

### MySQL and prediction history

- The backend uses MySQL Connector/Python, pinned to `mysql-connector-python==26.7.0`.
- Current configuration supports the five `MYSQL_*` connection variables, Railway service aliases, and `MYSQL_URL`.
- Local defaults remain `localhost`, port `3306`, user `root`, and database `rice_classifier`; the password comes from configuration.
- Earlier local connection and temporary-table history tests passed. Those tests confirmed the existing schema and saved history were preserved at that point.
- The history JSON keys remain `id`, `predictedGrade`, `confidence`, `imagePath`, `note`, `error`, and `createdAt`.

### Railway dependency build fix

- Removed only `-c constraints.txt` from runtime requirements.
- Added `backend/.python-version` containing `3.12`.
- Kept `backend/constraints.txt` tracked and unchanged.
- Committed and pushed as `82d21b1` — `Fix Railway Python dependency build`.
- The latest fix did not change MySQL variables, the Railway root directory, or the Uvicorn start command.

The current Dockerfile also uses Python 3.12, bundles the model artifacts and React client, runs as a non-root user, and checks `/ready`. Its build context excludes datasets, Flutter, generated Python files, and environment files. CI is configured for backend tests, web checks, a Docker build, and a container inference smoke test. This report did not verify a GitHub Actions run or inspect Railway build logs.

`constraints.txt` remains available for explicit use, but the current runtime and CI installation commands do not automatically apply it through `-c`.

## Verification

### Completed Flutter checks

- `flutter analyze`: passed with no issues.
- `flutter test`: all 52 tests passed.
- These results are from the completed Flutter URL update in this chat; tests were not rerun merely to produce this report.

### Fresh cloud checks

Observed on **21 October 2026 at 15:00:22 Asia/Manila**:

- [Health](https://cnn-production-c269.up.railway.app/health): HTTP 200; `status: ok`, model available, database available.
- [Readiness](https://cnn-production-c269.up.railway.app/ready): HTTP 200; `status: ready`, model available, database available.
- [Latest history](https://cnn-production-c269.up.railway.app/history?limit=1): HTTP 200; returned an empty list.

These were read-only requests. No classification or database write was performed for this report. Readiness confirms connectivity, while the empty history does not establish that a phone prediction has been saved.

### Other existing evidence

- The saved local API-test log, `backend/.tmp-api-results.log`, ends with `Ran 17 tests` and `OK`. It establishes that logged run, not a fresh pass of the entire current backend suite.
- The current backend inventory contains four test files and 42 test methods; their complete execution was not verified in this report.
- Saved model metrics report **36.2% accuracy** on **447 images** using group-aware stratified 5-fold cross-validation, generated on **3 October 2026**. This is a historical evaluation, not a new model run. A working cloud connection does not establish grading accuracy.

## Pending work

1. Commit and push the Flutter configuration and related test change when requested.
2. Connect Huawei device `6FFUT20C22000681` and run `flutter run -d 6FFUT20C22000681`. The earlier attempt found no matching device; the user chose to connect it later.
3. Make one real rice classification from the phone using Internet access and the Railway HTTPS endpoint. No ADB reverse tunnel or laptop FastAPI server is required.
4. Confirm that the resulting grade, confidence, and timestamp appear in cloud history. A successful prediction response alone is insufficient if `history_saved` is false.
5. Review the saved model evaluation and complete the phone-to-cloud verification before preparing the APK for wider distribution.

## Files and deployment state

- Current branch: `main`.
- Local `HEAD` and the local `origin/main` tracking reference both point to `82d21b1`; its push succeeded earlier in this chat.
- Uncommitted application changes: `mobile_app/lib/services/api_config.dart` and `mobile_app/test/api_service_test.dart`.
- New report: `docs/CURRENT_UPDATE_REPORT_2026-10-21.md`.
- No commit, push, phone installation, or release APK build was performed while preparing this report.
