import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../services/websocket_service.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '22');
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _ws = WebSocketService();

  bool _connected = false;
  bool _connecting = false;
  final List<String> _lines = [];

  @override
  void dispose() {
    _ws.disconnect();
    for (final c in [_hostCtrl, _portCtrl, _userCtrl, _passCtrl, _inputCtrl]) {
      c.dispose();
    }
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ──────────────────────────────────────────────────────────────────────────
  void _connect() {
    if (_hostCtrl.text.isEmpty || _userCtrl.text.isEmpty) {
      _addLine('✗ Host and Username are required.');
      return;
    }
    setState(() => _connecting = true);
    try {
      _ws.connect('/ws/ssh/');
      _ws.stream?.listen(
        (event) {
          final data = jsonDecode(event as String) as Map<String, dynamic>;
          switch (data['type']) {
            case 'connected':
              setState(() {
                _connected = true;
                _connecting = false;
              });
              _addLine('✓ ${data['message']}');
            case 'output':
              _addLine((data['data'] ?? data['stdout'] ?? '') as String);
            case 'error':
              setState(() {
                _connected = false;
                _connecting = false;
              });
              _addLine('✗ ${data['message']}');
          }
        },
        onDone: () {
          setState(() => _connected = false);
          _addLine('Connection closed.');
        },
        onError: (e) {
          setState(() {
            _connected = false;
            _connecting = false;
          });
          _addLine('WebSocket error: $e');
        },
      );

      _ws.send({
        'type': 'connect',
        'host': _hostCtrl.text.trim(),
        'port': _portCtrl.text.trim(),
        'username': _userCtrl.text.trim(),
        'password': _passCtrl.text,
      });
    } catch (e) {
      setState(() => _connecting = false);
      _addLine('Failed to open WebSocket: $e');
    }
  }

  void _sendInput() {
    final text = _inputCtrl.text;
    if (text.isEmpty || !_connected) return;
    _ws.send({'type': 'input', 'data': '$text\n'});
    _addLine('\$ $text');
    _inputCtrl.clear();
  }

  void _disconnect() {
    _ws.disconnect();
    setState(() => _connected = false);
    _addLine('Disconnected.');
  }

  void _addLine(String text) {
    final lines = text.split('\n');
    setState(() =>
        _lines.addAll(lines.where((l) => l.isNotEmpty || lines.length == 1)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ──────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // ── Header ─────────────────────────────────────────────────
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 28),
            decoration: const BoxDecoration(
              color: AppColors.surface,
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'SSH Terminal',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_connected)
                  OutlinedButton.icon(
                    onPressed: _disconnect,
                    icon: const Icon(Icons.link_off, size: 14),
                    label: const Text('Disconnect'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.accentRed,
                      side: const BorderSide(color: AppColors.accentRed),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                    ),
                  ),
              ],
            ),
          ),
          // ── Body ───────────────────────────────────────────────────
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  if (!_connected)
                    _ConnectionPanel(
                      hostCtrl: _hostCtrl,
                      portCtrl: _portCtrl,
                      userCtrl: _userCtrl,
                      passCtrl: _passCtrl,
                      connecting: _connecting,
                      onConnect: _connect,
                    ),
                  if (!_connected) const SizedBox(height: 16),
                  // ── Terminal view ───────────────────────────────────
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Column(
                        children: [
                          Expanded(
                            child: ListView.builder(
                              controller: _scrollCtrl,
                              itemCount: _lines.length,
                              itemBuilder: (_, i) => SelectableText(
                                _lines[i],
                                style: GoogleFonts.jetBrainsMono(
                                  color: const Color(0xFF22C55E),
                                  fontSize: 13,
                                  height: 1.6,
                                ),
                              ),
                            ),
                          ),
                          if (_connected) ...[
                            const Divider(color: AppColors.border, height: 12),
                            Row(
                              children: [
                                Text(
                                  '\$ ',
                                  style: GoogleFonts.jetBrainsMono(
                                    color: const Color(0xFF22C55E),
                                    fontSize: 13,
                                  ),
                                ),
                                Expanded(
                                  child: TextField(
                                    controller: _inputCtrl,
                                    onSubmitted: (_) => _sendInput(),
                                    style: GoogleFonts.jetBrainsMono(
                                      color: Colors.white,
                                      fontSize: 13,
                                    ),
                                    decoration: const InputDecoration(
                                      border: InputBorder.none,
                                      isDense: true,
                                      filled: false,
                                    ),
                                    autofocus: true,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Connection form ──────────────────────────────────────────────────────────
class _ConnectionPanel extends StatelessWidget {
  final TextEditingController hostCtrl, portCtrl, userCtrl, passCtrl;
  final bool connecting;
  final VoidCallback onConnect;

  const _ConnectionPanel({
    required this.hostCtrl,
    required this.portCtrl,
    required this.userCtrl,
    required this.passCtrl,
    required this.connecting,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'SSH Connection',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: _ConnField(
                    ctrl: hostCtrl, label: 'Host', hint: '192.168.1.1'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ConnField(
                    ctrl: portCtrl,
                    label: 'Port',
                    keyboardType: TextInputType.number),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child:
                    _ConnField(ctrl: userCtrl, label: 'Username', hint: 'root'),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: _ConnField(
                    ctrl: passCtrl, label: 'Password', obscure: true),
              ),
              const SizedBox(width: 16),
              ElevatedButton.icon(
                onPressed: connecting ? null : onConnect,
                icon: connecting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation(AppColors.background),
                        ),
                      )
                    : const Icon(Icons.power_settings_new, size: 16),
                label: Text(connecting ? 'Connecting…' : 'Connect'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ConnField extends StatelessWidget {
  final TextEditingController ctrl;
  final String label;
  final String? hint;
  final bool obscure;
  final TextInputType? keyboardType;

  const _ConnField({
    required this.ctrl,
    required this.label,
    this.hint,
    this.obscure = false,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) => TextField(
        controller: ctrl,
        obscureText: obscure,
        keyboardType: keyboardType,
        style: GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 14),
        decoration: InputDecoration(labelText: label, hintText: hint),
      );
}
