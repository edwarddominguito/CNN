# Rice Classifier: Introduction and Operational Framework

*Prepared from the current project source and saved model records on 23 October 2026.*

## 1. Introduction

The Rice Grade Classification System is an image-based application that uses a convolutional neural network (CNN) to classify photographs of rice into three project categories: **Premium**, **Well-Milled**, and **Poor-Quality-Rice-Mix**. The project brings together machine learning, a mobile application, a web interface, and a database to demonstrate a complete process for submitting an image, generating a classification, and recording the result. Its classification scope concerns rice grades rather than rice varieties or product names.

The system provides two ways to submit photographs. The mobile application allows users to capture an image with a device camera or select an existing photograph from the gallery. The web application allows users to select or drag and drop an image in a browser. Both interfaces send the image to a shared backend, where it is validated, preprocessed, and passed to the trained CNN. The backend returns the predicted grade and its confidence score. The mobile application also provides prediction history and an educational guide explaining the grade categories, image capture practices, and model outputs.

The project aims to make image-based rice classification accessible through familiar mobile and browser interfaces while maintaining a consistent prediction process. The CNN performs inference on the server, so classification requires a connection to the backend. Cached mobile history can be viewed without a connection. The predicted grade is an experimental model output; its usefulness depends on the training data, image conditions, and evaluation evidence described in the following sections.

## 2. Operational Framework

The system follows a client-server arrangement. Flutter and React provide the user interfaces; FastAPI receives requests and coordinates inference; TensorFlow executes the saved model; and MySQL stores prediction records. Model training is performed separately from the running application.

The classification workflow proceeds as follows:

1. The user captures or selects a rice photograph.
2. The client checks the file and submits it to the backend as a multipart upload.
3. The backend validates the image, corrects its orientation, converts it to RGB, crops its center, and resizes it for the model.
4. The CNN produces scores for the three supported grades. The backend selects the highest-scoring grade and expresses its softmax score as a confidence percentage.
5. The backend attempts to save the prediction in MySQL and returns the result, including whether history storage succeeded.
6. The client displays the grade and confidence. The mobile application maintains a local history copy and can retrieve records associated with its installation identifier.

### 2.1 Technology Stack

#### 2.1.1 Flutter and Dart Mobile Application

The mobile application is developed using Flutter and Dart. It contains Home, Scan, History, Guide, and About screens. Its Scan screen supports camera and gallery input, image previews, validation feedback, and classification results. The `image_picker` package provides image selection, while the `http` package handles communication with the backend.

The application uses `shared_preferences` to retain an anonymous installation identifier and a local copy of prediction history. This identifier associates requests with the installation's server history. The local cache supports viewing previous results when the backend is unavailable, although it does not provide offline classification.

#### 2.1.2 React and Vite Web Application

The web interface is built with React, JavaScript, and CSS, using Vite for development and production builds. It supports file selection, drag and drop, image previews, classification requests, and display of grades, confidence scores, loading states, and errors. It communicates with the backend through the browser's `fetch` API.

In the container deployment, the built React files are served by FastAPI from the same origin as the API. For separate web hosting, a public `VITE_API_URL` build setting specifies the backend address. The current React interface focuses on classification and does not include the mobile application's history screen.

#### 2.1.3 Python, FastAPI, and Uvicorn Backend

The backend is implemented in Python, with Python 3.12 specified for the Docker runtime and continuous integration environment. FastAPI defines the application endpoints, validates request data, and coordinates prediction and database operations. Uvicorn runs the application as an ASGI server.

The backend loads a saved model and its class labels at startup and checks that they are compatible before serving predictions. It also applies upload limits, request rate limits, and bounded inference concurrency. These controls help keep the service responsive when inputs are invalid or requests exceed its available resources.

#### 2.1.4 MySQL Database

MySQL stores prediction history, including the predicted grade, confidence, timestamp, and related record fields. The backend accesses it through MySQL Connector/Python and obtains connection settings from environment variables. The intended cloud arrangement uses a separate persistent MySQL service.

History requests are associated with an anonymous `X-Client-Id` supplied by the mobile application; the backend stores a hash of this identifier. This provides installation-based history separation. It does not implement a user account system. Uploaded photographs are temporary inference inputs and are removed after processing; the current backend does not provide a permanent image archive.

#### 2.1.5 Docker and Railway Hosting

Docker packages the backend, saved model bundle, and built React application into one deployable image. The multi-stage Dockerfile uses Node.js 24 to build the web client and a Python 3.12 runtime to serve the application. The runtime uses a non-root account and checks the application's readiness endpoint.

