import 'prediction_result.dart';

/// One row of the History screen.
class PredictionHistoryEntry {
  final String predictedGrade;
  final double confidence;
  final DateTime createdAt;
  final String? imagePath;
  final String? note;
  final String? error;

  const PredictionHistoryEntry({
    required this.predictedGrade,
    required this.confidence,
    required this.createdAt,
    this.imagePath,
    this.note,
    this.error,
  });

  factory PredictionHistoryEntry.fromJson(Map<String, dynamic> json) {
    return PredictionHistoryEntry(
      predictedGrade: toStringOrNull(json['predictedGrade']) ?? 'Unknown',
      confidence: toDoubleOrNull(json['confidence']) ?? 0,
      createdAt: DateTime.tryParse(toStringOrNull(json['createdAt']) ?? '') ?? DateTime.now(),
      imagePath: toStringOrNull(json['imagePath']),
      note: toStringOrNull(json['note']),
      error: toStringOrNull(json['error']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'predictedGrade': predictedGrade,
      'confidence': confidence,
      'createdAt': createdAt.toIso8601String(),
      'imagePath': imagePath,
      'note': note,
      'error': error,
    };
  }
}
