import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile_app/services/image_validation.dart';
import 'package:mobile_app/services/rice_api_service.dart';

import 'package:mobile_app/screens/about_screen.dart';
import 'package:mobile_app/screens/guide_screen.dart';
import 'package:mobile_app/screens/history_screen.dart';
import 'package:mobile_app/screens/home_screen.dart';
import 'package:mobile_app/screens/scan_screen.dart';

/// Every screen, at a phone width and a desktop width. Catches layout
/// exceptions and overflows that the analyzer cannot see.
void main() {
  const sizes = [Size(400, 800), Size(1400, 900)];

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

  testWidgets('history skips rows it cannot parse', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Premium'), findsOneWidget);
    expect(find.text('2 saved · 1 failed'), findsOneWidget);
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
  });
}
