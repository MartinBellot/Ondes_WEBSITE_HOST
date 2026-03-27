import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Thin wrapper around [WebSocketChannel].
/// WS base URL is resolved at runtime from the current page origin (production)
/// or falls back to ws://localhost:8000 for local dev.
/// Override at build time with --dart-define=WS_URL=wss://yourdomain.com
class WebSocketService {
  static const _envUrl = String.fromEnvironment('WS_URL');

  static String get _wsBaseUrl {
    if (_envUrl.isNotEmpty) return _envUrl;
    try {
      final origin = Uri.base.origin;
      if (origin.isNotEmpty && !origin.contains('localhost') && !origin.contains('127.0.0.1')) {
        final wsScheme = origin.startsWith('https') ? 'wss' : 'ws';
        final hostPart = origin.replaceFirst(RegExp(r'^https?'), '');
        return '$wsScheme$hostPart';
      }
    } catch (_) {}
    return 'ws://localhost:8000';
  }

  WebSocketChannel? _channel;

  bool get isConnected => _channel != null;

  void connect(String path) {
    _channel = WebSocketChannel.connect(Uri.parse('$_wsBaseUrl$path'));
  }

  Stream? get stream => _channel?.stream;

  void send(Map<String, dynamic> data) {
    _channel?.sink.add(jsonEncode(data));
  }

  void sendRaw(String data) {
    _channel?.sink.add(data);
  }

  void disconnect() {
    _channel?.sink.close();
    _channel = null;
  }
}
