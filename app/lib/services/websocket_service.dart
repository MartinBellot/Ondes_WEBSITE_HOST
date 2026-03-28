import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:web_socket_channel/web_socket_channel.dart';
import '../utils/server_config.dart';

/// Thin wrapper around [WebSocketChannel].
/// WS URL resolution priority:
///   1. Mobile (iOS/Android): ServerConfig.serverUrl converted to ws(s)://
///   2. --dart-define WS_URL build flag
///   3. Current page origin converted to ws(s)://  (production web)
///   4. ws://localhost:8000  (local dev fallback)
class WebSocketService {
  static const _envUrl = String.fromEnvironment('WS_URL');

  static String get _wsBaseUrl {
    // Mobile: derive WS URL from the user-configured server URL.
    if (!kIsWeb && ServerConfig.isConfigured) {
      final serverUrl = ServerConfig.serverUrl!;
      final wsScheme = serverUrl.startsWith('https') ? 'wss' : 'ws';
      final hostPart = serverUrl.replaceFirst(RegExp(r'^https?'), '');
      return '$wsScheme$hostPart';
    }
    if (_envUrl.isNotEmpty) return _envUrl;
    try {
      final origin = Uri.base.origin;
      if (origin.isNotEmpty &&
          !origin.contains('localhost') &&
          !origin.contains('127.0.0.1')) {
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
    // On Flutter web, a failed connection raises errors on BOTH `ready` and
    // `sink.done`. Without these suppressors, either one that isn't caught
    // becomes an "Uncaught Error" in the Dart zone even when `onError` is set
    // on the stream subscription. Stream errors are still delivered via
    // listen(onError:), so suppressing these futures is safe.
    _channel!.ready.catchError((_) {});
    _channel!.sink.done.catchError((_) {});
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
