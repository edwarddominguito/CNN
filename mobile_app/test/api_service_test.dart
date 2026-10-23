import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_app/models/prediction_history_entry.dart';
import 'package:mobile_app/models/prediction_result.dart';
import 'package:mobile_app/services/api_config.dart';
import 'package:mobile_app/services/image_validation.dart';
import 'package:mobile_app/services/rice_api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TrackingClient extends MockClient {
  bool closed = false;
  TrackingClient(super.fn);

  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final image = Uint8List.fromList([1, 2, 3, 4]);
  const hosts = ['https://rice.up.railway.app'];
  RiceApiService service(http.Client client, {Duration? timeout}) => RiceApiService(
    baseUrls: hosts,
    clientFactory: () => client,
    uploadTimeout: timeout ?? const Duration(seconds: 2),
  );
  const unsaved = PredictionResult(predictedGrade: 'Premium', confidence: 98.7);

  // A temporary photo folder per test, so no test touches a real app folder.
  Future<Directory> tempPhotoFolder() async {
    final folder = await Directory.systemTemp.createTemp('history_photos_test');
    addTearDown(() => folder.delete(recursive: true));
    return folder;
  }

  // Answers like the backend: /predict saves a row without a photo, taking
  // its result from [replies], and /history lists the newest rows or clears them.
  http.Client fakeBackend(List<Map<String, Object>> rows, List<(String, double)> replies, {
    bool includeHistoryId = true,
  }) {
    return MockClient((request) async {
      if (request.url.path == '/predict') {
        final (grade, confidence) = replies.removeAt(0);
        rows.insert(0, {
          'id': rows.length + 1,
          'predictedGrade': grade,
          'confidence': confidence,
          'createdAt': DateTime.utc(2026, 1, 1, 0, rows.length).toIso8601String(),
        });
        return http.Response(jsonEncode({
          'predicted_grade': grade,
          'confidence': confidence,
          if (includeHistoryId) 'history_id': rows.first['id'],
        }), 200);
      }
      if (request.method == 'DELETE') {
        rows.clear();
        return http.Response('{}', 200);
      }
      final limit = int.parse(request.url.queryParameters['limit'] ?? '50');
      return http.Response(jsonEncode(rows.take(limit).toList()), 200);
    });
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RiceApiService.forgetClientId();
  });

  test('every request carries one stable client ID that keeps history private', () async {
    final sent = <String?>[];
    final client = TrackingClient((request) async {
      sent.add(request.headers['X-Client-Id']);
      if (request.url.path == '/predict') {
        return http.Response(jsonEncode({'predicted_grade': 'Premium', 'confidence': 98.7}), 200);
      }
      return http.Response(request.method == 'GET' ? '[]' : '{}', 200);
    });
    final api = service(client);
    await api.predictRiceGrade('rice.jpg', image);
    await api.getHistory();
    await api.addToHistory(unsaved, image);
    expect(await api.clearHistory(), isTrue);

    expect(sent, hasLength(4));
    expect(sent.toSet(), hasLength(1));
    expect(sent.first, matches(RegExp(r'^[0-9a-f]{32}$')));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('history_client_id'), sent.first);
  });

  test('a saved client ID is reused after the app restarts', () async {
    final saved = 'f0' * 16;
    SharedPreferences.setMockInitialValues({'history_client_id': saved});
    String? sent;
    final client = TrackingClient((request) async {
      sent = request.headers['X-Client-Id'];
      return http.Response('[]', 200);
    });
    await service(client).getHistory();
    expect(sent, saved);
  });

  test('animated PNG files are rejected before creating a live preview', () async {
    final bytes = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAACAAAAAgAAAAAAAAAAAAEACgAA6FTcAAAAABBJREFUeJxj/M8AAkxgkgEADR0BA4LJcf8AAAAaZmNUTAAAAAEAAAACAAAAAgAAAAAAAAAAAAEACgAAcyc21AAAABZmZEFUAAAAAnicY2Rg+M/AwMDEAAYACx8BAyVgX34AAAAASUVORK5CYII=');
    expect(await validateImage('rice.png', bytes), contains('Animated'));
  });

  test('history timestamps include UTC and preserve the original instant', () {
    final original = DateTime(2026, 1, 2, 11, 4, 5);
    final entry = PredictionHistoryEntry(
      predictedGrade: 'Premium', confidence: 98.7, createdAt: original,
    );
    final serialized = entry.toJson()['createdAt'] as String;
    expect(serialized, endsWith('Z'));
    expect(DateTime.parse(serialized).isAtSameMomentAs(original), isTrue);
    expect(PredictionHistoryEntry.fromJson(entry.toJson()).createdAt.isAtSameMomentAs(original), isTrue);
  });

  test('debug and release builds default to Railway and validate overrides', () {
    const railway = ['https://cnn-production-c269.up.railway.app'];
    expect(ApiConfig.resolveBaseUrls(isRelease: false), railway);
    expect(ApiConfig.resolveBaseUrls(isRelease: true), railway);
    expect(ApiConfig.resolveBaseUrls(configuredUrl: '', isRelease: false), isEmpty);
    expect(ApiConfig.resolveBaseUrls(configuredUrl: '', isRelease: true), isEmpty);
    expect(ApiConfig.resolveBaseUrls(configuredUrl: 'http://localhost:8000', isRelease: true), isEmpty);
    expect(ApiConfig.resolveBaseUrls(configuredUrl: 'https://rice.up.railway.app/', isRelease: true), hosts);
    for (final url in ['bad address', 'file:///tmp', 'https://user:password@rice.test', 'https://rice.test?q=1']) {
      expect(ApiConfig.resolveBaseUrls(configuredUrl: url, isRelease: true), isEmpty);
    }
  });

  test('predict uploads multipart, reads real percentages, and closes the client', () async {
    final client = TrackingClient((request) async {
      expect(request.url.toString(), '${hosts.single}/predict');
      expect(request.method, 'POST');
      expect(request.headers['content-type'], startsWith('multipart/form-data'));
      return http.Response(jsonEncode({'predicted_grade': 'Premium', 'confidence': 98.7}), 200);
    });
    final result = await service(client).predictRiceGrade('rice.jpg', image);
    expect(result.predictedGrade, 'Premium');
    expect(result.confidence, 98.7);
    expect(result.savedByBackend, isTrue);
    expect(result.error, isNull);
    expect(client.closed, isTrue);
  });

  test('HTML proxy failures preserve the server status', () async {
    final client = TrackingClient((request) async => http.Response('<h1>Unavailable</h1>', 503));
    final result = await service(client).predictRiceGrade('rice.jpg', image);
    expect(result.error, contains('503'));
    expect(client.closed, isTrue);
  });

  test('valid predictions honor a backend history write failure', () async {
    final client = TrackingClient((request) async => http.Response(jsonEncode({
      'predicted_grade': 'Premium', 'confidence': 98.7, 'history_saved': false,
    }), 200));
    final result = await service(client).predictRiceGrade('rice.jpg', image);
    expect(result.error, isNull);
    expect(result.savedByBackend, isFalse);
    expect(result.predictedGrade, 'Premium');
  });

  test('invalid successful replies are failures, never invented grades', () async {
    for (final body in [
      {},
      {'predicted_grade': '', 'confidence': 20},
      {'predicted_grade': 'Premium', 'confidence': 'NaN'},
      {'predicted_grade': 'Premium', 'confidence': 101},
      {'error': {}},
    ]) {
      final client = TrackingClient((request) async => http.Response(jsonEncode(body), 200));
      final result = await service(client).predictRiceGrade('rice.jpg', image);
      expect(result.error, isNotNull);
      expect(result.savedByBackend, isFalse);
    }
  });

  test('a stalled request closes its underlying HTTP client on timeout', () async {
    final client = TrackingClient((request) => Completer<http.Response>().future);
    final result = await service(client, timeout: const Duration(milliseconds: 10))
        .predictRiceGrade('rice.jpg', image);
    expect(result.error, isNotNull);
    expect(client.closed, isTrue);
  });

  test('an oversized image never creates an HTTP client', () async {
    final api = RiceApiService(clientFactory: () => throw StateError('Should not open a connection'));
    final result = await api.predictRiceGrade('rice.jpg', Uint8List(15 * 1024 * 1024 + 1));
    expect(result.error, contains('15 MB'));
  });

  test('downloaded history remains available when the backend goes offline', () async {
    final client = TrackingClient((request) async => http.Response(jsonEncode([
      {'predictedGrade': 'Premium', 'confidence': 98.7, 'createdAt': '2026-01-02T03:04:05.000'},
    ]), 200));
    expect((await service(client).getHistory()).single.predictedGrade, 'Premium');
    final offline = RiceApiService(baseUrls: []);
    expect((await offline.getHistory()).single.predictedGrade, 'Premium');
  });

  test('history refresh preserves results left unsaved during a database outage', () async {
    final offline = RiceApiService(baseUrls: []);
    await offline.addToHistory(unsaved, image);
    final client = TrackingClient((request) async => http.Response('[]', 200));
    expect((await service(client).getHistory()).single.predictedGrade, 'Premium');
    expect((await offline.getHistory()).single.predictedGrade, 'Premium');
    expect(await offline.clearHistory(), isFalse);
    expect((await offline.getHistory()).single.predictedGrade, 'Premium');
  });

  test('failed remote deletion preserves downloaded and unsaved history', () async {
    const row = '{"predictedGrade":"Premium","confidence":98.7,"createdAt":"2026-01-02T03:04:05Z"}';
    SharedPreferences.setMockInitialValues({
      'prediction_history': [row], 'unsaved_prediction_history': [row],
    });
    final api = service(TrackingClient((request) async => http.Response('Unavailable', 503)));
    expect(await api.clearHistory(), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('prediction_history'), [row]);
    expect(prefs.getStringList('unsaved_prediction_history'), [row]);
  });

  test('simultaneous offline saves from different screens retain both records', () async {
    final first = RiceApiService(baseUrls: []);
    final second = RiceApiService(baseUrls: []);
    await Future.wait([
      first.addToHistory(unsaved, image), second.addToHistory(unsaved, image),
    ]);
    expect(await first.getHistory(), hasLength(2));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('unsaved_prediction_history'), hasLength(2));
  });

  test('a history refresh cannot resurrect records after a successful clear', () async {
    final reply = Completer<http.Response>();
    final started = Completer<void>();
    final api = RiceApiService(baseUrls: hosts, clientFactory: () => TrackingClient((request) async {
      if (request.method == 'DELETE') return http.Response('{}', 200);
      started.complete();
      return reply.future;
    }));
    final refreshing = api.getHistory();
    await started.future;
    final clearing = api.clearHistory();
    await Future<void>.delayed(Duration.zero);
    reply.complete(http.Response(jsonEncode([
      {'predictedGrade': 'Premium', 'confidence': 98.7, 'createdAt': '2026-01-02T03:04:05Z'},
    ]), 200));
    await refreshing;
    await clearing;
    expect(await RiceApiService(baseUrls: []).getHistory(), isEmpty);
  });

  group('History photos', () {
    test('identical overlapping predictions keep the photo for their exact row', () async {
      final folder = await tempPhotoFolder();
      final backend = fakeBackend([], [('Premium', 98.7), ('Premium', 98.7)]);
      final api = RiceApiService(
        baseUrls: hosts, clientFactory: () => backend, photoFolder: () async => folder,
      );
      final firstPhoto = Uint8List.fromList([1, 1]);
      final secondPhoto = Uint8List.fromList([2, 2]);
      // Both backend rows exist before the first screen gets to save its photo.
      final first = await api.predictRiceGrade('first.jpg', firstPhoto);
      final second = await api.predictRiceGrade('second.jpg', secondPhoto);
      expect(first.historyId, 1);
      expect(second.historyId, 2);
      await api.addToHistory(first, firstPhoto);
      await api.addToHistory(second, secondPhoto);

      final history = await api.getHistory();
      for (final entry in history) {
        expect(await RiceApiService.photoFile(folder, entry.imagePath)!.readAsBytes(),
            entry.id == first.historyId ? firstPhoto : secondPhoto);
      }
    });

    test('an exact saved row stays available when history goes offline immediately', () async {
      final folder = await tempPhotoFolder();
      final client = MockClient((request) async => request.url.path == '/predict'
          ? http.Response(jsonEncode({
              'predicted_grade': 'Premium', 'confidence': 98.7, 'history_id': 42,
            }), 200)
          : http.Response('Unavailable', 503));
      final api = RiceApiService(
        baseUrls: hosts, clientFactory: () => client, photoFolder: () async => folder,
      );
      await api.addToHistory(await api.predictRiceGrade('rice.jpg', image), image);
      final row = (await api.getHistory()).single;
      expect(row.id, 42);
      expect(await RiceApiService.photoFile(folder, row.imagePath)!.readAsBytes(), image);
    });

    test('an older server with ambiguous rows cannot attach the wrong photo', () async {
      final folder = await tempPhotoFolder();
      final backend = fakeBackend([], [('Premium', 98.7), ('Premium', 98.7)],
          includeHistoryId: false);
      final api = RiceApiService(
        baseUrls: hosts, clientFactory: () => backend, photoFolder: () async => folder,
      );
      final first = await api.predictRiceGrade('first.jpg', image);
      await api.predictRiceGrade('second.jpg', image);
      await api.addToHistory(first, image);
      expect((await api.getHistory()).map((row) => row.imagePath), everyElement(isNull));
      expect(await folder.list().toList(), isEmpty);
    });

    test('each photo stays with its own result, after a restart and offline', () async {
      final folder = await tempPhotoFolder();
      final backend = fakeBackend([], [('Premium', 98.7), ('Well-Milled', 64.2), ('Premium', 98.7)],
          includeHistoryId: false);
      RiceApiService api() => RiceApiService(
        baseUrls: hosts, clientFactory: () => backend, photoFolder: () async => folder,
      );
      final photos = [for (var i = 1; i <= 3; i++) Uint8List.fromList([i, i])];
      for (final photo in photos) {
        final scan = api();
        await scan.addToHistory(await scan.predictRiceGrade('rice.jpg', photo), photo);
      }

      // A restart keeps nothing in memory, only what the device stored.
      RiceApiService.forgetClientId();
      final history = await api().getHistory();
      expect(history.map((entry) => entry.predictedGrade), ['Premium', 'Well-Milled', 'Premium']);
      for (final (index, entry) in history.indexed) {
        expect(await RiceApiService.photoFile(folder, entry.imagePath)!.readAsBytes(), photos[2 - index]);
      }
      final offline = await RiceApiService(baseUrls: [], photoFolder: () async => folder).getHistory();
      expect(offline.map((entry) => entry.imagePath), history.map((entry) => entry.imagePath));
    });

    test('a deleted photo file leaves History intact', () async {
      final folder = await tempPhotoFolder();
      final backend = fakeBackend([], [('Premium', 98.7)]);
      final api = RiceApiService(
        baseUrls: hosts, clientFactory: () => backend, photoFolder: () async => folder,
      );
      await api.addToHistory(await api.predictRiceGrade('rice.jpg', image), image);
      await for (final file in folder.list()) {
        await file.delete();
      }
      expect((await api.getHistory()).single.predictedGrade, 'Premium');
    });

    test('a failed prediction, or one whose row cannot be found, keeps no photo', () async {
      final folder = await tempPhotoFolder();
      final failing = RiceApiService(
        baseUrls: hosts, photoFolder: () async => folder,
        clientFactory: () => MockClient((request) async => http.Response('Unavailable', 503)),
      );
      await failing.addToHistory(await failing.predictRiceGrade('rice.jpg', image), image);
      // Saved by /predict, but History cannot be read to find its row.
      final unlinkable = RiceApiService(
        baseUrls: hosts, photoFolder: () async => folder,
        clientFactory: () => MockClient((request) async => request.method == 'POST'
            ? http.Response(jsonEncode({'predicted_grade': 'Premium', 'confidence': 98.7}), 200)
            : http.Response('Unavailable', 503)),
      );
      await unlinkable.addToHistory(await unlinkable.predictRiceGrade('rice.jpg', image), image);

      expect(await folder.list().toList(), isEmpty);
      final kept = await RiceApiService(baseUrls: [], photoFolder: () async => folder).getHistory();
      expect(kept.single.error, isNotNull); // The failure is still listed, without a photo.
      expect(kept.single.imagePath, isNull);
    });

    test('a prediction a database outage left unsaved keeps its photo', () async {
      final folder = await tempPhotoFolder();
      final api = RiceApiService(
        baseUrls: hosts, photoFolder: () async => folder,
        clientFactory: () => MockClient((request) async => request.url.path == '/predict'
            ? http.Response(jsonEncode({
                'predicted_grade': 'Premium', 'confidence': 98.7, 'history_saved': false,
              }), 200)
            : http.Response('Unavailable', 503)),
      );
      await api.addToHistory(await api.predictRiceGrade('rice.jpg', image), image);
      final entry = (await RiceApiService(baseUrls: [], photoFolder: () async => folder).getHistory()).single;
      expect(await RiceApiService.photoFile(folder, entry.imagePath)!.readAsBytes(), image);
    });

    test('a recovered history save keeps its exact row and local photo on refresh', () async {
      final folder = await tempPhotoFolder();
      final client = MockClient((request) async {
        if (request.method == 'POST') return http.Response('{"id":42,"saved":true}', 200);
        // The server does not need the device's private file name to list rows.
        return http.Response(jsonEncode([{
          'id': 42, 'predictedGrade': 'Premium', 'confidence': 98.7,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        }]), 200);
      });
      final api = RiceApiService(
        baseUrls: hosts, clientFactory: () => client, photoFolder: () async => folder,
      );
      await api.addToHistory(unsaved, image);
      final offline = RiceApiService(baseUrls: [], photoFolder: () async => folder);
      expect((await offline.getHistory()).single.id, 42);
      final refreshed = (await api.getHistory()).single;
      expect(refreshed.id, 42);
      expect(await RiceApiService.photoFile(folder, refreshed.imagePath)!.readAsBytes(), image);
    });

    test('clearing History deletes its photos', () async {
      final folder = await tempPhotoFolder();
      final backend = fakeBackend([], [('Premium', 98.7)]);
      final api = RiceApiService(
        baseUrls: hosts, clientFactory: () => backend, photoFolder: () async => folder,
      );
      await api.addToHistory(await api.predictRiceGrade('rice.jpg', image), image);
      expect(await folder.list().toList(), hasLength(1));
      expect(await api.clearHistory(), isTrue);
      expect(await folder.list().toList(), isEmpty);
    });

    test('photos of rows that drop out of History are deleted', () async {
      final folder = await tempPhotoFolder();
      final stray = await File('${folder.path}/left-by-an-interrupted-save').create();
      final backend = fakeBackend([], [for (var i = 0; i < 26; i++) ('Premium', 50.0 + i)]);
      final api = RiceApiService(
        baseUrls: hosts, clientFactory: () => backend, photoFolder: () async => folder,
      );
      for (var i = 0; i < 26; i++) {
        final photo = Uint8List.fromList([i]);
        await api.addToHistory(await api.predictRiceGrade('rice.jpg', photo), photo);
      }

      expect(await stray.exists(), isFalse);
      final history = await api.getHistory();
      expect(history, hasLength(25));
      expect(await folder.list().toList(), hasLength(25));
      for (final entry in history) {
        expect(await RiceApiService.photoFile(folder, entry.imagePath)!.exists(), isTrue);
      }
    });

    test('a stored photo name can never point outside the photo folder', () {
      final folder = Directory('photos');
      expect(RiceApiService.photoFile(folder, '1700000000000000')?.path, 'photos/1700000000000000');
      for (final name in ['../shared_prefs.xml', r'..\secret', '/data/user/0/app/cache/x.jpg']) {
        expect(RiceApiService.photoFile(folder, name), isNull);
      }
      expect(RiceApiService.photoFile(null, '1700000000000000'), isNull);
    });
  });
}
