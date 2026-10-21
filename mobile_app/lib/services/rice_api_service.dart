import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/prediction_history_entry.dart';
import '../models/prediction_result.dart';
import 'api_config.dart';

/// Everything the app sends to, or reads from, the FastAPI backend.
///
/// If the backend cannot be reached, the history is kept in a small copy on
/// the phone so the History screen still has something to show.
///
/// No method here throws. A screen that called one of these can always show
/// its answer and stop its spinner, whatever went wrong underneath.
class RiceApiService {
  final http.Client Function() _clientFactory;
  final List<String>? _baseUrls;
  final Duration _uploadTimeout;
  final Duration _quickTimeout;

  RiceApiService({
    http.Client Function()? clientFactory,
    List<String>? baseUrls,
    Duration uploadTimeout = const Duration(seconds: 120),
    Duration quickTimeout = const Duration(seconds: 5),
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _baseUrls = baseUrls,
       _uploadTimeout = uploadTimeout,
       _quickTimeout = quickTimeout;

  static const _historyKey = 'prediction_history';
  static const _unsavedHistoryKey = 'unsaved_prediction_history';
  static const _historyLimit = 25;
  // Screens use separate service instances but share the same local store.
  static Completer<void>? _historyOperation;

  Future<T> _withHistoryLock<T>(Future<T> Function() operation) async {
    while (_historyOperation != null) {
      await _historyOperation!.future;
    }
    final release = Completer<void>();
    _historyOperation = release;
    try {
      return await operation();
    } finally {
      _historyOperation = null;
      release.complete();
    }
  }

  /// Uploads the picked image to POST /predict and returns the model's answer.
  ///
  /// The screen has already read the file for its preview, so it passes the
  /// bytes in rather than making this read the same file a second time.
  Future<PredictionResult> predictRiceGrade(String fileName, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 15 * 1024 * 1024) {
      return _failed('Please select a non-empty image under 15 MB.');
    }
    final result = await _tryEachHost<PredictionResult>((baseUrl, client) async {
      final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/predict'));
      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: fileName),
      );

      final streamed = await client.send(request);
      final response = await http.Response.fromStream(streamed);
      final data = _decodeObject(response.body);

      if (response.statusCode != 200) {
        final message = data['detail'] ?? data['error'];
        return _failed(message?.toString() ?? 'Server error (${response.statusCode})');
      }

      // A 200 with no grade in it is not a prediction. Showing "Unknown 0%"
      // as if the model had answered would be inventing a result.
      final grade = toStringOrNull(data['predicted_grade']);
      final confidence = toDoubleOrNull(data['confidence']);
      final error = toStringOrNull(data['error']);
      if ((data['error'] != null && error == null) ||
          (error == null &&
              (grade == null || confidence == null || !confidence.isFinite ||
                  confidence < 0 || confidence > 100))) {
        return _failed('The server sent a reply this app could not read.');
      }

      return PredictionResult.fromJson(data);
    }, timeout: _uploadTimeout);

