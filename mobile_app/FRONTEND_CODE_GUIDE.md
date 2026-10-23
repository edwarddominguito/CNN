# Frontend Code Guide

A short explanation of every file in `mobile_app/lib/`.
This app is plain Flutter: `StatefulWidget`, `setState()`, `Navigator`, and
`async`/`await`. There is no BLoC, Provider, Riverpod, or GetX.

---

## 1. Folder layout

```
lib/
├── main.dart          the app starts here
├── app_colors.dart    all shared colours
├── content/           the Guide's static text, quiz questions and grade display names
├── models/            the shapes of the data from the backend
├── screens/           one file per page
├── services/          the code that talks to FastAPI
└── widgets/           parts that screens are built from
```

---

## 2. main.dart

The smallest file that matters. It does three things:

1. `main()` calls `runApp(const RiceGraderApp())`.
2. `MaterialApp` sets the theme (colours, button shapes, navigation bar).
3. `routes` lists the five screens and their names:

```dart
'/'        -> HomeScreen
'/scan'    -> ScanScreen
'/history' -> HistoryScreen
'/guide'   -> GuideScreen
'/about'   -> AboutScreen
```

No business logic lives here. The text sizes, button heights and card shapes are
set once in `_buildTheme()`, so screens read their styles from
`Theme.of(context).textTheme` instead of writing their own.

---

## 3. Every screen

### home_screen.dart (StatelessWidget)
The first page: one line of explanation, a Start Scan button, then the shortcut
tiles. It has no state because nothing on it changes.

### scan_screen.dart (StatefulWidget) — the most important screen
Holds six pieces of state:

```dart
XFile? image;                 // the picked photo
Uint8List? imageBytes;        // its bytes, used for the preview and the checks
PredictionResult? prediction; // what the model answered
bool isLoading = false;       // true while validating or waiting for FastAPI
String loadingMessage = '';   // which of those two steps is running
String? errorMessage;         // why the last attempt stopped
```

Three functions do the work: `pickImage()`, `classifyRice()` and `resetScan()`
(explained below). Exactly one of three things is on screen at a time — working,
finished, or waiting for the user — decided by `_buildActions()`.

### history_screen.dart (StatefulWidget)
Loads past predictions in `initState()`, keeps them in a `List`, and shows one
row per prediction. Has Refresh and Clear buttons in the title bar. A successful
row shows the photo it was classified from as a small thumbnail, or a
placeholder when this device has no copy; tapping a row with a photo opens it
larger on its own page.

### guide_screen.dart (StatelessWidget)
The Guide tab: a short, grouped list of learning topics (rice grades, quality
characteristics, grade comparison, capture guide, how the CNN works, confidence,
mini quiz, glossary, references). The list comes from `guideSections` in
`content/guide_content.dart`.

### guide_topic_screen.dart (StatelessWidget)
One screen for every Guide page. It draws the topic's blocks (paragraphs, notes,
bullet lists, steps, cards, comparison, quiz) with `widgets/guide_blocks.dart`.
Adding a page means adding a `GuideTopic` to `content/guide_content.dart`, not a
new screen. `openGuideTopic()` opens a page and ignores a double tap.

All Guide text is static. Nothing in the Guide calls the backend, and nothing in
it claims the CNN detects defects: the model only classifies the whole photo.

### about_screen.dart (StatelessWidget)
A short description of the app, the three grades it supports, and the version.
Nothing on it changes at runtime, so it holds no state and makes no request.
Server addresses, model paths and evaluation results are deliberately kept out
of the app — they live in `docs/DEVELOPMENT.md` and the results files.

---

## 4. Services

### services/api_config.dart
The **only** place the backend address is selected. All builds default to
`https://cnn-production-c269.up.railway.app`. Override it with
`--dart-define=API_BASE_URL=https://your-backend.up.railway.app`; release builds
require HTTPS. Only the selected address is used, with no localhost fallback.

For local development, explicitly use `http://10.0.2.2:8000` on an Android
emulator, `http://127.0.0.1:8000` on desktop/web, or the computer's LAN address
on a physical phone. HTTP overrides are allowed only in debug builds.

### services/rice_api_service.dart
All backend communication, in one class:

| Method | What it does | Backend route |
| --- | --- | --- |
| `predictRiceGrade(fileName, bytes)` | uploads a photo, returns the grade | `POST /predict` |
| `getHistory()` | past predictions | `GET /history` |
| `addToHistory(result, photo)` | files a finished scan: keeps the photo of a successful one, records an answer the backend did not save | `GET /history`, `POST /history` |
| `clearHistory()` | returns true after confirmed deletion; otherwise keeps local history | `DELETE /history` |

Inside, one small private helper is reused by all of them:

```dart
Future<T?> _tryEachHost<T>(Future<T?> Function(String, http.Client) sendRequest, {Duration? timeout})
```

It loops over the addresses from `ApiConfig`, tries each one, and returns the
first answer. If no address works it returns `null`, and the calling method
turns that into a friendly message instead of a crash. Each request closes its
HTTP client in `finally`, including on timeout. The upload deadline is two
minutes; history requests use five seconds.

