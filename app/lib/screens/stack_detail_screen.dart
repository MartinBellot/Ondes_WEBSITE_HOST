import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/stacks_provider.dart';
import '../services/websocket_service.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/content_header.dart';
import '../widgets/main_shell.dart';

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

  // ── Deploy status polling ────────────────────────────────────────
  bool _wsDeliveredStatus = false;
  bool _wsReconnectScheduled = false;

  final _api = ApiService();
  final _logsScrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
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
    // Cancel the old subscription BEFORE disconnect to prevent its onDone
    // from triggering _scheduleWsReconnect() and creating an infinite loop.
    await _wsSub?.cancel();
    _wsSub = null;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final token = prefs.getString('access_token') ?? '';
    _ws.disconnect();
    _ws.connect('/ws/deploy/${widget.stackId}/?token=$token');
    _wsSub = _ws.stream?.listen(
      (raw) {
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
            _wsDeliveredStatus = true;
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
      },
      onError: (_) {
        // WebSocket connection error — reload stack status via REST
        if (mounted) _loadStack();
        _scheduleWsReconnect();
      },
      onDone: () {
        _scheduleWsReconnect();
      },
      cancelOnError: false,
    );
  }

  void _scheduleWsReconnect() {
    if (!mounted || _wsReconnectScheduled) return;
    // Only keep the WS alive while the stack is actively doing something.
    // When idle/running/stopped there is nothing to stream, so let the connection
    // stay closed to avoid spurious setState() calls every ~10 s.
    final current = _stack['status'] as String? ?? '';
    const busyStates = {'building', 'cloning', 'starting', 'stopping', 'deploying'};
    if (!busyStates.contains(current)) return;

    _wsReconnectScheduled = true;
    Future.delayed(const Duration(seconds: 3), () {
      _wsReconnectScheduled = false;
      if (!mounted) return;
      _wsSub?.cancel();
      _connectWs();
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
    final provider = context.read<StacksProvider>();
    setState(() {
      _deployLogs.clear();
      _updateInfo = null; // will refresh after redeploy
      _wsDeliveredStatus = false;
    });
    _tabController.animateTo(0); // Switch to deploy log tab
    // Re-establish WS before triggering the deploy so log messages aren't missed.
    _wsSub?.cancel();
    await _connectWs();
    await provider.deployStack(widget.stackId);
    // Immediately fetch fresh status so the poll loop doesn't see a stale 'running'.
    await _loadStack();
    // Fallback poll: if WS never delivers the final status (e.g. deploy
    // finishes before WS reconnects), refresh every 4s for up to 40s.
    for (var i = 0; i < 10 && mounted && !_wsDeliveredStatus; i++) {
      await Future.delayed(const Duration(seconds: 4));
      if (!mounted || _wsDeliveredStatus) break;
      await _loadStack(); // load first, then check
      final current = _stack['status'] as String? ?? '';
      if (!['building', 'cloning', 'starting'].contains(current)) break;
    }
  }

  Future<void> _action(String action) async {
    final provider = context.read<StacksProvider>();
    _wsDeliveredStatus = false;
    // Re-establish WS before triggering the action so status updates arrive.
    _wsSub?.cancel();
    await _connectWs();
    await provider.stackAction(widget.stackId, action);
    await _loadStack();
    // Fallback poll: action runs in a background thread server-side;
    // if WS misses the final status update, poll until the stack leaves the busy state.
    for (var i = 0; i < 8 && mounted && !_wsDeliveredStatus; i++) {
      await Future.delayed(const Duration(seconds: 4));
      if (!mounted) break;
      final current = _stack['status'] as String? ?? '';
      if (!['building', 'cloning', 'starting', 'stopping'].contains(current)) break;
      await _loadStack();
    }
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.primarySurface,
        title: const Text('Supprimer ce stack ?',
            style: TextStyle(color: AppColors.textPrimary)),
        content: const Text(
            'Cette action supprimera les containers et les données associées.',
            style: TextStyle(color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Annuler',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            style:
                TextButton.styleFrom(foregroundColor: AppColors.accentRed),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<StacksProvider>().deleteStack(widget.stackId);
      if (mounted) {
        final nav = MainShell.contentNavKey.currentState;
        if (nav != null && nav.canPop()) nav.pop();
      }
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
      return const Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          children: [
            ContentHeader(title: 'Stack'),
            Expanded(
              child: Center(
                child: CircularProgressIndicator(color: AppColors.accent),
              ),
            ),
          ],
        ),
      );
    }

    final name = _stack['name'] as String? ?? 'Stack';
    final status = _stack['status'] as String? ?? 'idle';
    final statusMsg = _stack['status_message'] as String? ?? '';

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          // ── Glass header ─────────────────────────────────────────────
          ContentHeader(
            title: name,
            backLabel: 'GitHub',
            actions: [
              IconButton(
                icon: const Icon(Icons.delete_outline,
                    color: AppColors.accentRed, size: 20),
                tooltip: 'Supprimer',
                onPressed: _confirmDelete,
              ),
            ],
            bottom: TabBar(
              controller: _tabController,
              labelColor: AppColors.accent,
              unselectedLabelColor: AppColors.textMuted,
              indicatorColor: AppColors.accent,
              indicatorWeight: 2,
              dividerColor: GlassTokens.cardBorder,
              isScrollable: true,
              tabs: const [
                Tab(text: 'Déploiement'),
                Tab(text: 'Variables'),
                Tab(text: 'Logs'),
                Tab(text: 'Domaine & SSL'),
                Tab(text: 'CI/CD'),
                Tab(text: 'Console'),
              ],
            ),
          ),
          // ── Status banner ─────────────────────────────────────────────
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
                // CI/CD webhook
                _WebhookTab(stack: _stack),
                // Docker exec console
                _ConsoleTab(stackId: widget.stackId),
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
    'stopping': ('Arrêt en cours…', AppColors.accentYellow),
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
      color: color.withValues(alpha: 0.08),
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
      color: AppColors.accentYellow.withValues(alpha: 0.10),
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
    final isBusy = ['building', 'cloning', 'starting', 'stopping'].contains(status);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ActionBtn(
              icon: Icons.rocket_launch_outlined,
              label: 'Redéployer',
              color: AppColors.accent,
              onTap: isBusy ? null : onDeploy,
            ),
          ),
          const SizedBox(width: 10),
          if (!isRunning)
            Expanded(
              child: _ActionBtn(
                icon: Icons.play_arrow,
                label: 'Démarrer',
                color: AppColors.accentGreen,
                onTap: isBusy ? null : onStart,
              ),
            ),
          if (isRunning)
            Expanded(
              child: _ActionBtn(
                icon: Icons.stop,
                label: 'Arrêter',
                color: AppColors.accentRed,
                onTap: onStop,
              ),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: _ActionBtn(
              icon: Icons.restart_alt,
              label: 'Redémarrer',
              color: AppColors.accentYellow,
              onTap: isBusy ? null : onRestart,
            ),
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
        side: BorderSide(color: color.withValues(alpha: 0.5)),
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

    return SelectionArea(
      child: ListView.builder(
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
      ),
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
  bool _isDetecting = false;

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

  Future<void> _showDetectDialog() async {
    setState(() => _isDetecting = true);
    Map<String, dynamic>? result;
    String? error;
    try {
      result = await _api.detectNginx(widget.stackId);
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => _isDetecting = false);
    }

    if (!mounted) return;

    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Erreur : $error'),
        backgroundColor: AppColors.accentRed,
      ));
      return;
    }

    final suggestions =
        (result?['suggestions'] as List<dynamic>?) ?? [];

    if (suggestions.isEmpty) {
      final files = (result?['nginx_files_found'] as List<dynamic>?) ?? [];
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(files.isEmpty
            ? 'Aucun fichier nginx trouvé dans le repo. Déployez d\'abord.'
            : 'Fichiers nginx trouvés mais aucun VHost détectable.'),
        duration: const Duration(seconds: 5),
      ));
      return;
    }

    final imported = await showDialog<List<Map<String, dynamic>>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _NginxDetectDialog(
        stackId: widget.stackId,
        suggestions: suggestions.cast<Map<String, dynamic>>(),
        nginxFiles: (result?['nginx_files_found'] as List<dynamic>?)
                ?.cast<String>() ??
            [],
      ),
    );

    if (imported != null && imported.isNotEmpty && mounted) {
      setState(() => _vhosts = [...imported, ..._vhosts]);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${imported.length} VHost(s) importé(s).'),
        backgroundColor: AppColors.accent,
      ));
    }
  }

  Future<void> _deleteVhost(int id, String domain) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Supprimer $domain ?',
            style: const TextStyle(color: AppColors.textPrimary)),
        content: const Text(
          'La config NGINX sera supprimée et NGINX rechargé.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Annuler',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
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

  Future<void> _checkDns(int vhostId, String domain) async {
    Map<String, dynamic>? result;
    String? error;
    try {
      result = await _api.checkVhostDns(vhostId);
    } catch (e) {
      error = e.toString();
    }
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Erreur DNS : $error'),
        backgroundColor: AppColors.accentRed,
      ));
      return;
    }
    final propagated = result?['propagated'] == true;
    final serverIp   = result?['server_ip'] as String? ?? '—';
    final resolvedIp = result?['resolved_ip'] as String? ?? 'Non résolu';
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Row(
          children: [
            Icon(
              propagated ? Icons.check_circle : Icons.warning_amber_rounded,
              color: propagated ? AppColors.accentGreen : AppColors.accentYellow,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                propagated ? 'DNS propagé ✓' : 'DNS non encore propagé',
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 15),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(domain,
                style: const TextStyle(
                    color: AppColors.accent,
                    fontWeight: FontWeight.bold,
                    fontSize: 14)),
            const SizedBox(height: 12),
            _DnsIpRow(label: 'IP du serveur',      value: serverIp,   ok: true),
            const SizedBox(height: 4),
            _DnsIpRow(label: 'IP résolue', value: resolvedIp,
                ok: resolvedIp == serverIp),
            if (!propagated) ...[   
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Enregistrement A à créer dans votre zone DNS :',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 12),
                    ),
                    const SizedBox(height: 6),
                    Row(children: [
                      const Icon(Icons.dns_outlined,
                          size: 12, color: AppColors.textMuted),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '$domain   A   $serverIp',
                          style: const TextStyle(
                              color: AppColors.accent,
                              fontSize: 12,
                              fontFamily: 'monospace'),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ]),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Fermer',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
        ],
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

  Future<void> _showPortPicker(Map<String, dynamic> vhost) async {
    final updated = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _ContainerPortSheet(
        stackId: widget.stackId,
        vhost: vhost,
        api: _api,
      ),
    );
    if (updated != null && mounted) {
      setState(() {
        final idx = _vhosts.indexWhere((v) => v['id'] == updated['id']);
        if (idx != -1) _vhosts[idx] = updated;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Port mis à jour → ${updated['upstream_port']}'),
        backgroundColor: AppColors.accentGreen,
        duration: const Duration(seconds: 2),
      ));
    }
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
              if (_isDetecting)
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.accent),
                )
              else
                TextButton.icon(
                  onPressed: _showDetectDialog,
                  icon: const Icon(Icons.auto_awesome, size: 15),
                  label: const Text('Détecter', style: TextStyle(fontSize: 13)),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.accent,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                ),
              const SizedBox(width: 4),
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
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.language_outlined,
                      size: 52, color: AppColors.textSecondary),
                  const SizedBox(height: 12),
                  const Text('Aucun domaine configuré',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 15)),
                  const SizedBox(height: 6),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      'Déployez d\'abord, puis cliquez "Détecter" pour importer\nautomatiquement depuis votre config nginx.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (_isDetecting)
                    const CircularProgressIndicator(color: AppColors.accent)
                  else
                    FilledButton.icon(
                      onPressed: _showDetectDialog,
                      icon: const Icon(Icons.auto_awesome, size: 16),
                      label: const Text('Détecter depuis le repo'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
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
                onCheckDns: () => _checkDns(
                    _vhosts[i]['id'] as int, _vhosts[i]['domain'] as String),
                onEditPort: () => _showPortPicker(_vhosts[i]),
              ),
            ),
          ),
      ],
    );
  }
}