    return result ??
        _failed(ApiConfig.configurationError ??
            'Could not reach the server. Please check your connection and try again.');
  }

  /// The backend's history when it is reachable, otherwise the phone's copy.
  Future<List<PredictionHistoryEntry>> getHistory() => _withHistoryLock(() async {
    final remoteEntries = await _tryEachHost<List<PredictionHistoryEntry>>((baseUrl, client) async {
      final response = await client
          .get(Uri.parse('$baseUrl/history?limit=$_historyLimit'))
          .timeout(_quickTimeout);
      if (response.statusCode != 200) {
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! List) {
        return null;
      }

      return decoded
          .whereType<Map<String, dynamic>>()
          .map(PredictionHistoryEntry.fromJson)
          .toList();
    });

    if (remoteEntries == null) return _readLocalHistory();
    final entries = [
      ...remoteEntries,
      ...await _readLocalHistory(key: _unsavedHistoryKey),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    await _writeLocalHistory(entries);
    return entries.take(_historyLimit).toList();
  });

  /// Saves a client failure or a prediction left unsaved by a database outage.
  /// Only call this when [PredictionResult.savedByBackend] is false.
  Future<void> saveUnsavedPrediction(PredictionHistoryEntry entry) => _withHistoryLock(() async {
    final saved = await _tryEachHost<bool>((baseUrl, client) async {
      final response = await client
          .post(
            Uri.parse('$baseUrl/history'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(entry.toJson()),
          )
          .timeout(_quickTimeout);
      return response.statusCode == 200 ? true : null;
    });

    if (saved == null) {
      final unsaved = [entry, ...await _readLocalHistory(key: _unsavedHistoryKey)];
      await _writeLocalHistory(unsaved, key: _unsavedHistoryKey);
    }
    await _writeLocalHistory([entry, ...await _readLocalHistory()]);
  });

  /// Failed server deletion must preserve the local copies for a later retry.
  Future<bool> clearHistory() => _withHistoryLock(() async {
    final cleared = await _tryEachHost<bool>((baseUrl, client) async {
      final response = await client.delete(Uri.parse('$baseUrl/history')).timeout(_quickTimeout);
      return response.statusCode == 200 ? true : null;
    });

    if (cleared != true) return false;
    await _writeLocalHistory([]);
    await _writeLocalHistory([], key: _unsavedHistoryKey);
    return true;
  });

  /// Runs [sendRequest] against each address from [ApiConfig] until one of them
  /// gives an answer. Returns null when none of them work.
  Future<T?> _tryEachHost<T>(
    Future<T?> Function(String baseUrl, http.Client client) sendRequest, {
    Duration? timeout,
  }) async {
    for (final baseUrl in _baseUrls ?? ApiConfig.baseUrls) {
      http.Client? client;
      try {
        client = _clientFactory();
        final result = await sendRequest(baseUrl, client).timeout(timeout ?? _quickTimeout);
        if (result != null) {
          return result;
        }
      } catch (_) {
        continue; // This address did not work, try the next one.
      } finally {
        client?.close();
      }
    }
    return null;
  }

  Future<List<PredictionHistoryEntry>> _readLocalHistory({String key = _historyKey}) async {
    List<String> rows;
    try {
      final prefs = await SharedPreferences.getInstance();
      rows = prefs.getStringList(key) ?? [];
    } catch (_) {
      // The device store is unavailable, or an older build of the app wrote a
      // different type under this key. An empty list beats a stuck History.
      return [];
    }

    // One unreadable row should not empty the whole History screen, so bad
    // rows are skipped instead.
    final entries = <PredictionHistoryEntry>[];
    for (final row in rows) {
      try {
        final decoded = jsonDecode(row);
        if (decoded is Map<String, dynamic>) {
          entries.add(PredictionHistoryEntry.fromJson(decoded));
        }
      } catch (_) {
        continue;
      }
    }

    entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return entries;
  }

  /// Replaces the phone's copy of the history.
  ///
  /// Best effort on purpose: this copy only exists so the History screen has
  /// something to show while the backend is unreachable, and failing to write
  /// it must never break the screen the user is looking at.
  Future<void> _writeLocalHistory(List<PredictionHistoryEntry> entries, {String key = _historyKey}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        key,
        entries.take(_historyLimit).map((entry) => jsonEncode(entry.toJson())).toList(),
      );
    } catch (error) {
      debugPrint('Could not save the offline history copy: $error');
    }
  }

  PredictionResult _failed(String error) {
    return PredictionResult(
      predictedGrade: 'Prediction Failed',
      confidence: 0,
      error: error,
    );
  }

  /// The response body as a JSON object, or an empty one. A body that is not
  /// JSON at all (an error page from a proxy, say) must not hide the status
  /// code behind a parsing exception.
  Map<String, dynamic> _decodeObject(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : {};
    } on FormatException {
      return {};
    }
  }
}
