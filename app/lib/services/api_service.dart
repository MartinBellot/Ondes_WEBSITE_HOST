import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/server_config.dart';

/// Centralised HTTP client.
/// URL resolution priority:
///   1. Mobile (iOS/Android): ServerConfig.serverUrl  → set by the user at first launch
///   2. --dart-define API_URL build flag
///   3. Current page origin + /api  (production web)
///   4. http://localhost:8000/api   (local dev fallback)
class ApiService {
  // ── Singleton ──────────────────────────────────────────────────────────────
  // A single shared instance ensures there is exactly ONE Dio client and ONE
  // refresh-token flow across the entire app.  This eliminates two races:
  //   1. Multiple ApiService instances all trying to refresh simultaneously
  //      (second attempt hits a blacklisted token → force-logout).
  //   2. Two concurrent 401s on the SAME instance both entering the refresh
  //      logic before _isRefreshing is set (check-then-act race).
  // The Completer-based _refreshTokenOnce() serialises all concurrent 401s so
  // exactly one network call is made and every waiting request gets the result.
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;

  static const _envUrl = String.fromEnvironment('API_URL');

  /// Returns the API base URL (public accessor for use across the app).
  static String get baseUrl => _baseUrl;

  /// Returns the API base URL.
  static String get _baseUrl {
    // Mobile: use the server URL configured by the user.
    if (!kIsWeb && ServerConfig.isConfigured) {
      return '${ServerConfig.serverUrl}/api';
    }
    if (_envUrl.isNotEmpty) return _envUrl;
    try {
      final origin = Uri.base.origin;
      if (origin.isNotEmpty &&
          !origin.contains('localhost') &&
          !origin.contains('127.0.0.1')) {
        return '$origin/api';
      }
    } catch (_) {}
    return 'http://localhost:8000/api';
  }

  late final Dio _dio;

  /// Called when a token refresh fails (e.g. refresh token expired/blacklisted).
  /// Wire this up to trigger a global logout in your AuthProvider.
  void Function()? onForceLogout;

  /// In-flight refresh completer.  Non-null while a refresh is running.
  /// Subsequent 401s await this future instead of starting a second refresh,
  /// preventing concurrent rotations that would blacklist the token.
  Completer<String?>? _refreshCompleter;