Railway is the hosting platform identified in the deployment instructions and the mobile application's default API configuration. The documented arrangement hosts the application container alongside a separate MySQL service and exposes the application over HTTPS. The deployment evidence and its current verification limits are described in Section 2.4.

### 2.2 Other Technologies and Tools

#### 2.2.1 TensorFlow and Keras CNN Model

The classification model is implemented with TensorFlow and Keras using transfer learning with MobileNetV2. The training code initializes the backbone with ImageNet-pretrained weights and keeps it frozen while training the rice classification layers. The inspected saved model contains the MobileNetV2 backbone, global average pooling, dropout, a 128-unit ReLU dense layer, and a three-unit softmax output layer.

The model receives a 224 × 224 RGB image. Rescaling to the input range expected by MobileNetV2 is embedded in the model, helping keep training and serving consistent. Adam and sparse categorical cross-entropy are used for optimization. The returned confidence is the selected class's softmax score; it is not a measured probability that a particular prediction is correct.

#### 2.2.2 Image Processing and Dataset Preparation

Pillow handles image decoding, EXIF orientation correction, RGB conversion, cropping, and resizing. Official inference and evaluation use a centered square crop whose side is 65% of the shorter image edge, resized to 224 × 224 pixels. Training uses random crops around this scale, together with rotation, zoom, translation, and contrast augmentation.

The current dataset records contain 375 photographs: 125 for each grade, arranged in five batches per grade with 25 photographs per batch. A dataset manifest records file details, hashes, and audit results. A collection record provides fields for the source, collection details, and grade verification. A separate conversion script uses `pillow-heif` to convert HEIC photographs into JPEGs for dataset preparation.

#### 2.2.3 Internal API and Supporting Libraries

The clients use the project's own HTTP API. `POST /predict` accepts a photograph and returns its classification. `GET`, `POST`, and `DELETE /history` support history management. `GET /metrics` exposes the saved evaluation results, while `/health` and `/ready` report operational state. Supported inference uploads are single-frame JPEG, PNG, and WebP images, with a 15 MB file limit and a 25-million-pixel decoded-image limit.

NumPy supports numerical image and prediction processing. Scikit-learn provides grouped cross-validation and evaluation metrics, while Matplotlib generates training and evaluation plots. Git and GitHub support source control, and GitHub Actions defines automated backend, web, and container checks. The inspected classification workflow uses a locally stored model rather than an external prediction API. It contains no implemented web-scraping pipeline.

### 2.3 Development Process

#### 2.3.1 Dataset Preparation and Model Development

Dataset preparation organizes photographs by grade and batch. The intended collection rule assigns all photographs of one physical rice sample to one batch. Before training, the scanner checks image readability, duplicate pixel content, folder organization, and the availability of enough batches for each grade. The current manifest records 375 fully decoded images and no exact file or RGB-pixel duplicates.

Model evaluation uses group-aware stratified five-fold cross-validation. Batch folders remain together during splitting to reduce leakage between photographs of the same sample. Within each outer development split, a further grouped split provides validation data for early stopping and checkpoint selection. The saved run records 225 training images, 75 validation images, and 75 evaluation images in each fold. A fresh model is initialized for every fold.

After evaluation, the pipeline trains a final model on all available images for the median best epoch count from the folds. It saves the model, ordered class labels, and evaluation metrics as the deployment bundle. The five-fold scores describe the evaluated training procedure; they are not an independent test of the final model trained on all images.

#### 2.3.2 Application Integration and Verification

Application integration connects both clients to the same prediction endpoint and label definitions. Client checks provide early feedback on unsupported or unusable files, and the backend performs its own validation before inference. The prediction response distinguishes successful classification from successful history storage through the `history_saved` field.

The repository includes backend tests for API behavior, database access, model handling, request limits, and startup behavior. It also includes Flutter tests and React API tests. GitHub Actions is configured to run backend regression tests, web linting, web tests, a production web build, a Docker build, and deployment smoke checks against a MySQL service. The smoke-check script exercises readiness, the web application, history, and model inference. These files establish the verification workflow; no fresh application test run was performed while preparing this document.

#### 2.3.3 Current Scope and Limitations

The current saved evaluation, generated on 23 October 2026, reports **80.53% mean accuracy**, **83.48% macro precision**, **80.53% macro recall**, and **78.02% macro F1** across 375 evaluation images. Accuracy has a sample standard deviation of **22.80 percentage points**, and individual fold accuracies range from 41.33% to 100%. The variation indicates that performance depends substantially on the held-out batches. These figures come from the [current model metrics](../backend/artifacts/model/metrics.json) and [preserved fold results](model-evaluation/2026-10-23.json), rather than a new evaluation performed for this document.

