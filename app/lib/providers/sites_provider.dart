import 'package:flutter/foundation.dart';
import '../services/api_service.dart';

class SitesProvider extends ChangeNotifier {
  final _api = ApiService();

  List<dynamic> _sites = [];
  bool _isLoading = false;
  String? _error;

  List<dynamic> get sites => _sites;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> fetchSites() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      _sites = await _api.listSites();
    } catch (e) {
      _error = e.toString();
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<Map<String, dynamic>?> createSite(Map<String, dynamic> data) async {
    try {
      final site = await _api.createSite(data);
      await fetchSites();
      return site;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }

  Future<bool> updateSite(int id, Map<String, dynamic> data) async {
    try {
      await _api.updateSite(id, data);
      await fetchSites();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> deleteSite(int id) async {
    try {
      await _api.deleteSite(id);
      _sites.removeWhere((s) => s['id'] == id);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<Map<String, dynamic>> deploySite(int id) async {
    try {
      final result = await _api.deploySite(id);
      // Optimistically update status
      final idx = _sites.indexWhere((s) => s['id'] == id);
      if (idx != -1) {
        _sites[idx] = {..._sites[idx], 'status': 'deploying'};
        notifyListeners();
      }
      return result;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return {'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> requestCertbot(
      int siteId, String domain, String email) async {
    try {
      return await _api.siteCertbot(siteId, domain, email);
    } catch (e) {
      return {'status': 'error', 'message': e.toString()};
    }
  }

  Future<String?> nginxPreview(int siteId) async {
    try {
      final result = await _api.siteNginxPreview(siteId);
      return result['config'] as String?;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }

  Future<Map<String, dynamic>> applyNginx(int siteId) async {
    try {
      return await _api.siteNginxApply(siteId);
    } catch (e) {
      return {'status': 'error', 'message': e.toString()};
    }
  }
}
