import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile_app/services/image_validation.dart';
import 'package:mobile_app/services/rice_api_service.dart';

import 'package:mobile_app/screens/about_screen.dart';
import 'package:mobile_app/screens/guide_screen.dart';
import 'package:mobile_app/screens/history_screen.dart';
import 'package:mobile_app/screens/home_screen.dart';
import 'package:mobile_app/screens/scan_screen.dart';

class UnavailableCameraPicker extends ImagePicker {
  @override
  bool supportsImageSource(ImageSource source) => source != ImageSource.camera;
}

/// Every screen, at a small phone, a phone and a desktop width. Catches layout
/// exceptions and overflows that the analyzer cannot see.
void main() {
  const sizes = [Size(320, 640), Size(400, 800), Size(1400, 900)];
  // A real 3x2 PNG.
  final tinyPng = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAFklEQVR42mM8sW8aAwMDAwMDEwMMAAAmZgIgLUO7vQAAAABJRU5ErkJggg==');

  final screens = <String, Widget Function()>{
    'home': () => const HomeScreen(),
    'scan': () => const ScanScreen(),
    'history': () => const HistoryScreen(),
    'guide': () => const GuideScreen(),
    'about': () => const AboutScreen(),
  };

  // Flutter's test HTTP client refuses every request, so the screens always
  // take their offline path and these stored rows drive the history list.
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'prediction_history': [
        '{"predictedGrade":"Premium","confidence":97.5,'
            '"createdAt":"2026-01-02T03:04:05.000","note":"Close call"}',
        '{"predictedGrade":"Prediction Failed","confidence":0,'
            '"createdAt":"2026-01-01T03:04:05.000","error":"Could not connect"}',
        'not json at all',
      ],
    });
  });

  for (final entry in screens.entries) {
    for (final size in sizes) {
      testWidgets('${entry.key} lays out at ${size.width.toInt()}px', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(MaterialApp(home: entry.value()));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('an unsupported camera shows guidance without opening the picker', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: ScanScreen(imagePicker: UnavailableCameraPicker())));
    await tester.tap(find.text('Take Photo'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The camera is not available on this device.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('history skips rows it cannot parse', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Premium'), findsOneWidget);
    expect(find.text('2 saved · 1 failed'), findsOneWidget);
  });

  // A missing photo costs only its thumbnail, and a kept one opens larger.
  testWidgets('history shows kept photos and a placeholder for a missing one', (tester) async {
    final support = Directory.systemTemp.createTempSync('history_screen_test');
    addTearDown(() => support.deleteSync(recursive: true));
    File('${support.path}/history_photos/1')
      ..createSync(recursive: true)
      ..writeAsBytesSync(tinyPng);
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => support.path);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    SharedPreferences.setMockInitialValues({
      'prediction_history': [
        '{"predictedGrade":"Premium","confidence":97.5,'
            '"createdAt":"2026-01-02T03:04:05.000","imagePath":"1"}',
        '{"predictedGrade":"Well-Milled","confidence":81.25,'
            '"createdAt":"2026-01-01T03:04:05.000","imagePath":"2"}',
      ],
    });

    await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
    await tester.pumpAndSettle();
    // Reading and decoding files is real work the test clock does not wait for.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(find.byIcon(Icons.image_outlined), findsOneWidget); // Only photo 2 is gone.

    await tester.tap(find.text('Premium'));
    await tester.pumpAndSettle();
    expect(find.textContaining('97.50% confidence ·'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // A screen can only stop its spinner if the service always answers it, so
  // these two cover the failures that used to escape as exceptions instead.
  group('RiceApiService answers instead of throwing', () {
    test('history survives a stored value of the wrong type', () async {
      SharedPreferences.setMockInitialValues({
        'prediction_history': 'written by an older build',
      });

      expect(await RiceApiService().getHistory(), isEmpty);
    });

    test('a prediction with no server reachable comes back as an error', () async {
      final result = await RiceApiService().predictRiceGrade(
        'rice.jpg',
        Uint8List.fromList([1, 2, 3, 4]),
      );

      expect(result.error, isNotNull);
      expect(result.savedByBackend, isFalse);
    });
  });

  group('validateImage', () {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);

    test('rejects an empty file', () async {
      expect(await validateImage('rice.jpg', Uint8List(0)), isNotNull);
    });

    test('rejects an unsupported format', () async {
      final message = await validateImage('rice.heic', bytes);
      expect(message, contains('Unsupported'));
    });

    test('rejects bytes that are not an image', () async {
      expect(await validateImage('rice.jpg', bytes), isNotNull);
    });

    // Also run with --platform chrome: the web engine cannot size an image
    // before decoding it, so it takes a different path through validateImage.
    test('accepts a real still image', () async {
      expect(await validateImage('rice.png', tinyPng), isNull);
    });
  });
}