When the backend cannot be reached, history falls back to a small copy saved on
the phone with `shared_preferences`. The `history_saved` response flag also
preserves valid predictions when the backend's database is unavailable.
Those unsaved entries remain local when the server history is refreshed.

History photos never leave the device. After a successful prediction the
classified bytes are copied into the app's private folder (`history_photos/`
in `path_provider`'s application support directory); the web has no such
folder and shows placeholders. A row the backend saved is tied to its photo by
row id: right after `/predict`, the newest of this installation's rows with the
same grade and confidence that has no photo yet. Unsaved entries carry the
photo's file name themselves. Photos no saved record refers to (a cleared
History, rows past the 25 listed, a copy that could not be linked) are deleted.
History operations share a lock across service instances so concurrent screens
cannot lose saves or restore an old refresh after a confirmed clear. Cache
writes happen outside timed network callbacks. Unsaved prediction results are
queued even when the Scan screen was closed while waiting for the backend.

### services/image_validation.dart
One function, `validateImage(fileName, bytes)`. It returns `null` when the image
can be used, or a short message to show the user. It checks that the file is not
empty, that the extension is one the backend can read, and that the bytes really
decode into an image with a real width and height. Nothing else — it says nothing
about rice, quality or grade. The backend still validates the upload itself.

---

## 5. Models

### models/prediction_result.dart
What `POST /predict` sends back.

```dart
class PredictionResult {
  final String predictedGrade;   // for example "Premium"
  final double confidence;       // 0 to 100, already scaled by the backend
  final String? note;
  final String? error;           // not null means the prediction failed
}
```

The backend multiplies by 100 itself (`main.py`), so the app never scales the
confidence again. The confidence bar is the only place it is divided by 100.

`PredictionResult.fromJson(...)` turns the backend's JSON into this object.
The helper `toDoubleOrNull()` exists because the backend may send a number
(`97.5`) or a string (`"97.5"`), and both must work.

### models/prediction_history_entry.dart
One row of the History screen. It has `fromJson()` to read a saved row and
`toJson()` to write one. `id` is the backend's row id (null for an entry only
the phone holds) and `imagePath` is the file name of the row's photo in the
app's private folder.

---

## 6. Important reusable widgets

| File | What it is |
| --- | --- |
| `widgets/app_scaffold.dart` | `AppNavScaffold` — the frame every screen sits in (title bar + bottom navigation). Also `AppPage`, the scrolling body with standard padding, and `appRoutes`, the list of tabs. |
| `widgets/app_cards.dart` | The small shared pieces: `AppCard` (the rounded box every screen is built from), `AppTile` (icon or a leading widget such as a thumbnail + title + one line, tappable), `AppEmptyState`, and `AppCardGrid`. |
| `widgets/image_preview.dart` | `ImagePreview` — shows the picked photo, or "No sample loaded" when nothing is picked. |
| `widgets/scan_controls.dart` | `ScanControls` — the Take Photo, Gallery and Classify Rice buttons. Only built when the screen is idle, so it needs no busy state. |
| `widgets/prediction_result_card.dart` | `PredictionResultCard` — the grade, the model confidence and its bar, plus links to "About This Grade" and "Understanding Confidence" in the Guide. Only ever built for a real prediction; failures are shown by the Scan screen. |
| `widgets/guide_blocks.dart` | `GuideBlockView` — draws one block of a Guide page from the shared cards above, so every Guide page looks the same. |
| `widgets/guide_quiz.dart` | `GuideQuizView` — the multiple-choice quiz. Its score lives only in the widget's state; nothing is saved or sent. |

Grade names: the backend label (for example `Poor-Quality-Rice-Mix`) is stored
and sent unchanged. `gradeDisplayName()` in `content/rice_grades.dart` only
changes how it is drawn (`Poor-Quality Rice Mix`).

`app_colors.dart` holds every shared colour, so changing a shade in one place
changes it everywhere.

---

## 7. How navigation works

Navigation uses Flutter's built-in `Navigator` with **named routes**. There is
no routing package.

Two ways to move between screens:

```dart
// From a button: push a new screen on top.
Navigator.pushNamed(context, '/scan');

// From the bottom navigation bar (inside AppNavScaffold):
Navigator.pushNamedAndRemoveUntil(context, '/history', (route) => false);
```

The second one clears the old screens first. Without it, tapping tabs back and
forth would stack dozens of screens on top of each other.

Guide pages are pushed on top of the screen that opened them with
`openGuideTopic()`. They pass `isSubPage: true` to `AppNavScaffold`, so their
back arrow returns to the page underneath (for example a scan result) and
tapping the Guide tab returns to the Guide list.

---

## 8. How image selection and camera capture work

Both use the same function. Only the `source` is different:

```dart
onCamera:  () => pickImage(ImageSource.camera)    // opens the camera
onGallery: () => pickImage(ImageSource.gallery)   // opens the photo gallery
```

Because there is one function and one `image` variable, the camera and the
gallery cannot get out of sync.

---

## 9. How FastAPI communication works

`predictRiceGrade()` builds a **multipart** request, which is how a file is
uploaded over HTTP:

