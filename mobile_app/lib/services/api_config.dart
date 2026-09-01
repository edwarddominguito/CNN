import 'package:flutter/foundation.dart';

/// The only place the backend address is written down.
class ApiConfig {
  static const _localhost = [
    'http://127.0.0.1:8000',
    'http://localhost:8000',
  ];

  /// The app tries these addresses in order until one of them answers.
  ///
  /// An Android emulator cannot see "localhost" on your computer, it reaches
  /// the host machine through 10.0.2.2 instead. To run the app on a real phone
  /// on the same Wi-Fi, put your computer's IPv4 address first, for example:
  /// 'http://192.168.1.10:8000'.
  static List<String> get baseUrls {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return ['http://10.0.2.2:8000', ..._localhost];
    }
    return _localhost;
  }
}
