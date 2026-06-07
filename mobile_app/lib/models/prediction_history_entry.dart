import 'prediction_result.dart';

class PredictionHistoryEntry {
  final String predictedGrade;
  final double confidence;
  final String? imagePath;
  final String? note;
  final String? error;
  final DateTime createdAt;

  const PredictionHistoryEntry({
    required this.predictedGrade,
    required this.confidence,
    required this.createdAt,
    this.imagePath,
    this.note,
    this.error,
  });

  factory PredictionHistoryEntry.fromPrediction({
    required PredictionResult result,
    required DateTime createdAt,
    String? imagePath,
  }) {
    return PredictionHistoryEntry(
      predictedGrade: result.predictedGrade,
      confidence: result.confidence,
      createdAt: createdAt,
      imagePath: imagePath,
      note: result.note,
      error: result.error,
    );
  }

  factory PredictionHistoryEntry.fromJson(Map<String, dynamic> json) {
    return PredictionHistoryEntry(
      predictedGrade: json['predictedGrade'] as String? ?? 'Unknown',
      confidence: _toDouble(json['confidence']) ?? 0,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      imagePath: json['imagePath'] as String?,
      note: json['note'] as String?,
      error: json['error'] as String?,
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

  static double? _toDouble(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}
