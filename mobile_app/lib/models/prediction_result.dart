/// Shared JSON coercion: the backend may send a number or a numeric string.
double? toDoubleOrNull(Object? value) {
  final parsed = value is num ? value.toDouble() : value is String ? double.tryParse(value) : null;
  return parsed != null && parsed.isFinite ? parsed : null;
}

/// Shared JSON coercion: anything that is not a filled-in string is treated as
/// missing, so a wrong type in the response cannot throw a cast error.
String? toStringOrNull(Object? value) {
  if (value is String && value.trim().isNotEmpty) return value;
  return null;
}

/// One answer from POST /predict.
///
/// [confidence] arrives from the backend already scaled to 0-100, so the app
/// never multiplies it again.
class PredictionResult {
  final String predictedGrade;
  final double confidence;
  final String? note;
  final String? error;

  /// Whether the backend recorded this answer. A temporary database outage
  /// can leave a valid prediction unsaved, so the app keeps those locally too.
  final bool savedByBackend;

  const PredictionResult({
    required this.predictedGrade,
    required this.confidence,
    this.note,
    this.error,
    this.savedByBackend = false,
  });

  factory PredictionResult.fromJson(Map<String, dynamic> json) {
    return PredictionResult(
      predictedGrade: toStringOrNull(json['predicted_grade']) ?? 'Unknown',
      confidence: toDoubleOrNull(json['confidence']) ?? 0,
      note: toStringOrNull(json['note']),
      error: toStringOrNull(json['error']),
      savedByBackend: json['history_saved'] != false,
    );
  }
}
