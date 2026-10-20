import 'package:flutter/foundation.dart';

/// Use --dart-define=API_BASE_URL=https://your-backend.up.railway.app
/// for release builds. Debug builds keep the local emulator defaults.
class ApiConfig {
  static const _configuredUrl = String.fromEnvironment('API_BASE_URL');
  static const _localhost = [
    'http://127.0.0.1:8000',
    'http://localhost:8000',
  ];

  static List<String> get baseUrls => resolveBaseUrls();

  static String? get configurationError => baseUrls.isEmpty
      ? 'The app is not connected to its server. Please contact the app administrator.'
      : null;

  @visibleForTesting
  static List<String> resolveBaseUrls({
    String configuredUrl = _configuredUrl,
    bool isRelease = kReleaseMode,
    bool isWeb = kIsWeb,
    TargetPlatform? platform,
  }) {
    final value = configuredUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    if (value.isNotEmpty) {
      final uri = Uri.tryParse(value);
      if (uri == null || !uri.hasAuthority || uri.host.isEmpty ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment ||
          (isRelease && uri.scheme != 'https')) {
        return [];
      }
      return [value];
    }
    if (isRelease) return [];
    if (!isWeb && (platform ?? defaultTargetPlatform) == TargetPlatform.android) {
      return ['http://10.0.2.2:8000', ..._localhost];
    }
    return _localhost;
  }
}
