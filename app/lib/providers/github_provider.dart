import 'package:flutter/foundation.dart';
import '../services/api_service.dart';

class GitHubProvider extends ChangeNotifier {
  final _api = ApiService();

  // ── Profile ──────────────────────────────────────────────────────────────
  bool _connected = false;
  String? _login;
  String? _name;
  String? _avatarUrl;
  bool _isProfileLoading = false;

  bool get connected => _connected;
  String? get login => _login;
  String? get name => _name;
  String? get avatarUrl => _avatarUrl;
  bool get isProfileLoading => _isProfileLoading;

  // ── OAuth App config ─────────────────────────────────────────────────────
  bool _oauthConfigured = false;
  String? _callbackUrl;
  String? _clientId;
  String? _clientIdHint;
  bool _isConfigLoading = false;
  bool _isConfigSaving = false;

  bool get oauthConfigured => _oauthConfigured;
  String? get callbackUrl => _callbackUrl;
  String? get clientId => _clientId;
  String? get clientIdHint => _clientIdHint;
  bool get isConfigLoading => _isConfigLoading;
  bool get isConfigSaving => _isConfigSaving;

  // ── OAuth runtime ────────────────────────────────────────────────────────
  String? _authUrl;
  String? get authUrl => _authUrl;

  // ── Repos ────────────────────────────────────────────────────────────────
  List<dynamic> _repos = [];
  bool _isLoadingRepos = false;
  /// True once the first fetch attempt has been made (success or failure).
  /// Prevents the auto-trigger listener from looping on repeated failures.
  bool _reposInitialized = false;

  List<dynamic> get repos => _repos;
  bool get isLoadingRepos => _isLoadingRepos;
  bool get reposInitialized => _reposInitialized;

  // ── Branches + compose ──────────────────────────────────────────────────
  List<String> _branches = [];
  bool _isLoadingBranches = false;
  List<String> _composeFiles = [];
  Map<String, String> _envTemplate = {};
  bool _isLoadingCompose = false;

  List<String> get branches => _branches;
  bool get isLoadingBranches => _isLoadingBranches;
  List<String> get composeFiles => _composeFiles;
  Map<String, String> get envTemplate => _envTemplate;
  bool get isLoadingCompose => _isLoadingCompose;

  // ── Error ────────────────────────────────────────────────────────────────
  String? _error;
  String? get error => _error;

  // ─────────────────────────────────────────────────────────────────────────

  /// Load OAuth App config (called on screen open to show wizard or connect button).
  Future<void> loadConfig() async {
    _isConfigLoading = true;
    notifyListeners();
    try {
      final data = await _api.githubGetConfig();
      _oauthConfigured = data['configured'] as bool? ?? false;
      _callbackUrl = data['callback_url'] as String?;
      if (_oauthConfigured) {
        _clientId = data['client_id'] as String?;
        _clientIdHint = null;
      }
    } catch (_) {}
    _isConfigLoading = false;
    notifyListeners();
  }

  /// Save new OAuth App credentials. Returns null on success, error string on failure.
  Future<String?> saveConfig(String clientId, String clientSecret) async {
    _isConfigSaving = true;
    notifyListeners();
    try {
      final data = await _api.githubSaveConfig(clientId, clientSecret);
      _oauthConfigured = data['configured'] as bool? ?? true;
      _clientId = data['client_id'] as String?;
    } catch (e) {
      _isConfigSaving = false;
      notifyListeners();
      return e.toString();
    }
    _isConfigSaving = false;
    notifyListeners();
    return null;
  }

  Future<void> deleteConfig() async {
    try {
      await _api.githubDeleteConfig();
    } catch (_) {}
    _oauthConfigured = false;
    _clientId = null;
    _authUrl = null;
    notifyListeners();
  }

  /// Load profile on app start (called from MainShell).
  Future<void> loadProfile() async {
    _isProfileLoading = true;
    notifyListeners();
    try {
      final data = await _api.githubProfile();
      _applyProfile(data);
    } catch (_) {}
    _isProfileLoading = false;
    notifyListeners();
  }

  void _applyProfile(Map<String, dynamic> data) {
    _connected = data['connected'] as bool? ?? false;
    if (_connected) {
      _login = data['login'] as String?;
      _name = data['name'] as String?;
      _avatarUrl = data['avatar_url'] as String?;
    }
  }

  /// Request the OAuth authorize URL from backend (requires config to be saved first).
  Future<Map<String, dynamic>> requestAuthUrl() async {
    _error = null;
    final data = await _api.githubOAuthStart();
    _oauthConfigured = data['configured'] as bool? ?? false;
    if (_oauthConfigured) {
      _authUrl = data['auth_url'] as String?;
    } else {
      _callbackUrl = data['callback_url'] as String?;
    }
    notifyListeners();
    return data;
  }

  /// Step 2: called after the OAuth popup closes successfully.
  Future<void> onOAuthSuccess() async {
    await loadProfile();
    if (_connected) await fetchRepos();
  }

  Future<void> disconnect() async {
    try {
      await _api.githubDisconnect();
    } catch (_) {}
    _connected = false;
    _login = null;
    _name = null;
    _avatarUrl = null;
    _repos = [];
    _reposInitialized = false;
    _branches = [];
    _composeFiles = [];
    _envTemplate = {};
    notifyListeners();
  }

  Future<void> fetchRepos() async {
    _reposInitialized = true;
    _isLoadingRepos = true;
    _error = null;
    notifyListeners();
    try {
      _repos = await _api.githubListRepos();
    } catch (e) {
      _error = e.toString();
      // Reset the flag so that a subsequent successful login can auto-trigger
      // a fresh fetch (e.g. after a forced logout caused by expired tokens).
      _reposInitialized = false;
    }
    _isLoadingRepos = false;
    notifyListeners();
  }

  Future<void> fetchBranches(String owner, String repo) async {
    _isLoadingBranches = true;
    _branches = [];
    _composeFiles = [];
    _envTemplate = {};
    notifyListeners();
    try {
      _branches = await _api.githubListBranches(owner, repo);
    } catch (e) {
      _error = e.toString();
    }
    _isLoadingBranches = false;
    notifyListeners();
  }

  Future<void> fetchComposeFiles(
      String owner, String repo, String branch) async {
    _isLoadingCompose = true;
    _composeFiles = [];
    _envTemplate = {};
    notifyListeners();
    try {
      final data = await _api.githubComposeFiles(owner, repo, branch);
      _composeFiles = (data['compose_files'] as List? ?? []).cast<String>();
      _envTemplate = Map<String, String>.from(
          (data['env_template'] as Map? ?? {})
              .map((k, v) => MapEntry(k.toString(), v.toString())));
    } catch (e) {
      _error = e.toString();
    }
    _isLoadingCompose = false;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
