import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Thin wrapper around [WebSocketChannel].
/// WS base URL is injected via --dart-define=WS_URL=…
class WebSocketService {
  static const _wsBaseUrl = String.fromEnvironment(
    'WS_URL',
    defaultValue: 'ws://localhost:8000',
  );

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
