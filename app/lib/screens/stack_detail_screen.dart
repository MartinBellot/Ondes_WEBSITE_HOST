import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/stacks_provider.dart';
import '../services/websocket_service.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

class StackDetailScreen extends StatefulWidget {
  final int stackId;

  const StackDetailScreen({super.key, required this.stackId});

  @override
  State<StackDetailScreen> createState() => _StackDetailScreenState();
}

class _StackDetailScreenState extends State<StackDetailScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;

  // ── WebSocket ─────────────────────────────────────────────────────────────
  final _ws = WebSocketService();
  final List<_LogEntry> _deployLogs = [];
  StreamSubscription? _wsSub;

  // ── Stack data ────────────────────────────────────────────────────────────
  Map<String, dynamic> _stack = {};
  bool _isLoading = true;

  // ── Env editor ────────────────────────────────────────────────────────────
  final Map<String, TextEditingController> _envControllers = {};
  bool _isSavingEnv = false;

  // ── Logs tab ──────────────────────────────────────────────────────────────
  String _staticLogs = '';
  bool _isLoadingLogs = false;

  // ── Update check ────────────────────────────────────────────────
  Map<String, dynamic>? _updateInfo;

  final _api = ApiService();
  final _logsScrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() {
      if (_tabController.index == 2 && _staticLogs.isEmpty) {
        _loadStaticLogs();
      }
    });
    _loadStack();
    _connectWs();
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _ws.disconnect();
    _tabController.dispose();
    _logsScrollCtrl.dispose();
    for (final c in _envControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadStack() async {
    setState(() => _isLoading = true);
    try {
      final data = await _api.getStack(widget.stackId);
      setState(() {
        _stack = data;
        _buildEnvControllers(
            Map<String, String>.from((data['env_vars'] as Map? ?? {})
                .map((k, v) => MapEntry(k.toString(), v.toString()))));
      });
      _checkForUpdates(); // fire-and-forget
    } catch (_) {}
    setState(() => _isLoading = false);
  }

  Future<void> _checkForUpdates() async {
    try {
      final info = await _api.checkStackUpdate(widget.stackId);
      if (mounted) setState(() => _updateInfo = info);
    } catch (_) {}
  }

  void _buildEnvControllers(Map<String, String> vars) {
    for (final c in _envControllers.values) {
      c.dispose();
    }
    _envControllers.clear();
    for (final e in vars.entries) {
      _envControllers[e.key] = TextEditingController(text: e.value);
    }
  }

  Future<void> _connectWs() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token') ?? '';
    _ws.connect('/ws/deploy/${widget.stackId}/?token=$token');
    _wsSub = _ws.stream?.listen((raw) {
      if (!mounted) return;
      try {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        final type = msg['type'] as String? ?? '';
        if (type == 'log') {
          setState(() => _deployLogs.add(_LogEntry(
                message: msg['message'] as String? ?? '',
                level: msg['level'] as String? ?? 'info',
              )));
          _scrollLogsToBottom();
        } else if (type == 'status') {
          setState(() {
            _stack = Map.from(_stack)
              ..['status'] = msg['status']
              ..['status_message'] = msg['message'];
          });
          // Also update the provider list
          context
              .read<StacksProvider>()
              .refreshStack(widget.stackId);
        }
      } catch (_) {}
    });
  }

  void _scrollLogsToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logsScrollCtrl.hasClients) {
        _logsScrollCtrl.animateTo(
          _logsScrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _loadStaticLogs() async {
    setState(() => _isLoadingLogs = true);
    _staticLogs = await context.read<StacksProvider>().fetchLogs(widget.stackId);
    setState(() => _isLoadingLogs = false);
  }

  Future<void> _deploy() async {
    setState(() {
      _deployLogs.clear();
      _updateInfo = null; // will refresh after redeploy
    });
    _tabController.animateTo(0); // Switch to deploy log tab
    await context.read<StacksProvider>().deployStack(widget.stackId);
  }

  Future<void> _action(String action) async {
    await context.read<StacksProvider>().stackAction(widget.stackId, action);
    await _loadStack();
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Supprimer ce stack ?',
            style: TextStyle(color: AppColors.textPrimary)),
        content: const Text(
            'Cette action supprimera les containers et les données associées.',
            style: TextStyle(color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style:
                TextButton.styleFrom(foregroundColor: AppColors.accentRed),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<StacksProvider>().deleteStack(widget.stackId);
      Navigator.pop(context);
    }
  }

  Future<void> _saveEnv() async {
    setState(() => _isSavingEnv = true);
    final vars = {
      for (final e in _envControllers.entries) e.key: e.value.text,
    };
    final ok = await context
        .read<StacksProvider>()
        .updateEnv(widget.stackId, vars);
    setState(() => _isSavingEnv = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? 'Variables sauvegardées'
            : 'Erreur lors de la sauvegarde'),
        backgroundColor:
            ok ? AppColors.accentGreen : AppColors.accentRed,
      ));
    }
  }

  void _addEnvVar() {
    showDialog(
      context: context,
      builder: (_) => _AddEnvVarDialog(
        onAdd: (key, value) {
          setState(() {
            _envControllers[key] =
                TextEditingController(text: value);
          });
        },
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
            backgroundColor: AppColors.surface,
            title: const Text('Stack',
                style: TextStyle(color: AppColors.textPrimary))),
        body: const Center(
            child:
                CircularProgressIndicator(color: AppColors.accent)),
      );
    }

    final name = _stack['name'] as String? ?? 'Stack';
    final status = _stack['status'] as String? ?? 'idle';
    final statusMsg = _stack['status_message'] as String? ?? '';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: Text(name,
            style: const TextStyle(color: AppColors.textPrimary)),
        actions: [
          IconButton(
            icon:
                const Icon(Icons.delete_outline, color: AppColors.accentRed),
            tooltip: 'Supprimer',
            onPressed: _confirmDelete,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.accent,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.accent,
          isScrollable: true,
          tabs: const [
            Tab(text: 'Déploiement'),
            Tab(text: 'Variables'),
            Tab(text: 'Logs'),
            Tab(text: 'Domaine & SSL'),
          ],
        ),
      ),
      body: Column(
        children: [
          // ── Status banner ──────────────────────────────────────────────
          _StatusBanner(
              status: status, message: statusMsg),
          // ── Update banner (new commit available) ───────────────────────
          if (_updateInfo != null &&
              _updateInfo!['update_available'] == true)
            _UpdateBanner(
              currentSha:
                  _updateInfo!['current_sha_short'] as String? ?? '',
              latestSha:
                  _updateInfo!['latest_sha_short'] as String? ?? '',
              onRedeploy: _deploy,
              onDismiss: () =>
                  setState(() => _updateInfo = null),
            ),
          // ── Action bar ─────────────────────────────────────────────────
          _ActionBar(
              status: status,
              onDeploy: _deploy,
              onStart: () => _action('start'),
              onStop: () => _action('stop'),
              onRestart: () => _action('restart')),
          // ── Tabs ───────────────────────────────────────────────────────
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                // Deploy log
                _DeployLogTab(
                  logs: _deployLogs,
                  scrollCtrl: _logsScrollCtrl,
                ),
                // Env vars editor
                _EnvVarsTab(
                  controllers: _envControllers,
                  isSaving: _isSavingEnv,
                  onSave: _saveEnv,
                  onAdd: _addEnvVar,
                  onRemove: (key) {
                    setState(() {
                      _envControllers.remove(key)?.dispose();
                    });
                  },
                ),
                // Static logs
                _StaticLogsTab(
                  logs: _staticLogs,
                  isLoading: _isLoadingLogs,
                  onRefresh: _loadStaticLogs,
                ),
                // Domaine & SSL
                _DomainSslTab(stackId: widget.stackId),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Status banner ────────────────────────────────────────────────────────────

class _StatusBanner extends StatelessWidget {
  final String status;
  final String message;

  const _StatusBanner({required this.status, required this.message});

  static const _statusMeta = {
    'running': ("En cours d'exécution", AppColors.accentGreen),
    'error': ('Erreur', AppColors.accentRed),
    'building': ('Construction…', AppColors.accentYellow),
    'cloning': ('Clonage…', AppColors.accentYellow),
    'starting': ('Démarrage…', AppColors.accentYellow),
    'stopped': ('Arrêté', AppColors.textSecondary),
    'idle': ('Inactif', AppColors.textSecondary),
  };

  @override
  Widget build(BuildContext context) {
    final meta = _statusMeta[status];
    final label = meta?.$1 ?? status;
    final color = meta?.$2 ?? AppColors.textSecondary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: color.withOpacity(0.08),
      child: Row(
        children: [
          Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  color: color, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Text(label,
              style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w600,
                  fontSize: 13)),
          if (message.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(message,
                  style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12),
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Update banner ────────────────────────────────────────────────────────────

class _UpdateBanner extends StatelessWidget {
  final String currentSha;
  final String latestSha;
  final VoidCallback onRedeploy;
  final VoidCallback onDismiss;

  const _UpdateBanner({
    required this.currentSha,
    required this.latestSha,
    required this.onRedeploy,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: AppColors.accentYellow.withOpacity(0.10),
      child: Row(
        children: [
          const Icon(Icons.update, size: 16, color: AppColors.accentYellow),
          const SizedBox(width: 8),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12),
                children: [
                  const TextSpan(text: 'Nouveau commit disponible\u00a0: '),
                  TextSpan(
                    text: currentSha,
                    style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600),
                  ),
                  const TextSpan(text: ' \u2192 '),
                  TextSpan(
                    text: latestSha,
                    style: const TextStyle(
                        color: AppColors.accentYellow,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
          TextButton(
            onPressed: onRedeploy,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.accentYellow,
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Redéployer',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          InkWell(
            onTap: onDismiss,
            borderRadius: BorderRadius.circular(4),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.close,
                  size: 14, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Action bar ───────────────────────────────────────────────────────────────

class _ActionBar extends StatelessWidget {
  final String status;
  final VoidCallback onDeploy;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onRestart;

  const _ActionBar({
    required this.status,
    required this.onDeploy,
    required this.onStart,
    required this.onStop,
    required this.onRestart,
  });

  @override
  Widget build(BuildContext context) {
    final isRunning = status == 'running';
    final isBusy = ['building', 'cloning', 'starting'].contains(status);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          _ActionBtn(
            icon: Icons.rocket_launch_outlined,
            label: 'Redéployer',
            color: AppColors.accent,
            onTap: isBusy ? null : onDeploy,
          ),
          const SizedBox(width: 10),
          if (!isRunning)
            _ActionBtn(
              icon: Icons.play_arrow,
              label: 'Démarrer',
              color: AppColors.accentGreen,
              onTap: isBusy ? null : onStart,
            ),
          if (isRunning)
            _ActionBtn(
              icon: Icons.stop,
              label: 'Arrêter',
              color: AppColors.accentRed,
              onTap: onStop,
            ),
          const SizedBox(width: 10),
          _ActionBtn(
            icon: Icons.restart_alt,
            label: 'Redémarrer',
            color: AppColors.accentYellow,
            onTap: isBusy ? null : onRestart,
          ),
        ],
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _ActionBtn(
      {required this.icon,
      required this.label,
      required this.color,
      this.onTap});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 13)),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withOpacity(0.5)),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

// ─── Deploy log tab ───────────────────────────────────────────────────────────

class _LogEntry {
  final String message;
  final String level;
  _LogEntry({required this.message, required this.level});
}

class _DeployLogTab extends StatelessWidget {
  final List<_LogEntry> logs;
  final ScrollController scrollCtrl;

  const _DeployLogTab({required this.logs, required this.scrollCtrl});

  static const _levelColors = {
    'error': AppColors.accentRed,
    'warning': AppColors.accentYellow,
    'success': AppColors.accentGreen,
    'info': AppColors.textPrimary,
  };

  @override
  Widget build(BuildContext context) {
    if (logs.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.receipt_long_outlined,
                size: 48, color: AppColors.textSecondary),
            SizedBox(height: 12),
            Text("Aucun log de déploiement",
                style: TextStyle(
                    color: AppColors.textSecondary, fontSize: 15)),
            SizedBox(height: 6),
            Text("Cliquez sur Redéployer pour commencer.",
                style: TextStyle(
                    color: AppColors.textSecondary, fontSize: 13)),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: scrollCtrl,
      padding: const EdgeInsets.all(12),
      itemCount: logs.length,
      itemBuilder: (_, i) {
        final entry = logs[i];
        final color = _levelColors[entry.level] ?? AppColors.textPrimary;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Text(
            entry.message,
            style: TextStyle(
                color: color,
                fontSize: 12,
                fontFamily: 'monospace'),
          ),
        );
      },
    );
  }
}

// ─── Env vars tab ─────────────────────────────────────────────────────────────

class _EnvVarsTab extends StatelessWidget {
  final Map<String, TextEditingController> controllers;
  final bool isSaving;
  final VoidCallback onSave;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;

  const _EnvVarsTab({
    required this.controllers,
    required this.isSaving,
    required this.onSave,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              const Text("Variables d'environnement",
                  style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8)),
              const Spacer(),
              TextButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Ajouter'),
                style: TextButton.styleFrom(
                    foregroundColor: AppColors.accent),
              ),
            ],
          ),
        ),
        if (controllers.isEmpty)
          const Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.tune_outlined,
                      size: 48, color: AppColors.textSecondary),
                  SizedBox(height: 10),
                  Text("Aucune variable définie",
                      style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14)),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: ListView(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16),
              children: controllers.entries.map((e) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: Text(e.key,
                            style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                                fontFamily: 'monospace')),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: e.value,
                          style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 13,
                              fontFamily: 'monospace'),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: AppColors.background,
                            contentPadding:
                                const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8),
                            border: OutlineInputBorder(
                                borderRadius:
                                    BorderRadius.circular(6),
                                borderSide: const BorderSide(
                                    color: AppColors.border)),
                            enabledBorder: OutlineInputBorder(
                                borderRadius:
                                    BorderRadius.circular(6),
                                borderSide: const BorderSide(
                                    color: AppColors.border)),
                            focusedBorder: OutlineInputBorder(
                                borderRadius:
                                    BorderRadius.circular(6),
                                borderSide: const BorderSide(
                                    color: AppColors.accent)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        icon: const Icon(Icons.close,
                            size: 18,
                            color: AppColors.textSecondary),
                        onPressed: () => onRemove(e.key),
                        visualDensity:
                            VisualDensity.compact,
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: isSaving ? null : onSave,
              icon: isSaving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white))
                  : const Icon(Icons.save_outlined),
              label: Text(isSaving ? 'Sauvegarde…' : 'Sauvegarder'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                padding: const EdgeInsets.symmetric(
                    vertical: 12),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Static logs tab ──────────────────────────────────────────────────────────

class _StaticLogsTab extends StatelessWidget {
  final String logs;
  final bool isLoading;
  final VoidCallback onRefresh;

  const _StaticLogsTab(
      {required this.logs,
      required this.isLoading,
      required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(
          child:
              CircularProgressIndicator(color: AppColors.accent));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(
            children: [
              const Text('Logs container',
                  style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh,
                    size: 18, color: AppColors.textSecondary),
                tooltip: 'Rafraîchir',
                onPressed: onRefresh,
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              logs.isEmpty ? '(aucun log)' : logs,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Add env var dialog ───────────────────────────────────────────────────────

class _AddEnvVarDialog extends StatefulWidget {
  final void Function(String key, String value) onAdd;
  const _AddEnvVarDialog({required this.onAdd});

  @override
  State<_AddEnvVarDialog> createState() => _AddEnvVarDialogState();
}

class _AddEnvVarDialogState extends State<_AddEnvVarDialog> {
  final _keyCtrl = TextEditingController();
  final _valCtrl = TextEditingController();

  @override
  void dispose() {
    _keyCtrl.dispose();
    _valCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Ajouter une variable',
          style: TextStyle(color: AppColors.textPrimary)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _keyCtrl,
            autofocus: true,
            style: const TextStyle(
                color: AppColors.textPrimary, fontSize: 14),
            decoration: const InputDecoration(
              labelText: 'Clé (ex: PORT)',
              labelStyle:
                  TextStyle(color: AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _valCtrl,
            style: const TextStyle(
                color: AppColors.textPrimary, fontSize: 14),
            decoration: const InputDecoration(
              labelText: 'Valeur',
              labelStyle:
                  TextStyle(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler',
              style:
                  TextStyle(color: AppColors.textSecondary)),
        ),
        TextButton(
          onPressed: () {
            final k = _keyCtrl.text.trim();
            if (k.isNotEmpty) {
              widget.onAdd(k, _valCtrl.text);
              Navigator.pop(context);
            }
          },
          style: TextButton.styleFrom(
              foregroundColor: AppColors.accent),
          child: const Text('Ajouter'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Domaine & SSL tab
// ─────────────────────────────────────────────────────────────────────────────

class _DomainSslTab extends StatefulWidget {
  final int stackId;
  const _DomainSslTab({required this.stackId});

  @override
  State<_DomainSslTab> createState() => _DomainSslTabState();
}

class _DomainSslTabState extends State<_DomainSslTab> {
  final _api = ApiService();
  List<dynamic> _vhosts = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadVhosts();
  }

  Future<void> _loadVhosts() async {
    setState(() => _isLoading = true);
    try {
      _vhosts = await _api.listStackVhosts(widget.stackId);
    } catch (_) {}
    setState(() => _isLoading = false);
  }

  void _showAddVhostDialog() {
    showDialog(
      context: context,
      builder: (_) => _AddVhostDialog(
        stackId: widget.stackId,
        onCreated: (vhost) {
          setState(() => _vhosts = [vhost, ..._vhosts]);
          final warning = vhost['warning'] as String?;
          if (warning != null && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(warning),
              backgroundColor: AppColors.accentYellow,
              duration: const Duration(seconds: 6),
            ));
          }
        },
      ),
    );
  }

  Future<void> _deleteVhost(int id, String domain) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Supprimer $domain ?',
            style: const TextStyle(color: AppColors.textPrimary)),
        content: const Text(
          'La config NGINX sera supprimée et NGINX rechargé.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.accentRed),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _api.deleteVhost(id);
      setState(() => _vhosts = _vhosts.where((v) => v['id'] != id).toList());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erreur : $e'),
          backgroundColor: AppColors.accentRed,
        ));
      }
    }
  }

  void _showSslSheet(Map<String, dynamic> vhost) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _SslActivationSheet(
        vhost: vhost,
        onSuccess: (updated) {
          setState(() {
            final idx = _vhosts.indexWhere((v) => v['id'] == updated['id']);
            if (idx != -1) _vhosts[idx] = updated;
          });
        },
      ),
    );
  }

  Future<void> _refreshCertStatus(int id) async {
    try {
      final info = await _api.getCertStatus(id);
      setState(() {
        final idx = _vhosts.indexWhere((v) => v['id'] == id);
        if (idx != -1) {
          _vhosts[idx] = {
            ..._vhosts[idx] as Map,
            'ssl_status':    info['ssl_status'],
            'ssl_expires_at': info['expires_at'],
            'cert_days_remaining': info['days_remaining'],
          };
        }
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.accent));
    }

    return Column(
      children: [
        // ── Header action bar ───────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              const Text(
                'Vhosts NGINX',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh,
                    size: 18, color: AppColors.textSecondary),
                tooltip: 'Rafraîchir',
                onPressed: _loadVhosts,
              ),
              FilledButton.icon(
                onPressed: _showAddVhostDialog,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Ajouter', style: TextStyle(fontSize: 13)),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                ),
              ),
            ],
          ),
        ),
        if (_vhosts.isEmpty)
          const Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.language_outlined,
                      size: 52, color: AppColors.textSecondary),
                  SizedBox(height: 12),
                  Text('Aucun domaine configuré',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 15)),
                  SizedBox(height: 6),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      'Cliquez sur "Ajouter" pour lier un domaine à ce stack.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _vhosts.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _VhostCard(
                vhost: _vhosts[i],
                onDelete: () => _deleteVhost(
                    _vhosts[i]['id'] as int, _vhosts[i]['domain'] as String),
                onActivateSsl: () => _showSslSheet(_vhosts[i]),
                onRefreshCert: () =>
                    _refreshCertStatus(_vhosts[i]['id'] as int),
              ),
            ),
          ),
      ],
    );
  }
}

