import 'package:flutter/foundation.dart';
import '../services/api_service.dart';

class DockerProvider extends ChangeNotifier {
  final _api = ApiService();

  List<dynamic> _containers = [];
  bool _isLoading = false;
  String? _error;

  List<dynamic> get containers => _containers;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> fetchContainers() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      _containers = await _api.listContainers();
    } catch (e) {
      _error = e.toString();
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<bool> createContainer(Map<String, dynamic> data) async {
    try {
      await _api.createContainer(data);
      await fetchContainers();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<void> performAction(String containerId, String action) async {
    try {
      await _api.containerAction(containerId, action);
      await fetchContainers();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }
}
