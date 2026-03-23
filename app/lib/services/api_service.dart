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

  // ── Docker ──────────────────────────────────────────────────────────────────

  Future<List<dynamic>> listContainers() async {
    final res = await _dio.get('/docker/containers/');
    return res.data as List<dynamic>;
  }

  Future<Map<String, dynamic>> createContainer(Map<String, dynamic> data) async {
    final res = await _dio.post('/docker/containers/create/', data: data);
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> containerAction(String containerId, String action) async {
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

  Future<Map<String, dynamic>> updateSite(int id, Map<String, dynamic> data) async {
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

  Future<Map<String, dynamic>> siteCertbot(int id, String domain, String email) async {
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
    final res = await _dio.post('/github/branches/', data: {'token': token, 'repo': repo});
    return (res.data as List<dynamic>).cast<String>();
  }
}
