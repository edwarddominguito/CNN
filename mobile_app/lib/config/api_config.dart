import 'package:flutter/foundation.dart';

class ApiConfig {
  static String get baseUrl {
    return baseUrls.first;
  }

  static List<String> get baseUrls {
    if (kIsWeb ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      return const ['http://127.0.0.1:8000', 'http://localhost:8000'];
    }

    // Android emulator uses 10.0.2.2 to access your laptop localhost.
    return const [
      'http://10.0.2.2:8000',
      'http://127.0.0.1:8000',
      'http://localhost:8000',
    ];
  }

  // For real phone, replace with your laptop IPv4 address:
  // static const String baseUrl = 'http://192.168.1.10:8000';
}
