import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

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

  // A missing photo costs only its thumbnail, and every result opens for review.
  testWidgets('history shows kept photos and a placeholder for a missing one', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    expect(find.text('Scan Details'), findsOneWidget);
    expect(find.text('97.5%'), findsOneWidget); // the result card the Scan screen shows
    expect(find.text('About Premium'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // The web has no photo folder, so its photos are reduced copies in local storage.
  testWidgets('history shows photos kept in local storage, at desktop width', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    SharedPreferences.setMockInitialValues({
      'prediction_history': [
        '{"predictedGrade":"Premium","confidence":97.5,'
            '"createdAt":"2026-01-02T03:04:05.000","imagePath":"1"}',
        '{"predictedGrade":"Well-Milled","confidence":81.25,'
            '"createdAt":"2026-01-01T03:04:05.000","imagePath":"2"}',
      ],
      'history_photos/1': base64Encode(tinyPng),
    });

    await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(find.byIcon(Icons.image_outlined), findsOneWidget); // Photo 2 was never kept.

    await tester.tap(find.text('Well-Milled'));
    await tester.pumpAndSettle();
    expect(find.text('No photo of this scan is kept on this device.'), findsOneWidget);
    expect(find.text('About Well-Milled'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('the full-screen photo viewer', () {
    const twoScans = [
      '{"predictedGrade":"Premium","confidence":97.5,'
          '"createdAt":"2026-01-02T03:04:05.000","imagePath":"1"}',
      '{"predictedGrade":"Well-Milled","confidence":81.25,'
          '"createdAt":"2026-01-01T03:04:05.000","imagePath":"2"}',
    ];
    final viewer = find.byType(InteractiveViewer);
    final shownPhoto = find.descendant(of: viewer, matching: find.byType(RawImage));

    // Gives the app a private photo folder holding [photos], as on a phone.
    void keepPhotos(Map<String, List<int>> photos) {
      final support = Directory.systemTemp.createTempSync('photo_viewer_test');
      addTearDown(() => support.deleteSync(recursive: true));
      for (final photo in photos.entries) {
        File('${support.path}/history_photos/${photo.key}')
          ..createSync(recursive: true)
          ..writeAsBytesSync(photo.value);
      }
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async => support.path);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }

    // Reading and decoding files is real work the test clock does not wait for.
    Future<void> letPhotosLoad(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
    }

    // The viewer shows a spinner until its photo is decoded, so these pump a
    // fixed time instead of waiting for the screen to settle.
    Future<void> openViewer(WidgetTester tester, Finder photo) async {
      await tester.tap(photo);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    String openedFile(WidgetTester tester) {
      final opened = tester.widget<Image>(find.descendant(of: viewer, matching: find.byType(Image)));
      return ((opened.image as ResizeImage).imageProvider as FileImage).file.path;
    }

    Future<Uint8List> pngOfSize(int width, int height) async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        ui.Paint()..color = const ui.Color(0xFFD7CCC8),
      );
      final image = await recorder.endRecording().toImage(width, height);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return png!.buffer.asUint8List();
    }

    testWidgets('opens the right photo from History and from Scan Details', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Wider than the 4096 pixels the viewer decodes, like a 50-megapixel photo.
      final widePng = (await tester.runAsync(() => pngOfSize(5000, 50)))!;
      keepPhotos({'1': tinyPng, '2': widePng});
      SharedPreferences.setMockInitialValues({'prediction_history': twoScans});

      await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
      await tester.pumpAndSettle();
      await letPhotosLoad(tester);

      // The second row's thumbnail opens the second row's photo.
      await openViewer(tester, find.byTooltip('View photo').at(1));
      expect(find.descendant(of: viewer, matching: find.byType(CircularProgressIndicator)), findsOneWidget);
      await letPhotosLoad(tester);
      expect(openedFile(tester), endsWith('history_photos/2'));
      expect(tester.widget<RawImage>(shownPhoto).image!.width, 4096); // reduced while decoding
      expect(tester.getSize(shownPhoto), const Size(400, 400 * 40 / 4096)); // fitted, same shape
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(viewer, findsNothing);
      expect(find.text('2 saved'), findsOneWidget); // back on the History list

      // The photo on Scan Details opens that scan's photo.
      await tester.tap(find.text('Premium'));
      await tester.pumpAndSettle();
      await openViewer(tester, find.byTooltip('View photo'));
      await letPhotosLoad(tester);
      expect(openedFile(tester), endsWith('history_photos/1'));
      expect(tester.getSize(shownPhoto), const Size(3, 2)); // its own size, never enlarged
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Scan Details'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('zooms by double-tap and pinch, moves, and fits back', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      keepPhotos({'1': tinyPng});
      SharedPreferences.setMockInitialValues({'prediction_history': twoScans});
      await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
      await tester.pumpAndSettle();
      await letPhotosLoad(tester);
      await openViewer(tester, find.byTooltip('View photo').first);
      await letPhotosLoad(tester);
      Matrix4 zoom() => tester.widget<InteractiveViewer>(viewer).transformationController!.value;

      // A double-tap zooms in around the tapped spot, which stays in place.
      final spot = tester.getCenter(viewer) + const Offset(30, -40);
      await tester.tapAt(spot);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(spot);
      await tester.pumpAndSettle();
      expect(zoom().getMaxScaleOnAxis(), 3);
      final local = spot - tester.getTopLeft(viewer);
      expect(MatrixUtils.transformPoint(zoom(), local), offsetMoreOrLessEquals(local));

      await tester.tap(find.byTooltip('Fit to screen'));
      await tester.pump();
      expect(zoom().isIdentity(), isTrue);
      expect(find.byTooltip('Fit to screen'), findsNothing);

      // Two fingers spread apart zoom in; one finger then moves the photo.
      final center = tester.getCenter(viewer);
      final first = await tester.startGesture(center - const Offset(20, 0));
      final second = await tester.startGesture(center + const Offset(20, 0));
      for (var i = 0; i < 5; i++) {
        await first.moveBy(const Offset(-12, 0));
        await second.moveBy(const Offset(12, 0));
        await tester.pump();
      }
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(zoom().getMaxScaleOnAxis(), greaterThan(2));
      final before = zoom().getTranslation().x;
      await tester.dragFrom(center, const Offset(60, 0));
      await tester.pumpAndSettle();
      expect(zoom().getTranslation().x, greaterThan(before));

      // A double-tap while zoomed in returns to the whole photo.
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(zoom().isIdentity(), isTrue);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(viewer, findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('says "Photo unavailable" for a damaged or missing file', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      keepPhotos({'1': utf8.encode('not an image')}); // photo 2 is missing
      SharedPreferences.setMockInitialValues({'prediction_history': twoScans});
      await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
      await tester.pumpAndSettle();
      await letPhotosLoad(tester);
      expect(find.byIcon(Icons.image_outlined), findsNWidgets(2)); // both fall back

      for (var row = 0; row < 2; row++) {
        await openViewer(tester, find.byTooltip('View photo').at(row));
        await letPhotosLoad(tester);
        expect(find.text('Photo unavailable'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        expect(find.text('2 saved'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
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