// ─── Vhost card ───────────────────────────────────────────────────────────────

class _VhostCard extends StatelessWidget {
  final Map<String, dynamic> vhost;
  final VoidCallback onDelete;
  final VoidCallback onActivateSsl;
  final VoidCallback onRefreshCert;

  const _VhostCard({
    required this.vhost,
    required this.onDelete,
    required this.onActivateSsl,
    required this.onRefreshCert,
  });

  static const _sslStatusColors = {
    'active':   AppColors.accentGreen,
    'warning':  AppColors.accentYellow,
    'critical': AppColors.accentRed,
    'pending':  AppColors.accentYellow,
    'error':    AppColors.accentRed,
    'expired':  AppColors.accentRed,
    'none':     AppColors.textSecondary,
  };

  static const _sslStatusLabels = {
    'active':   'SSL actif',
    'pending':  'En cours…',
    'error':    'Erreur SSL',
    'expired':  'Expiré',
    'none':     'HTTP seulement',
  };

  @override
  Widget build(BuildContext context) {
    final domain       = vhost['domain'] as String? ?? '';
    final label        = vhost['service_label'] as String? ?? 'app';
    final port         = vhost['upstream_port'];
    final sslEnabled   = vhost['ssl_enabled'] as bool? ?? false;
    final sslStatus    = vhost['ssl_status'] as String? ?? 'none';
    final expiresAt    = vhost['ssl_expires_at'] as String?;
    final daysLeft     = vhost['cert_days_remaining'] as int?;
    final sslColor     = _sslStatusColors[sslStatus] ?? AppColors.textSecondary;
    final sslLabel     = _sslStatusLabels[sslStatus] ?? sslStatus;

    // Parse expiry if set
    DateTime? expiry;
    if (expiresAt != null) {
      try { expiry = DateTime.parse(expiresAt); } catch (_) {}
    }
    final days = daysLeft ?? (expiry != null
        ? expiry.difference(DateTime.now()).inDays
        : null);

    Color expiryColor = AppColors.accentGreen;
    if (days != null) {
      if (days < 0) expiryColor = AppColors.accentRed;
      else if (days < 7) expiryColor = AppColors.accentRed;
      else if (days < 30) expiryColor = AppColors.accentYellow;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Row 1: domain + service label ──────────────────────────────
          Row(
            children: [
              const Icon(Icons.language, size: 16, color: AppColors.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  domain,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14),
                ),
              ),
              _LabelChip(label),
            ],
          ),
          const SizedBox(height: 8),
          // ── Row 2: port + SSL badge ────────────────────────────────────
          Row(
            children: [
              const Icon(Icons.settings_ethernet,
                  size: 14, color: AppColors.textSecondary),
              const SizedBox(width: 4),
              Text(
                'Port : $port',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12),
              ),
              const SizedBox(width: 16),
              Icon(
                sslEnabled ? Icons.lock : Icons.lock_open,
                size: 14,
                color: sslColor,
              ),
              const SizedBox(width: 4),
              Text(
                sslLabel,
                style: TextStyle(color: sslColor, fontSize: 12),
              ),
            ],
          ),
          // ── Cert expiry info (when SSL active) ─────────────────────────
          if (sslEnabled && days != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  days < 0
                      ? Icons.warning_amber_rounded
                      : Icons.verified_outlined,
                  size: 13,
                  color: expiryColor,
                ),
                const SizedBox(width: 4),
                Text(
                  days < 0
                      ? 'Certificat expiré depuis ${days.abs()}j'
                      : 'Expire dans $days jours',
                  style: TextStyle(color: expiryColor, fontSize: 12),
                ),
                if (expiry != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    '(${_formatDate(expiry)})',
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 11),
                  ),
                ],
                const Spacer(),
                InkWell(
                  onTap: onRefreshCert,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: const Icon(Icons.refresh,
                        size: 14, color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          // ── Actions ────────────────────────────────────────────────────
          Row(
            children: [
              if (!sslEnabled)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onActivateSsl,
                    icon: const Icon(Icons.lock_outline, size: 14),
                    label: const Text('Activer SSL',
                        style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.accentGreen,
                      side: const BorderSide(
                          color: AppColors.accentGreen, width: 1),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                )
              else
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onActivateSsl,
                    icon: const Icon(Icons.autorenew, size: 14),
                    label: const Text('Renouveler cert',
                        style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.accent,
                      side: const BorderSide(
                          color: AppColors.accent, width: 1),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline, size: 14),
                label: const Text('Supprimer',
                    style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accentRed,
                  side: const BorderSide(
                      color: AppColors.accentRed, width: 1),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}/'
        '${dt.month.toString().padLeft(2, '0')}/'
        '${dt.year}';
  }
}

class _LabelChip extends StatelessWidget {
  final String label;
  const _LabelChip(this.label);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.accent.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: const TextStyle(
                color: AppColors.accent,
                fontSize: 11,
                fontWeight: FontWeight.w500)),
      );
}

