import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Centralised HTTP client.
/// Base URL is injected at build time via --dart-define=API_URL=…
/// Defaults to http://localhost:8000/api for local dev.
class ApiService {
  static const _baseUrl = String.fromEnvironment(
    'API_URL',
    defaultValue: 'http://localhost:8000/api',
  );

  late final Dio _dio;

  /// Called when a token refresh fails (e.g. refresh token expired/blacklisted).
  /// Wire this up to trigger a global logout in your AuthProvider.
  void Function()? onForceLogout;

  /// Whether a refresh is already in flight (prevents concurrent refresh loops).
  bool _isRefreshing = false;

  ApiService() {
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
        // Only intercept 401s on non-refresh endpoints to avoid infinite loops.
        final path = error.requestOptions.path;
        if (error.response?.statusCode == 401 &&
            !path.contains('/auth/refresh/') &&
            !path.contains('/auth/login/') &&
            !_isRefreshing) {
          _isRefreshing = true;
          try {
            final prefs = await SharedPreferences.getInstance();
            final refreshToken = prefs.getString('refresh_token');
            if (refreshToken == null) {
              _isRefreshing = false;
              onForceLogout?.call();
              return handler.next(error);
            }

            // Use a bare Dio to avoid re-triggering this interceptor.
            final refreshDio = Dio(BaseOptions(baseUrl: _baseUrl));
            final res = await refreshDio.post('/auth/refresh/', data: {
              'refresh': refreshToken,
            });

            final newAccess = res.data['access'] as String;
            // simplejwt ROTATE_REFRESH_TOKENS returns a new refresh token.
            final newRefresh = res.data['refresh'] as String?;

            await prefs.setString('access_token', newAccess);
            if (newRefresh != null) {
              await prefs.setString('refresh_token', newRefresh);
            }

            _isRefreshing = false;

            // Retry the original request with the new access token.
            final opts = error.requestOptions;
            opts.headers['Authorization'] = 'Bearer $newAccess';
            final retryResponse = await _dio.fetch(opts);
            return handler.resolve(retryResponse);
          } catch (_) {
            _isRefreshing = false;
            // Refresh failed — force logout.
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove('access_token');
            await prefs.remove('refresh_token');
            onForceLogout?.call();
            return handler.next(error);
          }
        }
        handler.next(error);
      },
    ));
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

  Future<Map<String, dynamic>> githubVerifyToken(String token) async {
    final res = await _dio.post('/github/user/', data: {'token': token});
    return res.data as Map<String, dynamic>;
  }

  Future<List<dynamic>> githubListRepos(String token) async {
    final res = await _dio.post('/github/repos/', data: {'token': token});
    return res.data as List<dynamic>;
  }

  Future<List<String>> githubListBranches(String token, String repo) async {
    final res = await _dio
        .post('/github/branches/', data: {'token': token, 'repo': repo});
    return (res.data as List<dynamic>).cast<String>();
  }
}