```dart
final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/predict'));
request.files.add(
  http.MultipartFile.fromBytes('file', bytes, filename: fileName),
);
```

The field name `'file'` must match the FastAPI parameter:

```python
async def predict(file: UploadFile = File(...)):
```

The response body is JSON, which `PredictionResult.fromJson()` converts into a
Dart object.

---

## 10. How prediction results are displayed

`_buildActions()` picks one of three things, in this order:

```dart
if (isLoading)        -> _LoadingCard, a spinner with no value
if (prediction != null) -> PredictionResultCard + "Scan Again"
otherwise             -> the error card (if any) + ScanControls
```

Because the three cases are separate, the result card never has to think about
loading and the controls never have to think about errors.

The spinner has no percentage on purpose: neither the validation nor the CNN
reports measurable progress, so a number there would be invented.

---

## Execution flow

```
User opens app
    ↓
main.dart              runApp -> MaterialApp -> route '/'
    ↓
HomeScreen             user taps "Start Scan"
    ↓
ScanScreen             user taps Take Photo or Gallery
    ↓
pickImage()            image_picker returns the photo
    ↓
ImagePreview           the photo is shown on screen
    ↓
user taps "Classify Rice"
    ↓
classifyRice()         isLoading = true, "Validating image..."
    ↓
validateImage()        empty? wrong format? does it decode?
    ↓                        ↓ invalid
    ↓ valid                  errorMessage -> error card, nothing uploaded
    ↓
"Analyzing rice image..."
    ↓
RiceApiService.predictRiceGrade()
    ↓
FastAPI  POST /predict
    ↓
JSON response
    ↓
PredictionResult.fromJson()
    ↓
setState()             isLoading = false, prediction is stored
    ↓
PredictionResultCard   grade + model confidence shown
    ↓
resetScan()            "Scan Again" clears everything
```

---

## Important functions

**FUNCTION:** `pickImage(ImageSource source)` — `screens/scan_screen.dart`
**PURPOSE:** Opens the camera or the gallery and stores the chosen photo.
**INPUT:** `ImageSource.camera` or `ImageSource.gallery`.
**OUTPUT:** Sets `image` and `imageBytes`, clears the old prediction.
**WHY IT EXISTS:** One function for both sources, so there is only one place
where the selected image is set.

---

**FUNCTION:** `classifyRice()` — `screens/scan_screen.dart`
**PURPOSE:** Validates the picked image, then sends it to the backend.
**INPUT:** The image already in `image` and `imageBytes`.
**OUTPUT:** Stores a `PredictionResult` in `prediction`, or a message in
`errorMessage`.
**WHY IT EXISTS:** Keeps the steps in one readable list. It returns early when a
request is already running, so the button cannot be pressed twice, and it never
uploads an image that failed validation.

---

**FUNCTION:** `resetScan()` — `screens/scan_screen.dart`
**PURPOSE:** Clears the photo, the prediction and any error.
**INPUT:** Nothing.
**OUTPUT:** The screen returns to its empty state.
**WHY IT EXISTS:** One reset in one place, so "Scan Again" cannot drift out of
step with what the screen actually shows.

---

**FUNCTION:** `validateImage(fileName, bytes)` — `services/image_validation.dart`
**PURPOSE:** Decides whether a picked file is usable before it is uploaded.
**INPUT:** The file name and its bytes.
**OUTPUT:** `null` when valid, otherwise a short message for the user.
**WHY IT EXISTS:** Catches empty, unsupported and unreadable files early. The
answer is valid or invalid — never a percentage.

---

**FUNCTION:** `predictRiceGrade(fileName, bytes)` — `services/rice_api_service.dart`
**PURPOSE:** Uploads the image to `POST /predict`.
**INPUT:** The picked file's name and the bytes the Scan screen already read.
**OUTPUT:** A `PredictionResult`, including a friendly message if the upload
failed.
**WHY IT EXISTS:** Keeps HTTP code out of the screens. The screen only says
"predict this", it does not know about multipart requests or timeouts.

---

**FUNCTION:** `_tryEachHost<T>(...)` — `services/rice_api_service.dart`
**PURPOSE:** Tries every backend address until one answers.
**INPUT:** A function that performs one request against one address.
**OUTPUT:** The first successful answer, or `null` if none worked.
**WHY IT EXISTS:** Every request needs the same timeout, client cleanup and
error handling. Writing it once keeps the four public methods short.

---

**FUNCTION:** `getHistory()` — `services/rice_api_service.dart`
**PURPOSE:** Reads past predictions.
**INPUT:** Nothing.
**OUTPUT:** A list of `PredictionHistoryEntry`, newest first.
**WHY IT EXISTS:** It tries the backend database first and falls back to the
phone's saved copy, so the History screen still works when FastAPI is off.

---

## Running the app

```bash
cd mobile_app
flutter pub get
flutter run                # Android device or emulator
flutter run -d chrome      # browser (or use run_chrome.bat)
```

The server has to be running first, or scans fail with an error on the Scan
screen. The command for it, along with the addresses, model paths and training
commands, is in `docs/DEVELOPMENT.md` — those details are
deliberately kept out of the app itself.
