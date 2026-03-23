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
    _checkPersistedToken();
  }

  Future<void> _checkPersistedToken() async {
    final prefs = await SharedPreferences.getInstance();
    _isAuthenticated = prefs.getString('access_token') != null;
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
    await prefs.remove('access_token');
    await prefs.remove('refresh_token');
    _isAuthenticated = false;
    notifyListeners();
  }
}