The collection records still lack source and grade-verification evidence. The manifest explicitly marks physical batch independence and grade provenance as unverified. Folder separation and duplicate checks therefore cannot establish that every batch represents an independent physical sample or that every label has been independently confirmed.

The backend also has no rice-versus-non-rice detector or confidence rejection threshold. An unrelated photograph can receive a rice grade. The system should consequently be described as an experimental three-category classifier, with further data verification and evaluation needed to establish performance on new samples and capture conditions.

### 2.4 Deployment

#### 2.4.1 Backend and Web Deployment

The repository's deployment procedure builds the Docker image from the project root. The image includes the API code, required inference modules, React build, and three model-bundle files: `rice_cnn_model.keras`, `class_names.json`, and `metrics.json`. Raw training photographs and research outputs are excluded from the deployment image. Training is completed separately and does not run during application startup.

The application starts through `python -m scripts.start_server`, binds to `0.0.0.0`, and uses the platform's `PORT` value, defaulting to 8000. MySQL connection details are supplied through environment configuration. The backend serves both the API and bundled web client. Its `/ready` endpoint requires an available model and usable database, making it the appropriate deployment readiness check. A replacement model must be included in a new deployment or followed by an application restart before it is loaded.

#### 2.4.2 Mobile Deployment

The Flutter application currently defaults to `https://cnn-production-c269.up.railway.app` in both debug and release configurations. Developers can select another backend at build time through `--dart-define=API_BASE_URL=...`; release configurations require HTTPS. Because inference runs on the server, the application does not need to bundle the TensorFlow model or connect directly to MySQL.

Android builds can be produced from the Flutter project for device installation. The source and deployment notes do not establish app-store publication or a completed production mobile release. Device installation, camera capture, successful cloud prediction, and retrieval of the resulting history record remain distinct checks in an end-to-end deployment verification.

#### 2.4.3 Deployment Verification

The project report dated 21 October 2026 records successful HTTPS checks of the configured Railway service's health, readiness, and history endpoints. This is historical evidence that the service was reachable and reported model and database availability at that time. That report left physical-phone classification and confirmation of a saved cloud history record pending.

Fresh read-only checks of `/health`, `/ready`, and `/metrics` were attempted during preparation of this document on 23 October 2026, but the service could not be reached from this session. This does not establish that the deployment is offline. Current cloud availability, completion of the pending phone test, and deployment of the updated local model remain unverified here. The 80.53% accuracy figure above belongs to the current local model records and should not be attributed to the live Railway service without confirming its deployed artifacts.

## Source Notes

This draft follows the supplied Introduction and Operational Framework outline. Technical descriptions were checked against the current implementation and saved artifacts. Some earlier repository notes retain older dataset counts and evaluation results; the current manifest and model records were used for those figures.

- **Mobile interface and packages:** [Flutter package configuration](../mobile_app/pubspec.yaml), [application routes](../mobile_app/lib/main.dart), [scan screen](../mobile_app/lib/screens/scan_screen.dart), [API configuration](../mobile_app/lib/services/api_config.dart), and [API/history service](../mobile_app/lib/services/rice_api_service.dart).
- **Web interface:** [React package configuration](../my-react-app/package.json), [application component](../my-react-app/src/App.jsx), and [API client](../my-react-app/src/api.js).
- **Backend and database:** [runtime dependencies](../backend/requirements.txt), [FastAPI application](../backend/app/main.py), [request middleware](../backend/app/middleware.py), and [MySQL access](../backend/app/database.py).
- **Machine learning:** [model architecture and final training](../backend/ml/train_model.py), [image preprocessing](../backend/ml/image_preprocessing.py), [grouped training controller](../backend/ml/train_5fold.py), and [evaluation code](../backend/ml/evaluate_model.py).
- **Dataset and results:** [dataset manifest](../backend/data/dataset/dataset_manifest.json), [collection record](../backend/data/dataset/collection_record.csv), [saved model metrics](../backend/artifacts/model/metrics.json), and [preserved fold results and deployment bundle hashes](model-evaluation/2026-10-23.json).
- **Deployment and verification:** [Dockerfile](../Dockerfile), [production entry point](../backend/scripts/start_server.py), [GitHub Actions workflow](../.github/workflows/ci.yml), [Railway instructions](RAILWAY.md), and [21 October status report](CURRENT_UPDATE_REPORT_2026-10-21.md).