// ─── Add vhost dialog ─────────────────────────────────────────────────────────

class _AddVhostDialog extends StatefulWidget {
  final int stackId;
  final void Function(Map<String, dynamic>) onCreated;
  const _AddVhostDialog({required this.stackId, required this.onCreated});

  @override
  State<_AddVhostDialog> createState() => _AddVhostDialogState();
}

class _AddVhostDialogState extends State<_AddVhostDialog> {
  final _domainCtrl = TextEditingController();
  final _portCtrl   = TextEditingController();
  final _labelCtrl  = TextEditingController(text: 'app');
  final _emailCtrl  = TextEditingController();
  final _api        = ApiService();

  List<Map<String, dynamic>> _containers = [];
  bool   _loadingContainers = true;
  int?   _selectedContainerIdx;
  bool   _manualMode = false;
  bool   _isSaving   = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadContainers();
  }

  @override
  void dispose() {
    _domainCtrl.dispose();
    _portCtrl.dispose();
    _labelCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadContainers() async {
    try {
      final list = await _api.getStackContainers(widget.stackId);
      if (!mounted) return;
      setState(() {
        _containers        = List<Map<String, dynamic>>.from(list);
        _loadingContainers = false;
        if (_containers.isEmpty) _manualMode = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() { _loadingContainers = false; _manualMode = true; });
    }
  }

  void _selectContainerIdx(int? idx) {
    setState(() {
      _selectedContainerIdx = idx;
      if (idx == null) return;
      final c = _containers[idx];
      _labelCtrl.text = c['service'] as String? ?? 'app';
      final ports = c['ports'] as List? ?? [];
      _portCtrl.text =
          ports.isNotEmpty ? (ports.first['host_port'] ?? '').toString() : '';
    });
  }

  List<Map<String, dynamic>> get _selectedPorts {
    if (_selectedContainerIdx == null) return [];
    return List<Map<String, dynamic>>.from(
        (_containers[_selectedContainerIdx!]['ports'] as List? ?? []));
  }

  Future<void> _save() async {
    final domain = _domainCtrl.text.trim();
    final port   = int.tryParse(_portCtrl.text.trim());
    if (domain.isEmpty) {
      setState(() => _error = 'Le domaine est requis.');
      return;
    }
    if (port == null || port < 1 || port > 65535) {
      setState(() => _error = 'Port invalide (1-65535).');
      return;
    }
    setState(() { _isSaving = true; _error = null; });
    try {
      final selectedContainer = _selectedContainerIdx != null
          ? _containers[_selectedContainerIdx!]
          : null;
      final vhost = await _api.createVhost({
        'stack':          widget.stackId,
        'domain':         domain,
        'upstream_port':  port,
        'service_label':  _labelCtrl.text.trim().isEmpty ? 'app' : _labelCtrl.text.trim(),
        'ssl_email':      _emailCtrl.text.trim(),
        'container_name': selectedContainer?['name'] ?? '',
      });
      widget.onCreated(vhost);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _error = e.toString());
    }
    setState(() => _isSaving = false);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hasManyPorts = _selectedPorts.length > 1;
    return AlertDialog(
      backgroundColor: AppColors.surface,
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
      title: Row(
        children: [
          const Expanded(
            child: Text('Ajouter un vhost',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
          ),
          if (!_loadingContainers && _containers.isNotEmpty)
            TextButton(
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact),
              onPressed: () => setState(() {
                _manualMode = !_manualMode;
                _selectedContainerIdx = null;
              }),
              child: Text(
                _manualMode ? '← Container' : 'Manuel',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 11),
              ),
            ),
        ],
      ),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 4),
              _Field(
                ctrl: _domainCtrl,
                label: 'Domaine (ex: app.example.com)',
                hint: 'Sans https://',
              ),
              const SizedBox(height: 14),
              // ── Container-picker / manual section ─────────────────────────
              if (_loadingContainers)
                const Row(children: [
                  SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.accent),
                  ),
                  SizedBox(width: 8),
                  Text('Détection des containers…',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 12)),
                ])
              else if (!_manualMode) ...[
                _buildContainerDropdown(),
                if (hasManyPorts) ...[
                  const SizedBox(height: 8),
                  _buildPortDropdown(),
                ],
                const SizedBox(height: 8),
                _Field(
                  ctrl: _portCtrl,
                  label: 'Port hôte (pré-rempli, modifiable)',
                  keyboardType: TextInputType.number,
                ),
              ] else ...[
                _Field(
                    ctrl: _labelCtrl,
                    label: 'Label service (ex: app, api, front)'),
                const SizedBox(height: 10),
                _Field(
                  ctrl: _portCtrl,
                  label: 'Port upstream (port exposé sur l\'hôte)',
                  keyboardType: TextInputType.number,
                ),
              ],
              const SizedBox(height: 10),
              _Field(
                ctrl: _emailCtrl,
                label: 'Email SSL (optionnel, pour Certbot)',
                keyboardType: TextInputType.emailAddress,
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!,
                    style: const TextStyle(
                        color: AppColors.accentRed, fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.pop(context),
          child: const Text('Annuler',
              style: TextStyle(color: AppColors.textSecondary)),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _save,
          style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
          child: _isSaving
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('Créer'),
        ),
      ],
    );
  }

  Widget _buildContainerDropdown() {
    final items = <DropdownMenuItem<int>>[
      const DropdownMenuItem<int>(
        value: -1,
        child: Text('— Choisir un container —',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
      ),
      ..._containers.asMap().entries.map((entry) {
        final i = entry.key;
        final c = entry.value;
        final service  = c['service'] as String? ?? c['name'] as String? ?? '?';
        final ports    = c['ports'] as List? ?? [];
        final portStr  = ports.isNotEmpty
            ? ' · port ${ports.first['host_port']}'
            : ' (aucun port exposé)';
        return DropdownMenuItem<int>(
          value: i,
          child: Row(children: [
            const Icon(Icons.dns_outlined,
                size: 14, color: AppColors.textSecondary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '$service$portStr',
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
        );
      }),
    ];
    return DropdownButtonFormField<int>(
      value: _selectedContainerIdx ?? -1,
      items: items,
      isExpanded: true,
      onChanged: (v) => _selectContainerIdx(v == -1 ? null : v),
      dropdownColor: AppColors.surface,
      style: const TextStyle(color: AppColors.textPrimary),
      decoration: _dropdownDecoration('Container Docker'),
    );
  }

  Widget _buildPortDropdown() {
    final ports = _selectedPorts;
    final currentHostPort = int.tryParse(_portCtrl.text);
    return DropdownButtonFormField<int>(
      value: currentHostPort,
      items: ports.map((p) {
        final hp = p['host_port'] as int?;
        final cp = p['container_port'] ?? '';
        return DropdownMenuItem<int>(
          value: hp,
          child: Text(
            'Port $hp (interne : $cp)',
            style:
                const TextStyle(color: AppColors.textPrimary, fontSize: 13),
          ),
        );
      }).toList(),
      isExpanded: true,
      onChanged: (v) => setState(() => _portCtrl.text = v?.toString() ?? ''),
      dropdownColor: AppColors.surface,
      style: const TextStyle(color: AppColors.textPrimary),
      decoration: _dropdownDecoration('Port exposé sur l\'hôte'),
    );
  }

  InputDecoration _dropdownDecoration(String label) => InputDecoration(
        labelText: label,
        labelStyle:
            const TextStyle(color: AppColors.textSecondary, fontSize: 12),
        filled: true,
        fillColor: AppColors.background,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.border)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.border)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.accent)),
      );
}

