import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import '../models/prediction_history_entry.dart';

class HistoryService {
  static const String _storageKey = 'prediction_history';
  static const int _maxEntries = 25;
  static const Duration _timeout = Duration(seconds: 5);

  Future<List<PredictionHistoryEntry>> getEntries() async {
    for (final baseUrl in ApiConfig.baseUrls) {
      try {
        final uri = Uri.parse('$baseUrl/history?limit=$_maxEntries');
        final response = await http.get(uri).timeout(_timeout);

        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body);
          if (decoded is List) {
            return decoded
                .whereType<Map<String, dynamic>>()
                .map(PredictionHistoryEntry.fromJson)
                .toList();
          }
        }
      } catch (_) {
        continue;
      }
    }

    return _getLocalEntries();
  }

  Future<void> addEntry(PredictionHistoryEntry entry) async {
    // Successful predictions are saved by the backend /predict endpoint.
    if (entry.error == null) return;

    for (final baseUrl in ApiConfig.baseUrls) {
      try {
        final uri = Uri.parse('$baseUrl/history');
        final response = await http
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(entry.toJson()),
            )
            .timeout(_timeout);

        if (response.statusCode >= 200 && response.statusCode < 300) {
          return;
        }
      } catch (_) {
        continue;
      }
    }

    await _addLocalEntry(entry);
  }

  Future<void> clear() async {
    for (final baseUrl in ApiConfig.baseUrls) {
      try {
        final uri = Uri.parse('$baseUrl/history');
        final response = await http.delete(uri).timeout(_timeout);

        if (response.statusCode >= 200 && response.statusCode < 300) {
          break;
        }
      } catch (_) {
        continue;
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  }

  Future<List<PredictionHistoryEntry>> _getLocalEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final rawEntries = prefs.getStringList(_storageKey) ?? [];

    return rawEntries
        .map((entry) => PredictionHistoryEntry.fromJson(jsonDecode(entry)))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> _addLocalEntry(PredictionHistoryEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = await _getLocalEntries();
    final updatedEntries = [entry, ...entries].take(_maxEntries).toList();

    await prefs.setStringList(
      _storageKey,
      updatedEntries.map((entry) => jsonEncode(entry.toJson())).toList(),
    );
  }
}
