import 'package:flutter/foundation.dart';

/// All builds use Railway unless API_BASE_URL explicitly overrides it.
class ApiConfig {
  static const _configuredUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://cnn-production-c269.up.railway.app',
  );

  static List<String> get baseUrls => resolveBaseUrls();

  static String? get configurationError => baseUrls.isEmpty
      ? 'The app is not connected to its server. Please contact the app administrator.'
      : null;

  @visibleForTesting
  static List<String> resolveBaseUrls({
    String configuredUrl = _configuredUrl,
    bool isRelease = kReleaseMode,
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
    return [];
  }
}
