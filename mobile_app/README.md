# Rice classifier Flutter app

Install Flutter with Dart 3.10.4 or later, then run `flutter pub get`.

All builds default to `https://cnn-production-c269.up.railway.app`.
To use a different backend, override the address when building:

```sh
flutter build apk --release --dart-define=API_BASE_URL=https://your-backend.up.railway.app
flutter build web --release --dart-define=API_BASE_URL=https://your-backend.up.railway.app
```

Replace the example with the backend's public HTTPS domain. This value is
embedded at build time. Release builds require a valid HTTPS URL and show a
configuration error when an empty or invalid override is provided. Rebuild
after changing the domain.
For a separately hosted web build, also allow its origin in backend
`CORS_ORIGINS`.

Debug builds also use Railway by default. To use a local backend, explicitly
pass `--dart-define=API_BASE_URL=http://127.0.0.1:8000` on desktop/web,
`http://10.0.2.2:8000` on an Android emulator, or your computer's LAN address
for a physical phone.
Android HTTP access is enabled only for debug builds.

Run `flutter analyze` and `flutter test` before building. Uploads have a
two-minute deadline, and HTTP clients close when requests finish or time out.
Only valid server predictions are displayed; network failures remain errors.
The app keeps an offline copy of downloaded history. History operations are
serialized across screens so concurrent saves and refreshes cannot overwrite
each other. A failed server deletion keeps both local history copies and shows
a retry message. Animated images are rejected before preview.

The Android project currently uses the debug signing key for release builds.
Configure your own signing key before publishing through an app store.
