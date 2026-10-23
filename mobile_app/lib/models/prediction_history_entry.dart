import 'prediction_result.dart';

/// One row of the History screen.
class PredictionHistoryEntry {
  /// The backend's row id, or null for an entry only this device holds.
  final int? id;
  final String predictedGrade;
  final double confidence;
  final DateTime createdAt;

  /// The file name of this prediction's photo in the app's private History
  /// folder (see RiceApiService.photoFile), or null when no photo was kept.
  final String? imagePath;
  final String? note;
  final String? error;

  const PredictionHistoryEntry({
    this.id,
    required this.predictedGrade,
    required this.confidence,
    required this.createdAt,
    this.imagePath,
    this.note,
    this.error,
  });

  factory PredictionHistoryEntry.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    return PredictionHistoryEntry(
      id: id is int ? id : null,
      predictedGrade: toStringOrNull(json['predictedGrade']) ?? 'Unknown',
      confidence: toDoubleOrNull(json['confidence']) ?? 0,
      createdAt: DateTime.tryParse(toStringOrNull(json['createdAt']) ?? '') ?? DateTime.now(),
      imagePath: toStringOrNull(json['imagePath']),
      note: toStringOrNull(json['note']),
      error: toStringOrNull(json['error']),
    );
  }

  /// This entry with [imagePath] as its photo.
  PredictionHistoryEntry withImagePath(String? imagePath) {
    return PredictionHistoryEntry(
      id: id,
      predictedGrade: predictedGrade,
      confidence: confidence,
      createdAt: createdAt,
      imagePath: imagePath,
      note: note,
      error: error,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      // Only rows the backend saved have one; uploads never send it.
      if (id != null) 'id': id,
      'predictedGrade': predictedGrade,
      'confidence': confidence,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'imagePath': imagePath,
      'note': note,
      'error': error,
    };
  }
}
