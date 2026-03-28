import 'package:shared_preferences/shared_preferences.dart';

/// Manages the Ondes HOST server base URL for mobile clients (iOS/Android).
/// On web/macOS the URL is derived from the page origin; on mobile the user
/// enters it once at first launch and it is persisted here.
class ServerConfig {
  static const _key = 'server_url';

  static String? _serverUrl;

  /// The stored server URL (without trailing slash), e.g. "https://host.example.com".
  /// Null means the user has not configured it yet.
  static String? get serverUrl => _serverUrl;

  /// Whether a server URL has been saved.
  static bool get isConfigured =>
      _serverUrl != null && _serverUrl!.isNotEmpty;

  /// Loads the persisted URL at app startup.
  /// Must be called (with await) in main() before runApp().
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_key);
    _serverUrl = (stored != null && stored.isNotEmpty) ? stored : null;
  }

  /// Persists [url] and updates the in-memory cache.
  /// Strips trailing slashes and normalises the scheme.
  static Future<void> setServerUrl(String url) async {
    var cleaned = url.trim();
    // Strip trailing slash
    while (cleaned.endsWith('/')) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    _serverUrl = cleaned;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, cleaned);
  }

  /// Clears the stored URL (e.g. when resetting the app).
  static Future<void> clear() async {
    _serverUrl = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
