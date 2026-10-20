# Rice classifier Flutter app

Install Flutter with Dart 3.10.4 or later, then run `flutter pub get`.

Connect a production build to your Railway backend with:

```sh
flutter build apk --release --dart-define=API_BASE_URL=https://your-backend.up.railway.app
flutter build web --release --dart-define=API_BASE_URL=https://your-backend.up.railway.app
```

Replace the example with the backend's public HTTPS domain. This value is
embedded at build time. Release builds require a valid HTTPS URL and show a
configuration error when it is missing. Rebuild after changing the domain.
For a separately hosted web build, also allow its origin in backend
`CORS_ORIGINS`.

Debug builds use localhost on desktop/web and `10.0.2.2:8000` on an Android
emulator. For a physical phone, use the Railway HTTPS URL or your computer's
LAN address with `flutter run --dart-define=API_BASE_URL=http://YOUR_PC_IP:8000`.
Android HTTP access is enabled only for debug builds.

Run `flutter analyze` and `flutter test` before building. Uploads have a
two-minute deadline, and HTTP clients close when requests finish or time out.
Only valid server predictions are displayed; network failures remain errors.
The app keeps an offline copy of downloaded history.

The Android project currently uses the debug signing key for release builds.
Configure your own signing key before publishing through an app store.
