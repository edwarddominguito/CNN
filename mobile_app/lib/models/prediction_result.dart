/// Shared JSON coercion: the backend may send a number or a numeric string.
double? toDoubleOrNull(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

/// Shared JSON coercion: anything that is not a filled-in string is treated as
/// missing, so a wrong type in the response cannot throw a cast error.
String? toStringOrNull(Object? value) {
  if (value is String && value.isNotEmpty) return value;
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

  /// True when this came back from the server, which records every answer it
  /// gives in its own history. Failures the app produced on its own (no
  /// connection, rejected upload) never reached that history and still have to
  /// be saved by the app.
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
      savedByBackend: true,
    );
  }
}