class _Field extends StatelessWidget {
  final TextEditingController ctrl;
  final String label;
  final String? hint;
  final TextInputType? keyboardType;
  const _Field({required this.ctrl, required this.label, this.hint, this.keyboardType});

  @override
  Widget build(BuildContext context) => TextField(
        controller: ctrl,
        keyboardType: keyboardType,
        style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
          hintStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
          filled: true,
          fillColor: AppColors.background,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.border)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.border)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.accent)),
        ),
      );
}

// ─── SSL Activation bottom sheet ─────────────────────────────────────────────

class _SslActivationSheet extends StatefulWidget {
  final Map<String, dynamic> vhost;
  final void Function(Map<String, dynamic>) onSuccess;
  const _SslActivationSheet(
      {required this.vhost, required this.onSuccess});

  @override
  State<_SslActivationSheet> createState() => _SslActivationSheetState();
}

class _SslActivationSheetState extends State<_SslActivationSheet> {
  final _emailCtrl = TextEditingController();
  final _api = ApiService();
  bool _isRunning = false;
  String? _output;
  String? _error;

  @override
  void initState() {
    super.initState();
    _emailCtrl.text = (widget.vhost['ssl_email'] as String?) ?? '';
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _runCertbot() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Un email est requis pour Certbot.');
      return;
    }
    setState(() { _isRunning = true; _error = null; _output = null; });
    try {
      final updated = await _api.runCertbot(
          widget.vhost['id'] as int, email);
      setState(() => _output = updated['certbot_output'] as String? ?? 'Succès.');
      widget.onSuccess(updated);
    } catch (e) {
      setState(() => _error = e.toString());
    }
    setState(() => _isRunning = false);
  }

  @override
  Widget build(BuildContext context) {
    final domain = widget.vhost['domain'] as String? ?? '';
    final sslEnabled = widget.vhost['ssl_enabled'] as bool? ?? false;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.5,
      builder: (_, sc) => SingleChildScrollView(
        controller: sc,
        padding: EdgeInsets.fromLTRB(
            20, 16, 20, MediaQuery.of(context).viewInsets.bottom + 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 16),

            // Title
            Row(children: [
              const Icon(Icons.lock_outline, color: AppColors.accentGreen, size: 22),
              const SizedBox(width: 10),
              Text(
                sslEnabled ? 'Renouveler SSL — $domain' : 'Activer SSL — $domain',
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 16),
              ),
            ]),
            const SizedBox(height: 20),

            // ── DNS Guide ───────────────────────────────────────────────
            if (!sslEnabled) ...[
              _SectionTitle('1. Vérifications DNS préalables'),
              const SizedBox(height: 8),
              _DnsGuideCard(domain: domain),
              const SizedBox(height: 16),
            ],

            // ── Email ───────────────────────────────────────────────────
            _SectionTitle(sslEnabled ? 'Email pour Certbot' : '2. Email pour Certbot'),
            const SizedBox(height: 8),
            _Field(
              ctrl: _emailCtrl,
              label: 'Adresse email (notifications Let\'s Encrypt)',
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 20),

            // ── Run button ──────────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isRunning ? null : _runCertbot,
                icon: _isRunning
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.verified_user_outlined),
                label: Text(_isRunning
                    ? 'Certbot en cours…'
                    : (sslEnabled ? 'Renouveler le certificat' : 'Lancer Certbot')),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accentGreen,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  textStyle: const TextStyle(fontSize: 15),
                ),
              ),
            ),

            // ── Result ──────────────────────────────────────────────────
            if (_error != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.accentRed.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.accentRed.withOpacity(0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline,
                        color: AppColors.accentRed, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_error!,
                          style: const TextStyle(
                              color: AppColors.accentRed, fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ],
            if (_output != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.accentGreen.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: AppColors.accentGreen.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(children: [
                      Icon(Icons.check_circle_outline,
                          color: AppColors.accentGreen, size: 16),
                      SizedBox(width: 6),
                      Text('Certbot exécuté avec succès',
                          style: TextStyle(
                              color: AppColors.accentGreen,
                              fontWeight: FontWeight.w600,
                              fontSize: 13)),
                    ]),
                    const SizedBox(height: 8),
                    SelectableText(
                      _output!,
                      style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                          fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DnsGuideCard extends StatelessWidget {
  final String domain;
  const _DnsGuideCard({required this.domain});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.accent.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Let\'s Encrypt doit pouvoir joindre votre serveur sur le port 80 '
            'pour valider votre domaine.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 12),
          _DnsRow(
            icon: Icons.dns_outlined,
            label: 'Enregistrement A',
            value: '$domain  →  <IP_publique_serveur>',
          ),
          const SizedBox(height: 6),
          _DnsRow(
            icon: Icons.timer_outlined,
            label: 'TTL recommandé',
            value: '300 – 3600 secondes',
          ),
          const SizedBox(height: 6),
          _DnsRow(
            icon: Icons.block_outlined,
            label: 'Port 80',
            value: 'Doit être ouvert (pare-feu / hébergeur)',
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 13,
                    color: AppColors.textSecondary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'dig A $domain +short',
                    style: const TextStyle(
                        color: AppColors.accent,
                        fontSize: 12,
                        fontFamily: 'monospace'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DnsRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _DnsRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: AppColors.textSecondary),
          const SizedBox(width: 6),
          Text('$label : ',
              style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 12)),
          ),
        ],
      );
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 13),
      );
}