// ─── Nginx auto-detect dialog ─────────────────────────────────────────────────

class _NginxDetectDialog extends StatefulWidget {
  final int stackId;
  final List<Map<String, dynamic>> suggestions;
  final List<String> nginxFiles;

  const _NginxDetectDialog({
    required this.stackId,
    required this.suggestions,
    required this.nginxFiles,
  });

  @override
  State<_NginxDetectDialog> createState() => _NginxDetectDialogState();
}

class _NginxDetectDialogState extends State<_NginxDetectDialog> {
  final _api = ApiService();

  /// Selected indices from suggestions to import
  late final List<bool> _selected;

  /// Editable upstream port for each suggestion
  late final List<TextEditingController> _portControllers;

  bool _isImporting = false;

  @override
  void initState() {
    super.initState();
    _selected = List.generate(
      widget.suggestions.length,
      (i) => widget.suggestions[i]['auto_create'] == true,
    );
    _portControllers = widget.suggestions.map((s) {
      return TextEditingController(
        text: (s['upstream_port'] ?? '').toString(),
      );
    }).toList();
  }

  @override
  void dispose() {
    for (final c in _portControllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _importSelected() async {
    setState(() => _isImporting = true);
    final imported = <Map<String, dynamic>>[];

    for (var i = 0; i < widget.suggestions.length; i++) {
      if (!_selected[i]) continue;
      final s = widget.suggestions[i];
      final port = int.tryParse(_portControllers[i].text.trim()) ?? 0;
      if (port <= 0) continue;

      if (s['already_exists'] == true) {
        // Update port only
        try {
          final updated = await _api.updateVhost(
            s['vhost_id'] as int? ?? -1,
            {'upstream_port': port},
          );
          imported.add(updated);
        } catch (_) {}
        continue;
      }

      try {
        final created = await _api.createVhost({
          'stack':           widget.stackId,
          'domain':          s['domain'],
          'upstream_port':   port,
          'service_label':   s['service_label'] ?? '',
          'container_name':  s['container_name'] ?? '',
          'ssl_enabled':     false,
          'route_overrides': s['route_overrides'] ?? [],
          'include_www':     s['include_www'] ?? false,
        });
        imported.add(created);
      } catch (_) {}
    }

    if (mounted) {
      setState(() => _isImporting = false);
      Navigator.of(context).pop(imported);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canImport = _selected.any((v) => v) && !_isImporting;

    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Row(
        children: [
          Icon(Icons.auto_awesome, color: AppColors.accent, size: 20),
          SizedBox(width: 8),
          Text('VHosts détectés',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.nginxFiles.isNotEmpty) ...[
              Text(
                'Config trouvée dans : ${widget.nginxFiles.join(', ')}',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 11),
              ),
              const SizedBox(height: 12),
            ],
            const Text(
              'Sélectionnez les domaines à importer :',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 340),
              child: SingleChildScrollView(
                child: Column(
                  children: List.generate(widget.suggestions.length, (i) {
                    final s = widget.suggestions[i];
                    final domain = s['domain'] as String? ?? '';
                    final svc = s['service_label'] as String? ?? '';
                    final alreadyExists = s['already_exists'] == true;
                    final noPort = (s['upstream_port'] == null);
                    final routeCount = (s['route_overrides'] as List?)?.length ?? 0;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _selected[i]
                              ? AppColors.accent.withValues(alpha: 0.5)
                              : AppColors.border,
                        ),
                      ),
                      child: CheckboxListTile(
                        value: _selected[i],
                        activeColor: AppColors.accent,
                        onChanged: _isImporting
                            ? null
                            : (v) => setState(() => _selected[i] = v ?? false),
                        title: Text(domain,
                            style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (svc.isNotEmpty)
                              Text('Service : $svc',
                                  style: const TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 11)),
                            if (alreadyExists)
                              const Text('Déjà configuré — met à jour le port',
                                  style: TextStyle(
                                      color: AppColors.accentYellow,
                                      fontSize: 11)),
                            if (noPort)
                              const Text(
                                  'Port inconnu — conteneur non démarré ?',
                                  style: TextStyle(
                                      color: AppColors.accentRed,
                                      fontSize: 11)),
                    if (routeCount > 1)
                              Text(
                                '$routeCount routes détectées (multi-service)',
                                style: const TextStyle(
                                    color: AppColors.accent,
                                    fontSize: 11)),
                            if (s['include_www'] == true)
                              const Text(
                                'Redirection www détectée',
                                style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 11)),
                            if (_selected[i]) ...[
                              const SizedBox(height: 6),
                              SizedBox(
                                height: 34,
                                child: TextField(
                                  controller: _portControllers[i],
                                  enabled: !_isImporting,
                                  keyboardType: TextInputType.number,
                                  style: const TextStyle(
                                      color: AppColors.textPrimary,
                                      fontSize: 12),
                                  decoration: InputDecoration(
                                    labelText: 'Port upstream',
                                    labelStyle: const TextStyle(
                                        color: AppColors.textSecondary,
                                        fontSize: 11),
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(6),
                                      borderSide: const BorderSide(
                                          color: AppColors.border),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(6),
                                      borderSide: const BorderSide(
                                          color: AppColors.border),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      ),
                    );
                  }),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _isImporting ? null : () => Navigator.of(context).pop(null),
          child: const Text('Annuler',
              style: TextStyle(color: AppColors.textSecondary)),
        ),
        FilledButton.icon(
          onPressed: canImport ? _importSelected : null,
          icon: _isImporting
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child:
                      CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.download, size: 16),
          label: const Text('Importer'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accent,
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
  final VoidCallback onCheckDns;
  final VoidCallback onEditPort;

  const _VhostCard({
    required this.vhost,
    required this.onDelete,
    required this.onActivateSsl,
    required this.onRefreshCert,
    required this.onCheckDns,
    required this.onEditPort,
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
    final routes       = (vhost['route_overrides'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final includeWww   = vhost['include_www'] as bool? ?? false;

    // Parse expiry if set
    DateTime? expiry;
    if (expiresAt != null) {
      try { expiry = DateTime.parse(expiresAt); } catch (_) {}
    }
    final days = daysLeft ?? (expiry?.difference(DateTime.now()).inDays);

    Color expiryColor = AppColors.accentGreen;
    if (days != null) {
      if (days < 0) {
        expiryColor = AppColors.accentRed;
      } else if (days < 7) {
        expiryColor = AppColors.accentRed;
      } else if (days < 30) {
        expiryColor = AppColors.accentYellow;
      }
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
              InkWell(
                onTap: onEditPort,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.only(right: 6, top: 2, bottom: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.settings_ethernet,
                          size: 14, color: AppColors.textSecondary),
                      const SizedBox(width: 4),
                      Text(
                        'Port : $port',
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 12),
                      ),
                      const SizedBox(width: 3),
                      const Icon(Icons.edit_outlined,
                          size: 11, color: AppColors.textMuted),
                    ],
                  ),
                ),
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
              if (routes.length > 1) ...[          
                const SizedBox(width: 12),
                const Icon(Icons.route, size: 13, color: AppColors.textMuted),
                const SizedBox(width: 3),
                Text(
                  '${routes.length} routes',
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 11),
                ),
              ],
              if (includeWww) ...[
                const SizedBox(width: 12),
                const Icon(Icons.language, size: 13, color: AppColors.textMuted),
                const SizedBox(width: 3),
                const Text('www', style: TextStyle(color: AppColors.textMuted, fontSize: 11)),
              ],
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
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.refresh,
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
              // DNS check
              OutlinedButton.icon(
                onPressed: onCheckDns,
                icon: const Icon(Icons.dns_outlined, size: 13),
                label: const Text('DNS', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                  side: const BorderSide(color: AppColors.border, width: 1),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(width: 8),
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
          color: AppColors.accent.withValues(alpha: 0.12),
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
  bool   _manualMode  = false;
  bool   _isSaving    = false;
  bool   _includeWww  = false;
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
        'include_www':    _includeWww,
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
                Row(
                  children: [
                    const Text('Container',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 12)),
                    const Spacer(),
                    InkWell(
                      onTap: () {
                        setState(() => _loadingContainers = true);
                        _loadContainers();
                      },
                      borderRadius: BorderRadius.circular(4),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.refresh,
                                size: 14, color: AppColors.textSecondary),
                            SizedBox(width: 3),
                            Text('Rafraîchir',
                                style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 11)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
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
              const SizedBox(height: 6),
              // www redirect toggle
              SwitchListTile(
                value: _includeWww,
                onChanged: (v) => setState(() => _includeWww = v),
                title: const Text('Rediriger www.domaine → domaine',
                    style: TextStyle(
                        color: AppColors.textPrimary, fontSize: 13)),
                subtitle: const Text(
                    'Ajoute un bloc nginx www + inclut www dans le cert SSL',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 11)),
                activeThumbColor: AppColors.accent,
                contentPadding: EdgeInsets.zero,
                dense: true,
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
      initialValue: _selectedContainerIdx ?? -1,
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
      initialValue: currentHostPort,
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

// ─── SSL Activation bottom sheet (with live DNS checker) ─────────────────────

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

  // Stages: 'dns_check' → 'ready' → 'running' → 'done'|'error'
  String _stage = 'dns_check';

  // DNS check state
  Map<String, dynamic>? _dnsResult;
  bool _checkingDns = false;
  Timer? _pollTimer;
  int _pollCount = 0;
  static const _maxPolls = 40; // 40 × 15s = 10 min max auto-polling

  // Certbot
  String? _output;
  String? _error;

  @override
  void initState() {
    super.initState();
    _emailCtrl.text = (widget.vhost['ssl_email'] as String?) ?? '';
    final sslEnabled = widget.vhost['ssl_enabled'] as bool? ?? false;
    if (sslEnabled) {
      // If already has SSL, skip DNS check stage — go straight to re-run
      _stage = 'ready';
    } else {
      _runDnsCheck();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _runDnsCheck() async {
    if (!mounted) return;
    setState(() => _checkingDns = true);
    try {
      final result = await _api.checkVhostDns(widget.vhost['id'] as int);
      if (!mounted) return;
      setState(() {
        _dnsResult = result;
        _checkingDns = false;
        if (result['propagated'] == true) {
          _stage = 'ready';
          _pollTimer?.cancel();
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _checkingDns = false);
    }
  }

  void _startAutoPoll() {
    _pollTimer?.cancel();
    _pollCount = 0;
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      _pollCount++;
      if (_pollCount > _maxPolls) {
        _pollTimer?.cancel();
        return;
      }
      await _runDnsCheck();
      if (_stage == 'ready') _pollTimer?.cancel();
    });
  }

  Future<void> _runCertbot() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Un email est requis pour Certbot.');
      return;
    }
    setState(() {
      _stage = 'running';
      _error = null;
      _output = null;
    });
    try {
      final updated = await _api.runCertbot(
          widget.vhost['id'] as int, email);
      if (!mounted) return;
      setState(() {
        _output = updated['certbot_output'] as String? ?? 'Succès.';
        _stage = 'done';
      });
      widget.onSuccess(updated);
    } on CertbotException catch (e) {
      if (!mounted) return;
      final detail = [e.toString(), if (e.output.isNotEmpty) e.output].join('\n\n');
      setState(() {
        _error = detail;
        _stage = 'ready';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _stage = 'ready';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final domain = widget.vhost['domain'] as String? ?? '';
    final sslEnabled = widget.vhost['ssl_enabled'] as bool? ?? false;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
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
              Expanded(
                child: Text(
                  sslEnabled ? 'Renouveler SSL — $domain' : 'Activer SSL — $domain',
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 16),
                ),
              ),
            ]),
            const SizedBox(height: 20),
            // DNS check step (skip for renewals)
            if (!sslEnabled) ...[
              _buildDnsStep(domain),
              const SizedBox(height: 20),
            ],
            // Email + Certbot step
            _buildCertbotStep(sslEnabled),
          ],
        ),
      ),
    );
  }

  Widget _buildDnsStep(String domain) {
    final propagated = _dnsResult?['propagated'] == true;
    final serverIp = _dnsResult?['server_ip'] as String?;
    final resolvedIp = _dnsResult?['resolved_ip'] as String?;

    final Color stepColor;
    final IconData stepIcon;
    final String stepTitle;

    if (_stage == 'ready' || propagated) {
      stepColor = AppColors.accentGreen;
      stepIcon = Icons.check_circle;
      stepTitle = 'DNS propagé ✓';
    } else if (_checkingDns) {
      stepColor = AppColors.accentYellow;
      stepIcon = Icons.pending;
      stepTitle = 'Vérification DNS en cours…';
    } else {
      stepColor = AppColors.accentYellow;
      stepIcon = Icons.warning_amber_rounded;
      stepTitle = 'En attente de propagation DNS';
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: stepColor.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: stepColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(stepIcon, size: 16, color: stepColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text('1. $stepTitle',
                    style: TextStyle(
                        color: stepColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
              ),
              if (_checkingDns)
                const SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.accentYellow),
                ),
            ],
          ),
          if (serverIp != null || resolvedIp != null) ...[
            const SizedBox(height: 10),
            _DnsIpRow(
              label: 'IP du serveur',
              value: serverIp ?? '—',
              ok: serverIp != null,
            ),
            const SizedBox(height: 4),
            _DnsIpRow(
              label: 'IP résolue ($domain)',
              value: resolvedIp ?? 'Non résolu',
              ok: resolvedIp != null && resolvedIp == serverIp,
            ),
          ],
          if (!propagated && !_checkingDns && _dnsResult != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Ajoutez cet enregistrement A dans votre zone DNS :',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  Row(children: [
                    const Icon(Icons.dns_outlined,
                        size: 12, color: AppColors.textMuted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '$domain   A   ${serverIp ?? '<votre IP>'}',
                        style: const TextStyle(
                            color: AppColors.accent,
                            fontSize: 12,
                            fontFamily: 'monospace'),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _checkingDns ? null : () {
                  _pollTimer?.cancel();
                  _runDnsCheck();
                },
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text('Revérifier', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: stepColor,
                  side: BorderSide(color: stepColor.withValues(alpha: 0.5)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: 10),
              if (!propagated)
                OutlinedButton.icon(
                  onPressed: () { _startAutoPoll(); setState(() {}); },
                  icon: const Icon(Icons.autorenew, size: 14),
                  label: Text(
                    _pollTimer?.isActive == true
                        ? 'Polling… ($_pollCount/$_maxPolls)'
                        : 'Auto (toutes 15s)',
                    style: const TextStyle(fontSize: 12),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: const BorderSide(color: AppColors.border),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCertbotStep(bool isRenewal) {
    final canRun = isRenewal || _stage == 'ready';
    final isDone = _stage == 'done';
    final isRunning = _stage == 'running';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(isRenewal ? 'Email pour Certbot' : '2. Email + Certbot'),
        const SizedBox(height: 8),
        _Field(
          ctrl: _emailCtrl,
          label: 'Adresse email (notifications Let\'s Encrypt)',
          keyboardType: TextInputType.emailAddress,
        ),
        if (!canRun && !isRenewal) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.accentYellow.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: AppColors.accentYellow.withValues(alpha: 0.25)),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline,
                    size: 14, color: AppColors.accentYellow),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'En attente de la propagation DNS avant de lancer Certbot.',
                    style: TextStyle(
                        color: AppColors.accentYellow, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: (canRun && !isRunning && !isDone) ? _runCertbot : null,
            icon: isRunning
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : isDone
                    ? const Icon(Icons.check_circle_outline)
                    : const Icon(Icons.verified_user_outlined),
            label: Text(isRunning
                ? 'Certbot en cours…'
                : isDone
                    ? 'SSL activé !'
                    : (isRenewal
                        ? 'Renouveler le certificat'
                        : 'Lancer Certbot')),
            style: FilledButton.styleFrom(
              backgroundColor: isDone
                  ? AppColors.accentGreen
                  : canRun
                      ? AppColors.accentGreen
                      : AppColors.border,
              padding: const EdgeInsets.symmetric(vertical: 13),
              textStyle: const TextStyle(fontSize: 15),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.accentRed.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: AppColors.accentRed.withValues(alpha: 0.3)),
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
              color: AppColors.accentGreen.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: AppColors.accentGreen.withValues(alpha: 0.3)),
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
    );
  }
}

// ─── DNS IP row helper ────────────────────────────────────────────────────────

class _DnsIpRow extends StatelessWidget {
  final String label;
  final String value;
  final bool ok;

  const _DnsIpRow({required this.label, required this.value, required this.ok});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.cancel,
            size: 12,
            color: ok ? AppColors.accentGreen : AppColors.accentRed,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 11),
                children: [
                  TextSpan(
                    text: '$label: ',
                    style: const TextStyle(color: AppColors.textMuted),
                  ),
                  TextSpan(
                    text: value,
                    style: TextStyle(
                      color: ok
                          ? AppColors.accentGreen
                          : AppColors.textSecondary,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
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

// ─── Webhook / CI·CD tab ─────────────────────────────────────────────────────

class _WebhookTab extends StatelessWidget {
  final Map<String, dynamic> stack;

  const _WebhookTab({required this.stack});

  @override
  Widget build(BuildContext context) {
    final token = stack['webhook_token'] as String? ?? '';
    final stackId = stack['id']?.toString() ?? '';

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // ── Header ─────────────────────────────────────────────────────
        const Row(
          children: [
            Icon(Icons.webhook_outlined, color: AppColors.accent, size: 20),
            SizedBox(width: 8),
            Text(
              'Déploiement automatique (CI/CD)',
              style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Ajoutez ces secrets dans votre dépôt GitHub '
          '(Settings → Secrets → Actions) pour déclencher '
          'un redéploiement automatique à chaque push sur main.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 24),

        // ── Secrets list ───────────────────────────────────────────────
        _SecretRow(
          name: 'ONDES_STACK_ID',
          value: stackId,
          hint: 'ID numérique de ce stack',
        ),
        const SizedBox(height: 12),
        _SecretRow(
          name: 'ONDES_WEBHOOK_TOKEN',
          value: token,
          hint: 'Token secret — ne le partagez pas',
          isSecret: true,
        ),
        const SizedBox(height: 12),
        const _SecretRow(
          name: 'ONDES_API_URL',
          value: 'https://votre-serveur.com',
          hint: 'URL racine de votre instance Ondes HOST',
          readOnly: true,
        ),

        const SizedBox(height: 32),

        // ── GitHub Action snippet ──────────────────────────────────────
        const Text(
          'Workflow GitHub Actions (.github/workflows/deploy.yml) :',
          style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  _buildWorkflowSnippet(stackId),
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: AppColors.textSecondary),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy_outlined,
                    size: 18, color: AppColors.textSecondary),
                tooltip: 'Copier',
                onPressed: () {
                  Clipboard.setData(
                      ClipboardData(text: _buildWorkflowSnippet(stackId)));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Workflow copié !'),
                        duration: Duration(seconds: 2)),
                  );
                },
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.accentYellow.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: AppColors.accentYellow.withValues(alpha: 0.3)),
          ),
          child: const Row(
            children: [
              Icon(Icons.info_outline,
                  color: AppColors.accentYellow, size: 16),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Le webhook ne nécessite pas de JWT. '
                  'Gardez le token secret — il donne accès au redéploiement.',
                  style: TextStyle(
                      color: AppColors.accentYellow, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _buildWorkflowSnippet(String stackId) => '''name: Deploy to Ondes HOST
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Trigger redeploy
        run: |
          curl -sf -X POST \\
            -H "Authorization: Bearer \${{ secrets.ONDES_WEBHOOK_TOKEN }}" \\
            "\${{ secrets.ONDES_API_URL }}/api/stacks/$stackId/webhook/"''';
}

// ─── Secret row widget ───────────────────────────────────────────────────────

class _SecretRow extends StatefulWidget {
  final String name;
  final String value;
  final String hint;
  final bool isSecret;
  final bool readOnly;

  const _SecretRow({
    required this.name,
    required this.value,
    required this.hint,
    this.isSecret = false,
    this.readOnly = false,
  });

  @override
  State<_SecretRow> createState() => _SecretRowState();
}

class _SecretRowState extends State<_SecretRow> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    final displayValue =
        widget.isSecret && !_visible ? '••••••••••••••••' : widget.value;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  widget.name,
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: AppColors.accent,
                      fontWeight: FontWeight.w600),
                ),
              ),
              const Spacer(),
              if (widget.isSecret)
                IconButton(
                  icon: Icon(
                      _visible ? Icons.visibility_off : Icons.visibility,
                      size: 16,
                      color: AppColors.textSecondary),
                  onPressed: () => setState(() => _visible = !_visible),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              if (!widget.readOnly)
                IconButton(
                  icon: const Icon(Icons.copy_outlined,
                      size: 16, color: AppColors.textSecondary),
                  tooltip: 'Copier',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: widget.value));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text('${widget.name} copié !'),
                          duration: const Duration(seconds: 2)),
                    );
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            displayValue.isEmpty ? '(non disponible)' : displayValue,
            style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: AppColors.textPrimary),
            overflow: TextOverflow.ellipsis,
          ),
          if (widget.hint.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              widget.hint,
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Bottom‑sheet : choisir le container/port d'un vhost en temps réel
// ──────────────────────────────────────────────────────────────────────────────

class _ContainerPortSheet extends StatefulWidget {
  final int stackId;
  final Map<String, dynamic> vhost;
  final ApiService api;

  const _ContainerPortSheet({
    required this.stackId,
    required this.vhost,
    required this.api,
  });

  @override
  State<_ContainerPortSheet> createState() => _ContainerPortSheetState();
}

class _ContainerPortSheetState extends State<_ContainerPortSheet> {
  List<Map<String, dynamic>> _containers = [];
  bool _loading = true;
  String? _error;
  String? _selectedId; // "containerName:port"

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.api.getStackContainers(widget.stackId);
      if (!mounted) return;
      setState(() {
        _containers = List<Map<String, dynamic>>.from(list);
        _loading = false;
        final currentPort = widget.vhost['upstream_port']?.toString();
        final currentName = widget.vhost['container_name']?.toString();
        for (final c in _containers) {
          final ports = (c['ports'] as List?)
              ?.map((p) => (p as Map<String, dynamic>)['host_port']?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList() ?? <String>[];
          for (final p in ports) {
            if (p == currentPort && c['name'] == currentName) {
              _selectedId = '${c['name']}:$p';
              break;
            }
          }
          if (_selectedId != null) break;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _selectPort(String containerName, String port, String serviceLabel) async {
    final vhostId = widget.vhost['id'] as int;
    try {
      final updated = await widget.api.updateVhost(vhostId, {
        'upstream_port': int.tryParse(port) ?? port,
        'container_name': containerName,
        'service_label': serviceLabel,
      });
      if (mounted) Navigator.of(context).pop(updated);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Erreur : $e'),
        backgroundColor: Colors.red,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      maxChildSize: 0.9,
      minChildSize: 0.3,
      builder: (_, sc) => Column(
        children: [
          // Handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textSecondary.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.cable_outlined, size: 16, color: AppColors.textSecondary),
                const SizedBox(width: 6),
                const Text(
                  'Sélectionner container/port',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18, color: AppColors.textSecondary),
                  tooltip: 'Rafraîchir',
                  onPressed: _load,
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!,
                                style: const TextStyle(color: Colors.red, fontSize: 12)),
                            const SizedBox(height: 8),
                            ElevatedButton.icon(
                              onPressed: _load,
                              icon: const Icon(Icons.refresh, size: 14),
                              label: const Text('Réessayer'),
                            ),
                          ],
                        ),
                      )
                    : _containers.isEmpty
                        ? const Center(
                            child: Text('Aucun container actif',
                                style: TextStyle(color: AppColors.textSecondary)),
                          )
                        : ListView.builder(
                            controller: sc,
                            itemCount: _containers.length,
                            itemBuilder: (_, i) {
                              final c = _containers[i];
                              final ports = (c['ports'] as List?)
                                  ?.map((p) => (p as Map<String, dynamic>)['host_port']?.toString() ?? '')
                                  .where((s) => s.isNotEmpty)
                                  .toList() ?? <String>[];
                              return _ContainerPortTile(
                                container: c,
                                ports: ports,
                                selectedId: _selectedId,
                                onSelect: (port) {
                                  setState(() => _selectedId = '${c['name']}:$port');
                                  _selectPort(
                                    c['name'] as String,
                                    port,
                                    (c['service'] ?? c['name']) as String,
                                  );
                                },
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}

class _ContainerPortTile extends StatelessWidget {
  final Map<String, dynamic> container;
  final List<String> ports;
  final String? selectedId;
  final void Function(String port) onSelect;

  const _ContainerPortTile({
    required this.container,
    required this.ports,
    required this.selectedId,
    required this.onSelect,
  });

  Color _statusColor(String? status) {
    if (status == null) return Colors.grey;
    final s = status.toLowerCase();
    if (s == 'running') return AppColors.accentGreen;
    if (s == 'exited' || s == 'dead') return Colors.red;
    return Colors.orange;
  }

  @override
  Widget build(BuildContext context) {
    final name = container['name'] as String? ?? '?';
    final service = container['service'] as String? ?? name;
    final status = container['status'] as String?;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _statusColor(status),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  service,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13),
                ),
              ),
              Text(
                status ?? '',
                style: TextStyle(
                    color: _statusColor(status), fontSize: 11),
              ),
            ],
          ),
        ),
        if (ports.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(30, 0, 16, 8),
            child: Text('Aucun port exposé',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          )
        else
          ...ports.map((port) {
            final id = '$name:$port';
            final selected = id == selectedId;
            return InkWell(
              onTap: () => onSelect(port),
              child: Container(
                padding: const EdgeInsets.fromLTRB(30, 6, 16, 6),
                color: selected
                    ? AppColors.accentGreen.withValues(alpha: 0.12)
                    : Colors.transparent,
                child: Row(
                  children: [
                    Icon(
                      selected ? Icons.radio_button_checked : Icons.radio_button_off,
                      size: 14,
                      color: selected ? AppColors.accentGreen : AppColors.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Port $port',
                      style: TextStyle(
                        color: selected
                            ? AppColors.accentGreen
                            : AppColors.textPrimary,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.normal,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        const Divider(height: 1, color: AppColors.border),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Console tab — interactive docker exec shell
// ─────────────────────────────────────────────────────────────────────────────

class _ConsoleTab extends StatefulWidget {
  final int stackId;
  const _ConsoleTab({required this.stackId});

  @override
  State<_ConsoleTab> createState() => _ConsoleTabState();
}

class _ConsoleTabState extends State<_ConsoleTab> {
  final _api        = ApiService();
  final _ws         = WebSocketService();
  final _inputCtrl  = TextEditingController();
  final _scrollCtrl = ScrollController();

  List<Map<String, dynamic>> _containers = [];
  bool   _loadingContainers = true;
  String? _selectedContainerId;
  bool   _connected  = false;
  bool   _connecting = false;
  final List<String> _lines = [];

  @override
  void initState() {
    super.initState();
    _loadContainers();
  }

  @override
  void dispose() {
    _ws.disconnect();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadContainers() async {
    setState(() => _loadingContainers = true);
    try {
      final list = await _api.getStackContainers(widget.stackId);
      if (!mounted) return;
      setState(() {
        _containers        = List<Map<String, dynamic>>.from(list);
        _loadingContainers = false;
        if (_containers.isNotEmpty && _selectedContainerId == null) {
          _selectedContainerId = _containers.first['id'] as String?;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _loadingContainers = false);
    }
  }

  Future<void> _connect() async {
    if (_selectedContainerId == null) return;
    setState(() { _connecting = true; _lines.clear(); });
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token') ?? '';
    try {
      _ws.connect('/ws/exec/$_selectedContainerId/?token=$token');
      _ws.stream?.listen(
        (event) {
          if (!mounted) return;
          final data = jsonDecode(event as String) as Map<String, dynamic>;
          switch (data['type']) {
            case 'connected':
              setState(() { _connected = true; _connecting = false; });
              _addOutput(data['message'] as String? ?? 'Connecté');
            case 'output':
              _addOutput(data['data'] as String? ?? '');
            case 'error':
              setState(() { _connected = false; _connecting = false; });
              _addOutput('✗ ${data['message']}');
          }
        },
        onDone: () {
          if (mounted) setState(() => _connected = false);
          _addOutput('\r\nSession fermée.');
        },
        onError: (e) {
          if (mounted) setState(() { _connected = false; _connecting = false; });
          _addOutput('Erreur WebSocket : $e');
        },
      );
    } catch (e) {
      setState(() => _connecting = false);
      _addOutput('Impossible d\'ouvrir la connexion : $e');
    }
  }

  void _disconnect() {
    _ws.disconnect();
    setState(() => _connected = false);
    _addOutput('Déconnecté.');
  }

  void _sendInput() {
    final text = _inputCtrl.text;
    if (text.isEmpty || !_connected) return;
    _ws.send({'type': 'input', 'data': '$text\n'});
    _inputCtrl.clear();
  }

  void _addOutput(String text) {
    if (!mounted) return;
    setState(() {
      _lines.addAll(text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n'));
      if (_lines.length > 2000) _lines.removeRange(0, _lines.length - 2000);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 80),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Toolbar ──────────────────────────────────────────────────────
          Row(
            children: [
              const Icon(Icons.terminal, color: AppColors.accent, size: 18),
              const SizedBox(width: 8),
              const Text('Console container',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              if (_loadingContainers)
                const SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.accent),
                )
              else
                IconButton(
                  icon: const Icon(Icons.refresh,
                      size: 16, color: AppColors.textSecondary),
                  tooltip: 'Rafraîchir les containers',
                  onPressed: _loadContainers,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
            ],
          ),
          const SizedBox(height: 10),
          // ── Container picker + connect button ────────────────────────────
          if (!_loadingContainers)
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedContainerId,
                    items: _containers.map((c) {
                      final id      = c['id'] as String? ?? '';
                      final service = c['service'] as String? ?? c['name'] as String? ?? id;
                      final status  = c['status'] as String? ?? '';
                      return DropdownMenuItem<String>(
                        value: id,
                        child: Row(children: [
                          Icon(Icons.circle,
                              size: 8,
                              color: status == 'running'
                                  ? AppColors.accentGreen
                                  : AppColors.textMuted),
                          const SizedBox(width: 6),
                          Text(service,
                              style: const TextStyle(
                                  color: AppColors.textPrimary, fontSize: 13)),
                        ]),
                      );
                    }).toList(),
                    onChanged: _connected
                        ? null
                        : (v) {
                            if (v == null) return;
                            setState(() {
                              _selectedContainerId = v;
                            });
                          },
                    dropdownColor: AppColors.surface,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide:
                              const BorderSide(color: AppColors.border)),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide:
                              const BorderSide(color: AppColors.border)),
                    ),
                    hint: const Text('Sélectionner un container',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 13)),
                  ),
                ),
                const SizedBox(width: 10),
                if (!_connected)
                  FilledButton.icon(
                    onPressed: (_connecting || _selectedContainerId == null)
                        ? null
                        : _connect,
                    icon: _connecting
                        ? const SizedBox(
                            width: 14, height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.play_arrow, size: 16),
                    label: const Text('Connecter'),
                    style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accent),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: _disconnect,
                    icon: const Icon(Icons.stop, size: 16),
                    label: const Text('Déconnecter'),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.accentRed,
                        side: const BorderSide(color: AppColors.accentRed)),
                  ),
              ],
            ),
          const SizedBox(height: 12),
          // ── Terminal output ──────────────────────────────────────────────
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.border),
              ),
              padding: const EdgeInsets.all(12),
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
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                  if (_connected) ...[
                    const Divider(color: AppColors.border, height: 10),
                    Row(
                      children: [
                        Text('\$ ',
                            style: GoogleFonts.jetBrainsMono(
                                color: const Color(0xFF22C55E), fontSize: 13)),
                        Expanded(
                          child: TextField(
                            controller: _inputCtrl,
                            onSubmitted: (_) => _sendInput(),
                            style: GoogleFonts.jetBrainsMono(
                                color: Colors.white, fontSize: 13),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              isDense: true,
                              filled: false,
                            ),
                            autofocus: true,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.send,
                              size: 16, color: AppColors.accent),
                          onPressed: _sendInput,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
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
    );
  }
}
