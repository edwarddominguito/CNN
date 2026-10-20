import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_app/models/prediction_history_entry.dart';
import 'package:mobile_app/services/api_config.dart';
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

  setUp(() => SharedPreferences.setMockInitialValues({}));

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

  test('release builds use only a configured HTTPS backend', () {
    expect(ApiConfig.resolveBaseUrls(isRelease: true), isEmpty);
    expect(ApiConfig.resolveBaseUrls(configuredUrl: 'http://localhost:8000', isRelease: true), isEmpty);
    expect(ApiConfig.resolveBaseUrls(configuredUrl: 'https://rice.up.railway.app/', isRelease: true), hosts);
    for (final url in ['bad address', 'file:///tmp', 'https://user:password@rice.test', 'https://rice.test?q=1']) {
      expect(ApiConfig.resolveBaseUrls(configuredUrl: url, isRelease: true), isEmpty);
    }
    expect(ApiConfig.resolveBaseUrls(isRelease: false, isWeb: false, platform: TargetPlatform.android).first,
        'http://10.0.2.2:8000');
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
    await offline.saveUnsavedPrediction(PredictionHistoryEntry(
      predictedGrade: 'Premium', confidence: 98.7, createdAt: DateTime.utc(2026, 1, 2),
    ));
    final client = TrackingClient((request) async => http.Response('[]', 200));
    expect((await service(client).getHistory()).single.predictedGrade, 'Premium');
    expect((await offline.getHistory()).single.predictedGrade, 'Premium');
    await offline.clearHistory();
    expect(await offline.getHistory(), isEmpty);
  });
}
