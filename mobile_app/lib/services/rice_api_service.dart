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
  static const _uploadTimeout = Duration(seconds: 20);
  static const _quickTimeout = Duration(seconds: 5);

  static const _historyKey = 'prediction_history';
  static const _historyLimit = 25;

  /// Uploads the picked image to POST /predict and returns the model's answer.
  ///
  /// The screen has already read the file for its preview, so it passes the
  /// bytes in rather than making this read the same file a second time.
  Future<PredictionResult> predictRiceGrade(String fileName, Uint8List bytes) async {
    final result = await _tryEachHost<PredictionResult>((baseUrl) async {
      final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/predict'));
      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: fileName),
      );

      final streamed = await request.send().timeout(_uploadTimeout);
      final response = await http.Response.fromStream(streamed);
      final data = _decodeObject(response.body);

      if (response.statusCode != 200) {
        final message = data['detail'] ?? data['error'];
        return _failed(message?.toString() ?? 'Server error (${response.statusCode})');
      }

      // A 200 with no grade in it is not a prediction. Showing "Unknown 0%"
      // as if the model had answered would be inventing a result.
      if (data['predicted_grade'] == null && data['error'] == null) {
        return _failed('The server sent a reply this app could not read.');
      }

      return PredictionResult.fromJson(data);
    });

    return result ??
        _failed('Could not reach the server. Please check your connection and try again.');
  }

  /// The backend's history when it is reachable, otherwise the phone's copy.
  Future<List<PredictionHistoryEntry>> getHistory() async {
    final entries = await _tryEachHost<List<PredictionHistoryEntry>>((baseUrl) async {
      final response = await http
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

    return entries ?? await _readLocalHistory();
  }

  /// The backend records every answer it sends, so this is only for failures
  /// that never reached it. See [PredictionResult.savedByBackend].
  Future<void> saveFailedPrediction(PredictionHistoryEntry entry) async {
    final saved = await _tryEachHost<bool>((baseUrl) async {
      final response = await http
          .post(
            Uri.parse('$baseUrl/history'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(entry.toJson()),
          )
          .timeout(_quickTimeout);
      return response.statusCode == 200 ? true : null;
    });

    if (saved == null) {
      final entries = [entry, ...await _readLocalHistory()].take(_historyLimit).toList();
      await _writeLocalHistory(entries);
    }
  }

  Future<void> clearHistory() async {
    await _tryEachHost<bool>((baseUrl) async {
      final response = await http.delete(Uri.parse('$baseUrl/history')).timeout(_quickTimeout);
      return response.statusCode == 200 ? true : null;
    });

    await _writeLocalHistory([]);
  }

  /// Runs [sendRequest] against each address from [ApiConfig] until one of them
  /// gives an answer. Returns null when none of them work.
  Future<T?> _tryEachHost<T>(Future<T?> Function(String baseUrl) sendRequest) async {
    for (final baseUrl in ApiConfig.baseUrls) {
      try {
        final result = await sendRequest(baseUrl);
        if (result != null) {
          return result;
        }
      } catch (_) {
        continue; // This address did not work, try the next one.
      }
    }
    return null;
  }

  Future<List<PredictionHistoryEntry>> _readLocalHistory() async {
    List<String> rows;
    try {
      final prefs = await SharedPreferences.getInstance();
      rows = prefs.getStringList(_historyKey) ?? [];
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
  Future<void> _writeLocalHistory(List<PredictionHistoryEntry> entries) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _historyKey,
        entries.map((entry) => jsonEncode(entry.toJson())).toList(),
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
