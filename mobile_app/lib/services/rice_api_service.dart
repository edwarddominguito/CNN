import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/prediction_history_entry.dart';
import '../models/prediction_result.dart';
import 'api_config.dart';

/// Everything the app sends to, or reads from, the FastAPI backend.
///
/// If the backend cannot be reached, the history is kept in a small copy on
/// the phone so the History screen still has something to show. The photo of
/// each successful scan is kept the same way, in the app's private folder;
/// the backend never keeps photos.
///
/// No method here throws. A screen that called one of these can always show
/// its answer and stop its spinner, whatever went wrong underneath.
class RiceApiService {
  final http.Client Function() _clientFactory;
  final List<String>? _baseUrls;
  final Future<Directory?> Function() _photoFolder;
  final Duration _uploadTimeout;
  final Duration _quickTimeout;

  RiceApiService({
    http.Client Function()? clientFactory,
    List<String>? baseUrls,
    Future<Directory?> Function()? photoFolder,
    Duration uploadTimeout = const Duration(seconds: 120),
    Duration quickTimeout = const Duration(seconds: 5),
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _baseUrls = baseUrls,
       _photoFolder = photoFolder ?? _appPhotoFolder,
       _uploadTimeout = uploadTimeout,
       _quickTimeout = quickTimeout;

  static const _historyKey = 'prediction_history';
  static const _unsavedHistoryKey = 'unsaved_prediction_history';
  // Backend row id -> name of its photo, for the rows /predict saves itself.
  static const _photoLinksKey = 'history_photo_links';
  static const _clientIdKey = 'history_client_id';
  static const _historyLimit = 25;
  // Screens use separate service instances but share the same local store.
  static Completer<void>? _historyOperation;
  // The backend shows each installation only the history saved with its random
  // ID. One shared load means screens racing on first launch cannot pick two.
  static String? _clientId;
  static Future<String>? _clientIdLoad;
  static final _validClientId = RegExp(r'^[A-Za-z0-9_-]{32,128}$');

  @visibleForTesting
  static void forgetClientId() {
    _clientId = null;
    _clientIdLoad = null;
  }

  Future<Map<String, String>> _clientHeaders() async {
    final id = _clientId ??= await (_clientIdLoad ??= _loadClientId());
    return {'X-Client-Id': id};
  }

  static Future<String> _loadClientId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_clientIdKey);
      if (saved != null && _validClientId.hasMatch(saved)) return saved;
      final created = _newClientId();
      await prefs.setString(_clientIdKey, created);
      return created;
    } catch (_) {
      // Without device storage, history is still private for this session.
      return _newClientId();
    }
  }

  static String _newClientId() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 16; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// The app's private folder for History photos. A browser gives a web app no
  /// private files, so the web keeps none.
  static Future<Directory?> _appPhotoFolder() async {
    if (kIsWeb) return null;
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/history_photos');
  }

  /// Where this device keeps History photos, or null when it keeps none.
  Future<Directory?> photoFolder() async {
    try {
      return await _photoFolder();
    } catch (_) {
      return null; // History still works, with placeholders instead of photos.
    }
  }

  /// The History photo called [name] in [folder]. Only a plain file name is
  /// accepted, so a stored value can never point outside the folder.
  static File? photoFile(Directory? folder, String? name) {
    if (folder == null || name == null || name.contains(RegExp(r'[/\\]'))) return null;
    return File('${folder.path}/$name');
  }

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
      request.headers.addAll(await _clientHeaders());
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
    final remoteEntries = await _fetchHistory();
    if (remoteEntries == null) return _readLocalHistory();

    // Rows saved by /predict carry no photo; this device's own are added here.
    final photos = await _readPhotoLinks();
    final entries = [
      for (final entry in remoteEntries) entry.withImagePath(entry.imagePath ?? photos[entry.id]),
      ...await _readLocalHistory(key: _unsavedHistoryKey),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    await _writeLocalHistory(entries);
    return entries.take(_historyLimit).toList();
  });

  /// Files a finished scan in History. A successful prediction also keeps a
  /// private copy of [photo] for the History screen; a failure keeps none.
  Future<void> addToHistory(PredictionResult result, Uint8List photo) => _withHistoryLock(() async {
    final photoName = result.error == null ? await _savePhoto(photo) : null;
    if (!result.savedByBackend) {
      // A failure, or a prediction a database outage left unsaved.
      await _saveUnsaved(PredictionHistoryEntry(
        predictedGrade: result.predictedGrade,
        confidence: result.confidence,
        createdAt: DateTime.now(),
        imagePath: photoName,
        note: result.note,
        error: result.error,
      ));
    } else {
      if (result.historyId != null) {
        // Keep the exact saved row immediately. A connection lost after the
        // prediction reply must not hide the result or discard its photo.
        final previous = await _readLocalHistory();
        await _writeLocalHistory([
          PredictionHistoryEntry(
            id: result.historyId,
            predictedGrade: result.predictedGrade,
            confidence: result.confidence,
            createdAt: DateTime.now(),
            imagePath: photoName,
            note: result.note,
            error: result.error,
          ),
          ...previous.where((entry) => entry.id != result.historyId),
        ]);
      }
      if (photoName != null) await _linkPhoto(result, photoName);
    }
    // Removes a photo that could not be linked to its row, and the photos of
    // rows that have dropped out of History.
    await _deleteUnusedPhotos();
  });

  Future<void> _saveUnsaved(PredictionHistoryEntry entry) async {
    final saved = await _tryEachHost<Map<String, dynamic>>((baseUrl, client) async {
      final response = await client
          .post(
            Uri.parse('$baseUrl/history'),
            headers: {'Content-Type': 'application/json', ...await _clientHeaders()},
            body: jsonEncode(entry.toJson()),
          )
          .timeout(_quickTimeout);
      return response.statusCode == 200 ? _decodeObject(response.body) : null;
    });

    var cached = entry;
    if (saved == null) {
      final unsaved = [entry, ...await _readLocalHistory(key: _unsavedHistoryKey)];
      await _writeLocalHistory(unsaved, key: _unsavedHistoryKey);
    } else {
      final rowId = saved['id'];
      if (rowId is int && rowId > 0) {
        cached = PredictionHistoryEntry.fromJson({...entry.toJson(), 'id': rowId});
        if (entry.imagePath != null) await _storePhotoLink(rowId, entry.imagePath!);
      }
    }
    await _writeLocalHistory([cached, ...await _readLocalHistory()]);
  }

  /// Failed server deletion must preserve the local copies for a later retry.
  Future<bool> clearHistory() => _withHistoryLock(() async {
    final cleared = await _tryEachHost<bool>((baseUrl, client) async {
      final response = await client
          .delete(Uri.parse('$baseUrl/history'), headers: await _clientHeaders())
          .timeout(_quickTimeout);
      return response.statusCode == 200 ? true : null;
    });

    if (cleared != true) return false;
    await _writeLocalHistory([]);
    await _writeLocalHistory([], key: _unsavedHistoryKey);
    await _writePhotoLinks({});
    await _deleteUnusedPhotos(); // Nothing refers to any photo any more.
    return true;
  });

  /// This installation's newest rows on the backend, or null when it cannot
  /// be reached.
  Future<List<PredictionHistoryEntry>?> _fetchHistory() {
    return _tryEachHost<List<PredictionHistoryEntry>>((baseUrl, client) async {
      final response = await client
          .get(Uri.parse('$baseUrl/history?limit=$_historyLimit'), headers: await _clientHeaders())
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
  }

  /// Copies a classified photo into the photo folder. Returns the copy's name,
  /// or null when this device keeps no photos or the copy failed.
  Future<String?> _savePhoto(Uint8List photo) async {
    final folder = await photoFolder();
    if (folder == null) return null;
    // Named after the moment it was kept, so no two photos share a name.
    final name = '${DateTime.now().microsecondsSinceEpoch}';
    try {
      await folder.create(recursive: true);
      await photoFile(folder, name)!.writeAsBytes(photo, flush: true);
      return name;
    } catch (error) {
      debugPrint('Could not keep the photo for History: $error');
      return null;
    }
  }

  /// Ties [photoName] to the row /predict just saved for [result]. The reply
  /// identifies its own row. Older servers need a unique grade/confidence
  /// match; ambiguous matches cannot safely identify which photo belongs where.
  Future<void> _linkPhoto(PredictionResult result, String photoName) async {
    var rowId = result.historyId;
    if (rowId == null) {
      final links = await _readPhotoLinks();
      final rows = await _fetchHistory();
      final matches = rows?.where((row) =>
          row.id != null && row.error == null && row.imagePath == null &&
          !links.containsKey(row.id) &&
          row.predictedGrade == result.predictedGrade &&
          row.confidence == result.confidence).take(2).toList();
      if (matches == null || matches.length != 1) return;
      rowId = matches.single.id!;
    }
    await _storePhotoLink(rowId, photoName);
  }

  Future<void> _storePhotoLink(int rowId, String photoName) async {
    final links = await _readPhotoLinks();
    links[rowId] = photoName;
    // History lists at most _historyLimit rows, so older links are never shown.
    final newestFirst = links.keys.toList()..sort((a, b) => b.compareTo(a));
    await _writePhotoLinks({for (final id in newestFirst.take(_historyLimit)) id: links[id]!});
  }

  /// Deletes kept photos that no saved History record refers to any more: those
  /// of cleared or aged-out rows, and any copy that could not be linked.
  Future<void> _deleteUnusedPhotos() async {
    final folder = await photoFolder();
    if (folder == null) return;
    try {
      if (!await folder.exists()) return;
      final records = [
        ...await _readLocalHistory(),
        ...await _readLocalHistory(key: _unsavedHistoryKey),
      ];
      final inUse = {
        ...(await _readPhotoLinks()).values,
        for (final record in records)
          if (record.imagePath != null) record.imagePath!,
      };
      await for (final item in folder.list()) {
        if (item is File && !inUse.contains(item.uri.pathSegments.last)) {
          await item.delete();
        }
      }
    } catch (error) {
      debugPrint('Could not tidy the History photos: $error');
    }
  }

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

  /// Which backend rows have a photo on this device: row id -> photo name.
  Future<Map<int, String>> _readPhotoLinks() async {
    final links = <int, String>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString(_photoLinksKey) ?? '{}');
      if (saved is Map) {
        saved.forEach((id, name) {
          final rowId = int.tryParse('$id');
          if (rowId != null && name is String) links[rowId] = name;
        });
      }
    } catch (_) {
      // Unreadable links only cost thumbnails, never the History list itself.
    }
    return links;
  }

  /// Best effort, like [_writeLocalHistory]: a lost link only costs a thumbnail.
  Future<void> _writePhotoLinks(Map<int, String> links) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_photoLinksKey, jsonEncode(links.map((id, name) => MapEntry('$id', name))));
    } catch (error) {
      debugPrint('Could not save the History photo links: $error');
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
