import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

class AuthProvider extends ChangeNotifier {
  final _api = ApiService();

  bool _isAuthenticated = false;
  bool _isLoading = true;
  String? _error;

  bool get isAuthenticated => _isAuthenticated;
  bool get isLoading => _isLoading;
  String? get error => _error;

  AuthProvider() {
    // Wire the force-logout callback so the interceptor can trigger it.
    _api.onForceLogout = _handleForceLogout;
    _restoreSession();
  }

  /// Called by the Dio interceptor when the refresh token is expired/invalid.
  void _handleForceLogout() {
    _isAuthenticated = false;
    notifyListeners();
  }

  /// On startup, try to silently restore the session via the refresh token.
  /// This survives API restarts, token rotation, and app restarts.
  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final hasRefresh = prefs.getString('refresh_token') != null;

    if (hasRefresh) {
      final restored = await _api.tryRestoreSession();
      _isAuthenticated = restored;
    } else {
      _isAuthenticated = false;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> login(String username, String password) async {
    _error = null;
    try {
      final data = await _api.login(username, password);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('access_token', data['access'] as String);
      await prefs.setString('refresh_token', data['refresh'] as String);
      _isAuthenticated = true;
      notifyListeners();
      return true;
    } catch (_) {
      _error = 'Invalid credentials. Please try again.';
      notifyListeners();
      return false;
    }
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    final refreshToken = prefs.getString('refresh_token');
    // Blacklist the refresh token server-side (best-effort — ignore errors).
    if (refreshToken != null) {
      try {
        await _api.logout(refreshToken);
      } catch (_) {}
    }
    await prefs.remove('access_token');
    await prefs.remove('refresh_token');
    _isAuthenticated = false;
    notifyListeners();
  }
}
