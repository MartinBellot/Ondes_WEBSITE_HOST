import 'package:flutter/foundation.dart';
import '../services/api_service.dart';

class GitHubProvider extends ChangeNotifier {
  final _api = ApiService();

  String? _githubLogin;
  List<dynamic> _repos = [];
  List<String> _branches = [];
  bool _isLoadingRepos = false;
  bool _isLoadingBranches = false;
  String? _error;

  String? get githubLogin => _githubLogin;
  List<dynamic> get repos => _repos;
  List<String> get branches => _branches;
  bool get isLoadingRepos => _isLoadingRepos;
  bool get isLoadingBranches => _isLoadingBranches;
  String? get error => _error;
  bool get isConnected => _githubLogin != null;

  /// Validates a PAT and fetches the authenticated user
  Future<bool> connect(String token) async {
    _error = null;
    try {
      final user = await _api.githubVerifyToken(token);
      _githubLogin = user['login'] as String;
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Invalid token or GitHub unreachable.';
      notifyListeners();
      return false;
    }
  }

  void disconnect() {
    _githubLogin = null;
    _repos = [];
    _branches = [];
    notifyListeners();
  }

  Future<void> fetchRepos(String token) async {
    _isLoadingRepos = true;
    _error = null;
    notifyListeners();
    try {
      _repos = await _api.githubListRepos(token);
    } catch (e) {
      _error = e.toString();
    }
    _isLoadingRepos = false;
    notifyListeners();
  }

  Future<void> fetchBranches(String token, String repo) async {
    _isLoadingBranches = true;
    _branches = [];
    notifyListeners();
    try {
      _branches = await _api.githubListBranches(token, repo);
    } catch (e) {
      _error = e.toString();
    }
    _isLoadingBranches = false;
    notifyListeners();
  }
}