  ApiService._internal() {
    _dio = Dio(BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      headers: {'Content-Type': 'application/json'},
    ));

    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('access_token');
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
      onError: (DioException error, handler) async {
        final path = error.requestOptions.path;
        final alreadyRetried = error.requestOptions.extra['_retried'] == true;

        if (error.response?.statusCode == 401 &&
            !path.contains('/auth/refresh/') &&
            !path.contains('/auth/login/') &&
            !alreadyRetried) {
          // Serialise: if a refresh is already running, wait for its result.
          final newToken = await _refreshTokenOnce();
          if (newToken != null) {
            final opts = error.requestOptions;
            opts.headers['Authorization'] = 'Bearer $newToken';
            opts.extra['_retried'] = true;
            try {
              final retryResponse = await _dio.fetch(opts);
              return handler.resolve(retryResponse);
            } catch (_) {
              return handler.next(error);
            }
          }
          return handler.next(error);
        }
        handler.next(error);
      },
    ));
  }

  /// Refresh the access token exactly once even when called concurrently.
  ///
  /// Returns the new access token on success, or null on failure
  /// (in which case [onForceLogout] is called and tokens are cleared).
  Future<String?> _refreshTokenOnce() async {
    // Already in flight — join the existing attempt.
    if (_refreshCompleter != null) {
      return _refreshCompleter!.future;
    }

    _refreshCompleter = Completer<String?>();
    try {
      final prefs = await SharedPreferences.getInstance();
      final refreshToken = prefs.getString('refresh_token');
      if (refreshToken == null) {
        _refreshCompleter!.complete(null);
        _refreshCompleter = null;
        onForceLogout?.call();
        return null;
      }

      // Use a bare Dio to avoid re-triggering this interceptor.
      final refreshDio = Dio(BaseOptions(baseUrl: _baseUrl));
      final res = await refreshDio.post('/auth/refresh/', data: {
        'refresh': refreshToken,
      });

      final newAccess = res.data['access'] as String;
      final newRefresh = res.data['refresh'] as String?;

      await prefs.setString('access_token', newAccess);
      if (newRefresh != null) {
        await prefs.setString('refresh_token', newRefresh);
      }

      _refreshCompleter!.complete(newAccess);
      _refreshCompleter = null;
      return newAccess;
    } catch (_) {
      _refreshCompleter!.complete(null);
      _refreshCompleter = null;
      // Refresh failed — clear tokens and trigger logout.
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('access_token');
      await prefs.remove('refresh_token');
      onForceLogout?.call();
      return null;
    }
  }

  /// Refreshes the Dio base URL from [ServerConfig].
  /// Call this after the user saves a new server URL on first mobile launch.
  void reloadBaseUrl() {
    _dio.options.baseUrl = _baseUrl;
  }

  // ── Auth ────────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> login(String username, String password) async {
    final res = await _dio.post('/auth/login/', data: {
      'username': username,
      'password': password,
    });
    return res.data as Map<String, dynamic>;
  }

  Future<void> logout(String refreshToken) async {
    await _dio.post('/auth/logout/', data: {'refresh': refreshToken});
  }

  /// Tries to silently get a new access token using the stored refresh token.
  /// Returns true if session was successfully restored.
  Future<bool> tryRestoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final refreshToken = prefs.getString('refresh_token');
    if (refreshToken == null) return false;
    try {
      final refreshDio = Dio(BaseOptions(baseUrl: _baseUrl));
      final res = await refreshDio.post('/auth/refresh/', data: {
        'refresh': refreshToken,
      });
      await prefs.setString('access_token', res.data['access'] as String);
      final newRefresh = res.data['refresh'] as String?;
      if (newRefresh != null) {
        await prefs.setString('refresh_token', newRefresh);
      }
      return true;
    } catch (_) {
      await prefs.remove('access_token');
      await prefs.remove('refresh_token');
      return false;
    }
  }

  // ── Docker ──────────────────────────────────────────────────────────────────

  Future<List<dynamic>> listContainers() async {
    final res = await _dio.get('/docker/containers/');
    return res.data as List<dynamic>;
  }

  Future<Map<String, dynamic>> createContainer(
      Map<String, dynamic> data) async {
    final res = await _dio.post('/docker/containers/create/', data: data);
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> containerAction(
      String containerId, String action) async {
    final res = await _dio.post('/docker/containers/$containerId/$action/');
    return res.data as Map<String, dynamic>;
  }

  // ── NGINX ───────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> previewNginxConfig(
    String domain,
    int upstreamPort,
    bool ssl,
  ) async {
    final res = await _dio.post('/nginx/preview/', data: {
      'domain': domain,
      'upstream_port': upstreamPort,
      'ssl': ssl,
    });
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> applyNginxConfig(
    String domain,
    int upstreamPort,
    bool ssl,
  ) async {
    final res = await _dio.post('/nginx/configure/', data: {
      'domain': domain,
      'upstream_port': upstreamPort,
      'ssl': ssl,
    });
    return res.data as Map<String, dynamic>;
  }

  // ── Sites ────────────────────────────────────────────────────────────────────

  Future<List<dynamic>> listSites() async {
    final res = await _dio.get('/sites/');
    return res.data as List<dynamic>;
  }

  Future<Map<String, dynamic>> createSite(Map<String, dynamic> data) async {
    final res = await _dio.post('/sites/', data: data);
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateSite(
      int id, Map<String, dynamic> data) async {
    final res = await _dio.patch('/sites/$id/', data: data);
    return res.data as Map<String, dynamic>;
  }

  Future<void> deleteSite(int id) async {
    await _dio.delete('/sites/$id/');
  }

  Future<Map<String, dynamic>> deploySite(int id) async {
    final res = await _dio.post('/sites/$id/deploy/');
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> siteNginxPreview(int id) async {
    final res = await _dio.get('/sites/$id/nginx/preview/');
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> siteNginxApply(int id) async {
    final res = await _dio.post('/sites/$id/nginx/apply/');
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> siteCertbot(
      int id, String domain, String email) async {
    final res = await _dio.post('/sites/$id/certbot/', data: {
      'domain': domain,
      'email': email,
    });
    return res.data as Map<String, dynamic>;
  }

  // ── GitHub ───────────────────────────────────────────────────────────────────

  /// OAuth App config — GET, POST (save), DELETE
  Future<Map<String, dynamic>> githubGetConfig() async {
    final res = await _dio.get('/github/config/');
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> githubSaveConfig(
      String clientId, String clientSecret) async {
    final res = await _dio.post('/github/config/', data: {
      'client_id': clientId,
      'client_secret': clientSecret,
    });
    return res.data as Map<String, dynamic>;
  }

  Future<void> githubDeleteConfig() async {
    await _dio.delete('/github/config/');
  }

  /// Returns {configured: bool, auth_url?: String, callback_url?: String}
  Future<Map<String, dynamic>> githubOAuthStart() async {
    final res = await _dio.get('/github/oauth/start/');
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> githubProfile() async {
    final res = await _dio.get('/github/profile/');
    return res.data as Map<String, dynamic>;
  }

  Future<void> githubDisconnect() async {
    await _dio.delete('/github/profile/');
  }

  Future<List<dynamic>> githubListRepos({int page = 1}) async {
    final res = await _dio.get('/github/repos/', queryParameters: {'page': page});
    return res.data as List<dynamic>;
  }

  Future<List<String>> githubListBranches(String owner, String repo) async {
    final res = await _dio.get('/github/repos/$owner/$repo/branches/');
    return (res.data as List<dynamic>).cast<String>();
  }

  Future<Map<String, dynamic>> githubComposeFiles(
      String owner, String repo, String branch) async {
    final res = await _dio.get(
      '/github/repos/$owner/$repo/compose-files/',
      queryParameters: {'branch': branch},
    );
    return res.data as Map<String, dynamic>;
  }

  // ── Stacks ────────────────────────────────────────────────────────────────

  Future<List<dynamic>> listStacks() async {
    final res = await _dio.get('/stacks/');
    return res.data as List<dynamic>;
  }

  Future<Map<String, dynamic>> getStack(int id) async {
    final res = await _dio.get('/stacks/$id/');
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> createStack(Map<String, dynamic> data) async {
    final res = await _dio.post('/stacks/', data: data);
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateStack(int id, Map<String, dynamic> data) async {
    final res = await _dio.patch('/stacks/$id/', data: data);
    return res.data as Map<String, dynamic>;
  }

  Future<void> deleteStack(int id) async {
    await _dio.delete('/stacks/$id/');
  }

  Future<Map<String, dynamic>> deployStack(int id) async {
    final res = await _dio.post('/stacks/$id/deploy/');
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> stackAction(int id, String action) async {
    final res = await _dio.post('/stacks/$id/action/$action/');
    return res.data as Map<String, dynamic>;
  }

  Future<String> stackLogs(int id, {int lines = 200}) async {
    final res =
        await _dio.get('/stacks/$id/logs/', queryParameters: {'lines': lines});
    return (res.data as Map<String, dynamic>)['logs'] as String? ?? '';
  }

  Future<Map<String, dynamic>> getStackEnv(int id) async {
    final res = await _dio.get('/stacks/$id/env/');
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateStackEnv(
      int id, Map<String, String> envVars) async {
    final res =
        await _dio.patch('/stacks/$id/env/', data: {'env_vars': envVars});
    return res.data as Map<String, dynamic>;
  }

  // ── Docker status ─────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> dockerStatus() async {
    final res = await _dio.get('/docker/status/');
    return res.data as Map<String, dynamic>;
  }

  // ── NGINX Vhosts ──────────────────────────────────────────────────────────

  /// List vhosts for a specific stack.
  Future<List<dynamic>> listStackVhosts(int stackId) async {
    final res = await _dio.get('/stacks/$stackId/vhosts/');
    return res.data as List<dynamic>;
  }

  /// Create a new vhost (HTTP only initially).
  /// [data] must include: stack (id), domain, upstream_port, service_label,
  /// and optionally ssl_email.
  Future<Map<String, dynamic>> createVhost(Map<String, dynamic> data) async {
    final res = await _dio.post('/nginx/vhosts/', data: data);
    return res.data as Map<String, dynamic>;
  }

  /// Update an existing vhost (e.g. change port or service_label).
  Future<Map<String, dynamic>> updateVhost(
      int id, Map<String, dynamic> data) async {
    final res = await _dio.patch('/nginx/vhosts/$id/', data: data);
    return res.data as Map<String, dynamic>;
  }

  /// Delete a vhost (removes the nginx config and reloads nginx).
  Future<void> deleteVhost(int id) async {
    await _dio.delete('/nginx/vhosts/$id/');
  }

  /// Run Certbot for a vhost. Body: { "email": "..." }
  /// Returns the updated vhost object (with ssl_status, ssl_expires_at, etc.).
  /// Throws a [CertbotException] on 422 so callers can display the certbot output.
  Future<Map<String, dynamic>> runCertbot(int vhostId, String email) async {
    try {
      final res = await _dio.post(
        '/nginx/vhosts/$vhostId/certbot/',
        data: {'email': email},
      );
      return res.data as Map<String, dynamic>;
    } on DioException catch (e) {
      final data = e.response?.data;
      if (data is Map) {
        final msg = (data['error'] as String? ?? '').trim();
        final out = (data['output'] as String? ?? '').trim();
        throw CertbotException(msg, out);
      }
      rethrow;
    }
  }

  /// Refresh cert status from disk and return expiry info.
  Future<Map<String, dynamic>> getCertStatus(int vhostId) async {
    final res = await _dio.get('/nginx/vhosts/$vhostId/cert-status/');
    return res.data as Map<String, dynamic>;
  }

  // ── Update check ──────────────────────────────────────────────────────────────────

  /// Compare the deployed commit SHA with the latest on the branch.
  /// Returns a map with keys: up_to_date, current_sha, current_sha_short,
  /// latest_sha, latest_sha_short, update_available.
  Future<Map<String, dynamic>> checkStackUpdate(int stackId) async {
    final res = await _dio.get('/stacks/$stackId/check-update/');
    return res.data as Map<String, dynamic>;
  }

  /// List running Docker containers for a stack (with port bindings).
  /// Each item: {id, name, service, image, status, ports: [{container_port, host_port}]}
  Future<List<dynamic>> getStackContainers(int stackId) async {
    final res = await _dio.get('/stacks/$stackId/containers/');
    return res.data as List<dynamic>;
  }

  // ── DNS propagation ───────────────────────────────────────────────────────

  /// Check whether the vhost domain resolves to this server's IP.
  /// Returns: {domain, server_ip, resolved_ip, propagated}
  Future<Map<String, dynamic>> checkVhostDns(int vhostId) async {
    final res = await _dio.get('/nginx/vhosts/$vhostId/check-dns/');
    return res.data as Map<String, dynamic>;
  }

  // ── Nginx auto-detection ──────────────────────────────────────────────────

  /// Scan the stack's cloned repo for nginx configs and return VHost suggestions
  /// without writing anything to the DB.
  /// Returns: {project_name, nginx_files_found, suggestions: [...]}
  Future<Map<String, dynamic>> detectNginx(int stackId) async {
    final res = await _dio.get('/stacks/$stackId/detect-nginx/');
    return res.data as Map<String, dynamic>;
  }
}

/// Thrown by [ApiService.runCertbot] when the server returns HTTP 422.
/// [message] is the human-readable error; [output] is the raw certbot stdout/stderr.
class CertbotException implements Exception {
  final String message;
  final String output;
  const CertbotException(this.message, this.output);
  @override
  String toString() => message.isNotEmpty ? message : 'Certbot a échoué.';
}

