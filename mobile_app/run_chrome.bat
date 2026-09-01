@echo off
setlocal
cd /d "%~dp0"
set "LOCAL_BUILD=%LOCALAPPDATA%\CNN-main-mobile-flutter-run-build"
if not exist "%LOCAL_BUILD%" mkdir "%LOCAL_BUILD%"
if not exist ".local_flutter_build\" mklink /J ".local_flutter_build" "%LOCAL_BUILD%" >nul
flutter config --build-dir=.local_flutter_build >nul
flutter pub get
flutter run -d chrome
