class PredictionResult {
  final String predictedGrade;
  final double confidence;
  final double? processingTimeMs;
  final String? note;
  final String? error;

  const PredictionResult({
    required this.predictedGrade,
    required this.confidence,
    this.processingTimeMs,
    this.note,
    this.error,
  });

  factory PredictionResult.fromJson(Map<String, dynamic> json) {
    return PredictionResult(
      predictedGrade: json['predicted_grade'] as String? ?? 'Unknown',
      confidence: _toDouble(json['confidence']) ?? 0.0,
      processingTimeMs: _toDouble(json['processing_time_ms']),
      note: json['note'] as String?,
      error: json['error'] as String?,
    );
  }

  static double? _toDouble(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}
