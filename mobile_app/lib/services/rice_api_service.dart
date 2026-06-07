import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../config/api_config.dart';
import '../models/prediction_result.dart';

class RiceApiService {
  static const Duration _timeout = Duration(seconds: 20);

  Future<PredictionResult> predictRiceGrade(XFile imageFile) async {
    Object? lastError;

    for (final baseUrl in ApiConfig.baseUrls) {
      try {
        final uri = Uri.parse('$baseUrl/predict');
        final request = http.MultipartRequest('POST', uri);
        final bytes = await imageFile.readAsBytes();

        request.files.add(
          http.MultipartFile.fromBytes('file', bytes, filename: imageFile.name),
        );

        final streamedResponse = await request.send().timeout(_timeout);
        final response = await http.Response.fromStream(streamedResponse);
        final data = _decodeJsonObject(response.body);

        if (response.statusCode != 200) {
          return PredictionResult(
            predictedGrade: 'Prediction Failed',
            confidence: 0,
            error:
                data['detail']?.toString() ??
                data['error']?.toString() ??
                'Server error (${response.statusCode})',
          );
        }

        return PredictionResult.fromJson(data);
      } catch (error) {
        lastError = error;
      }
    }

    return PredictionResult(
      predictedGrade: 'Prediction Failed',
      confidence: 0,
      error:
          'Could not connect to the prediction server. Last error: $lastError',
    );
  }

  Future<Map<String, dynamic>> getMetrics() async {
    for (final baseUrl in ApiConfig.baseUrls) {
      try {
        final uri = Uri.parse('$baseUrl/metrics');
        final response = await http.get(uri).timeout(_timeout);

        if (response.statusCode == 200) {
          return _decodeJsonObject(response.body);
        }
      } catch (_) {
        continue;
      }
    }

    return {};
  }

  Future<bool> checkBackendStatus() async {
    for (final baseUrl in ApiConfig.baseUrls) {
      try {
        final uri = Uri.parse(baseUrl);
        final response = await http
            .get(uri)
            .timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          return true;
        }
      } catch (_) {
        continue;
      }
    }

    return false;
  }

  Map<String, dynamic> _decodeJsonObject(String body) {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return {};
  }
}
