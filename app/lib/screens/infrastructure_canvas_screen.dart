import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../theme/app_theme.dart';

// ─── Data models ─────────────────────────────────────────────────────────────

class _ContainerNode {
  final String id;
  final String name;
  final String image;
  final String status;
  final double cpuPct;
  final double memPct;
  final double memMb;
  final Map<String, dynamic> labels;

  const _ContainerNode({
    required this.id,
    required this.name,
    required this.image,
    required this.status,
    required this.cpuPct,
    required this.memPct,
    required this.memMb,
    required this.labels,
  });

  factory _ContainerNode.fromJson(Map<String, dynamic> j) => _ContainerNode(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        image: j['image'] as String? ?? '',
        status: j['status'] as String? ?? 'unknown',
        cpuPct: (j['cpu_pct'] as num?)?.toDouble() ?? 0,
        memPct: (j['mem_pct'] as num?)?.toDouble() ?? 0,
        memMb: (j['mem_mb'] as num?)?.toDouble() ?? 0,
        labels: Map<String, dynamic>.from(j['labels'] as Map? ?? {}),
      );

  // Derive which stack this belongs to via compose label
  String get composeProject =>
      labels['com.docker.compose.project'] as String? ?? '';
  String get composeService =>
      labels['com.docker.compose.service'] as String? ?? '';

  _ContainerNode copyWith({double? cpuPct, double? memPct, double? memMb}) =>
      _ContainerNode(
        id: id,
        name: name,
        image: image,
        status: status,
        cpuPct: cpuPct ?? this.cpuPct,
        memPct: memPct ?? this.memPct,
        memMb: memMb ?? this.memMb,
        labels: labels,
      );
}

// ─── Main screen ─────────────────────────────────────────────────────────────

class InfrastructureCanvasScreen extends StatefulWidget {
  const InfrastructureCanvasScreen({super.key});

  @override
  State<InfrastructureCanvasScreen> createState() =>
      _InfrastructureCanvasScreenState();
}

class _InfrastructureCanvasScreenState
    extends State<InfrastructureCanvasScreen>
    with TickerProviderStateMixin {
  final _ws = WebSocketService();
  StreamSubscription? _wsSub;

  // Metrics data from WS
  List<_ContainerNode> _containers = [];
  bool _wsConnected = false;

  // Selected node for side panel
  _ContainerNode? _selectedNode;

  // Stack data for grouping
  List<dynamic> _stacks = [];

  // Canvas pan/zoom
  final _transformController = TransformationController();

  // Node positions (auto-laid out on first render)
  final Map<String, Offset> _positions = {};
  bool _laid = false;

  final _api = ApiService();

  @override
  void initState() {
    super.initState();
    _loadStacks();
    _connectMetrics();
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _ws.disconnect();
    _transformController.dispose();
    super.dispose();
  }

  Future<void> _loadStacks() async {
    try {
      final s = await _api.listStacks();
      if (mounted) setState(() => _stacks = s);
    } catch (_) {}
  }

  Future<void> _connectMetrics() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token') ?? '';
    _ws.connect('/ws/metrics/?token=$token');
    _wsSub = _ws.stream?.listen((raw) {
      if (!mounted) return;
      try {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        if (msg['type'] == 'metrics') {
          final list = (msg['containers'] as List? ?? [])
              .cast<Map<String, dynamic>>()
              .map(_ContainerNode.fromJson)
              .toList();
          setState(() {
            _wsConnected = true;
            _containers = list;
            // Update selected node live
            if (_selectedNode != null) {
              final updated = list
                  .where((c) => c.id == _selectedNode!.id)
                  .firstOrNull;
              if (updated != null) _selectedNode = updated;
            }
          });
        }
      } catch (_) {}
    });
  }

  // Auto-layout: pack nodes in a loose grid, grouping by compose project
  void _computePositions(Size size) {
    if (_laid && _positions.length == _containers.length) return;
    _laid = true;

    // Group by compose project
    final groups = <String, List<_ContainerNode>>{};
    for (final c in _containers) {
      final key = c.composeProject.isEmpty ? '__standalone' : c.composeProject;
      groups.putIfAbsent(key, () => []).add(c);
    }

    double groupX = 80;
    double groupY = 80;
    const nodeW = 180.0;
    const nodeH = 110.0;
    const gapX = 40.0;
    const gapY = 80.0;

    for (final entry in groups.entries) {
      final nodes = entry.value;
      double rowX = groupX;
      double rowY = groupY + 40; // leave room for group label
      int col = 0;
      for (final n in nodes) {
        if (!_positions.containsKey(n.id)) {
          _positions[n.id] = Offset(rowX, rowY);
        }
        rowX += nodeW + gapX;
        col++;
        if (col % 4 == 0) {
          rowX = groupX;
          rowY += nodeH + gapY;
        }
      }
      // Next group below
      groupY = rowY + nodeH + 80;
      groupX = 80;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          _CanvasHeader(
            wsConnected: _wsConnected,
            containerCount: _containers.length,
            runningCount:
                _containers.where((c) => c.status == 'running').length,
            onRefresh: _loadStacks,
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildCanvas()),
                if (_selectedNode != null) _NodeDetailPanel(
                  node: _selectedNode!,
                  onClose: () => setState(() => _selectedNode = null),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvas() {
    if (!_wsConnected && _containers.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 36,
              height: 36,
              child:
                  CircularProgressIndicator(color: AppColors.accent, strokeWidth: 2),
            ),
            SizedBox(height: 16),
            Text('Connexion au flux de métriques…',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
            SizedBox(height: 6),
            Text('Les données arrivent en temps réel via WebSocket.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
          ],
        ),
      );
    }

    if (_wsConnected && _containers.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 56, color: AppColors.textSecondary),
            SizedBox(height: 12),
            Text('Aucun container en cours',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 15)),
            SizedBox(height: 6),
            Text('Déployez un stack ou démarrez des containers.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _computePositions(constraints.biggest);
        return InteractiveViewer(
          transformationController: _transformController,
          boundaryMargin: const EdgeInsets.all(400),
          minScale: 0.3,
          maxScale: 2.5,
          child: _CanvasContent(
            containers: _containers,
            stacks: _stacks,
            positions: _positions,
            selectedId: _selectedNode?.id,
            onNodeTap: (node) => setState(() {
              _selectedNode = _selectedNode?.id == node.id ? null : node;
            }),
            onNodeMove: (id, offset) {
              setState(() => _positions[id] = offset);
            },
          ),
        );
      },
    );
  }
}

// ─── Canvas content (CustomPaint + positioned nodes) ─────────────────────────

class _CanvasContent extends StatelessWidget {
  final List<_ContainerNode> containers;
  final List<dynamic> stacks;
  final Map<String, Offset> positions;
  final String? selectedId;
  final void Function(_ContainerNode) onNodeTap;
  final void Function(String id, Offset offset) onNodeMove;

  const _CanvasContent({
    required this.containers,
    required this.stacks,
    required this.positions,
    required this.selectedId,
    required this.onNodeTap,
    required this.onNodeMove,
  });

  @override
  Widget build(BuildContext context) {
    // Calculate total canvas size based on node positions
    double maxX = 1400, maxY = 900;
    for (final pos in positions.values) {
      if (pos.dx + 220 > maxX) maxX = pos.dx + 220;
      if (pos.dy + 160 > maxY) maxY = pos.dy + 160;
    }

    // Group nodes by compose project for background rect grouping
    final groups = <String, List<_ContainerNode>>{};
    for (final c in containers) {
      final key = c.composeProject.isEmpty ? '' : c.composeProject;
      if (key.isNotEmpty) groups.putIfAbsent(key, () => []).add(c);
    }

    return SizedBox(
      width: maxX + 80,
      height: maxY + 80,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // ── Group backdrop rects ────────────────────────────────────────
          ...groups.entries.map((entry) {
            final groupNodes = entry.value;
            final nodePositions = groupNodes
                .where((n) => positions.containsKey(n.id))
                .map((n) => positions[n.id]!)
                .toList();
            if (nodePositions.isEmpty) return const SizedBox.shrink();

            const pad = 22.0;
            final minX =
                nodePositions.map((p) => p.dx).reduce((a, b) => a < b ? a : b) -
                    pad;
            final minY =
                nodePositions.map((p) => p.dy).reduce((a, b) => a < b ? a : b) -
                    pad - 24;
            final maxGX =
                nodePositions.map((p) => p.dx).reduce((a, b) => a > b ? a : b) +
                    180 + pad;
            final maxGY =
                nodePositions.map((p) => p.dy).reduce((a, b) => a > b ? a : b) +
                    120 + pad;

            return Positioned(
              left: minX,
              top: minY,
              child: Container(
                width: maxGX - minX,
                height: maxGY - minY,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: AppColors.accent.withValues(alpha: 0.12),
                      width: 1),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Text(
                    entry.key,
                    style: const TextStyle(
                      color: AppColors.accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            );
          }),

          // ── Container nodes ─────────────────────────────────────────────
          ...containers.map((node) {
            final pos = positions[node.id] ?? const Offset(40, 40);
            return Positioned(
              left: pos.dx,
              top: pos.dy,
              child: GestureDetector(
                onTap: () => onNodeTap(node),
                onPanUpdate: (d) {
                  onNodeMove(node.id, pos + d.delta);
                },
                child: _ContainerNodeCard(
                  node: node,
                  isSelected: selectedId == node.id,
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ─── Node card ────────────────────────────────────────────────────────────────

class _ContainerNodeCard extends StatelessWidget {
  final _ContainerNode node;
  final bool isSelected;

  const _ContainerNodeCard({
    required this.node,
    required this.isSelected,
  });

  Color get _statusColor {
    switch (node.status) {
      case 'running':
        return AppColors.accentGreen;
      case 'exited':
      case 'dead':
        return AppColors.accentRed;
      case 'paused':
        return AppColors.accentYellow;
      default:
        return AppColors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cpuColor = node.cpuPct > 80
        ? AppColors.accentRed
        : node.cpuPct > 40
            ? AppColors.accentYellow
            : AppColors.accentGreen;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 180,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSelected
              ? AppColors.accent
              : _statusColor.withValues(alpha: 0.35),
          width: isSelected ? 2 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: _statusColor.withValues(alpha: 0.12),
            blurRadius: 14,
            spreadRadius: 0,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status dot + name
          Row(
            children: [
              _StatusDot(color: _statusColor),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  node.composeService.isNotEmpty
                      ? node.composeService
                      : node.name,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Image
          Text(
            node.image.split(':').first.split('/').last,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 10,
              fontFamily: 'monospace',
            ),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          // CPU bar
          _MiniBar(
            label: 'CPU',
            value: node.cpuPct / 100,
            color: cpuColor,
            text: '${node.cpuPct.toStringAsFixed(1)}%',
          ),
          const SizedBox(height: 6),
          // Memory bar
          _MiniBar(
            label: 'MEM',
            value: node.memPct / 100,
            color: AppColors.accent,
            text: '${node.memMb.toStringAsFixed(0)} MB',
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final Color color;
  const _StatusDot({required this.color});

  @override
  Widget build(BuildContext context) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      );
}

class _MiniBar extends StatelessWidget {
  final String label;
  final double value; // 0..1
  final Color color;
  final String text;

  const _MiniBar({
    required this.label,
    required this.value,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 28,
          child: Text(label,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 9,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              )),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: value.clamp(0.0, 1.0),
              backgroundColor: AppColors.border,
              valueColor: AlwaysStoppedAnimation(color),
              minHeight: 4,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(text,
            style: TextStyle(
              color: color,
              fontSize: 9,
              fontFamily: 'monospace',
            )),
      ],
    );
  }
}

// ─── Header bar ───────────────────────────────────────────────────────────────

class _CanvasHeader extends StatelessWidget {
  final bool wsConnected;
  final int containerCount;
  final int runningCount;
  final VoidCallback onRefresh;

  const _CanvasHeader({
    required this.wsConnected,
    required this.containerCount,
    required this.runningCount,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          const Icon(Icons.account_tree_outlined,
              size: 18, color: AppColors.accent),
          const SizedBox(width: 10),
          const Text('Infrastructure Canvas',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              )),
          const SizedBox(width: 20),
          // Live indicator
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: wsConnected ? AppColors.accentGreen : AppColors.textMuted,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            wsConnected ? 'Live' : 'Connexion…',
            style: TextStyle(
              color: wsConnected ? AppColors.accentGreen : AppColors.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (wsConnected) ...[
            const SizedBox(width: 16),
            Text(
              '$runningCount / $containerCount containers actifs',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
          const Spacer(),
          Tooltip(
            message: 'Rafraîchir les stacks',
            child: IconButton(
              icon: const Icon(Icons.refresh,
                  size: 18, color: AppColors.textSecondary),
              onPressed: onRefresh,
            ),
          ),
          const SizedBox(width: 4),
          // Zoom indicator hint
          const Tooltip(
            message: 'Scroll pour zoomer · Drag pour déplacer',
            child: Icon(Icons.zoom_in, size: 18, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

// ─── Node detail side panel ───────────────────────────────────────────────────

class _NodeDetailPanel extends StatelessWidget {
  final _ContainerNode node;
  final VoidCallback onClose;

  const _NodeDetailPanel({required this.node, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final cpuColor = node.cpuPct > 80
        ? AppColors.accentRed
        : node.cpuPct > 40
            ? AppColors.accentYellow
            : AppColors.accentGreen;

    final statusColor = node.status == 'running'
        ? AppColors.accentGreen
        : node.status == 'exited' || node.status == 'dead'
            ? AppColors.accentRed
            : AppColors.accentYellow;

    return Container(
      width: 280,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(left: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: statusColor,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    node.composeService.isNotEmpty
                        ? node.composeService
                        : node.name,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close,
                      size: 16, color: AppColors.textSecondary),
                  onPressed: onClose,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          // Body
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _DetailRow('ID', node.id, mono: true),
                  _DetailRow('Nom complet', node.name),
                  _DetailRow('Image', node.image, mono: true),
                  _DetailRow('Statut', node.status),
                  if (node.composeProject.isNotEmpty)
                    _DetailRow('Stack', node.composeProject),
                  const SizedBox(height: 16),
                  // Big metric tiles
                  Row(
                    children: [
                      Expanded(
                        child: _BigMetricTile(
                          label: 'CPU',
                          value: '${node.cpuPct.toStringAsFixed(1)}%',
                          color: cpuColor,
                          progress: node.cpuPct / 100,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _BigMetricTile(
                          label: 'Mémoire',
                          value: '${node.memMb.toStringAsFixed(0)} MB',
                          color: AppColors.accent,
                          progress: node.memPct / 100,
                          subtitle:
                              '${node.memPct.toStringAsFixed(1)}% du lim.',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (node.labels.isNotEmpty) ...[
                    const Text(
                      'LABELS',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...node.labels.entries
                        .where(
                            (e) => e.key.startsWith('com.docker.compose'))
                        .map((e) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: _DetailRow(
                                e.key.split('.').last,
                                e.value.toString(),
                                mono: true,
                              ),
                            )),
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

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;

  const _DetailRow(this.label, this.value, {this.mono = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
                fontFamily: mono ? 'monospace' : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _BigMetricTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final double progress;
  final String? subtitle;

  const _BigMetricTile({
    required this.label,
    required this.value,
    required this.color,
    required this.progress,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
              )),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                color: color,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
              )),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 9,
                )),
          ],
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              backgroundColor: AppColors.border,
              valueColor: AlwaysStoppedAnimation(color),
              minHeight: 5,
            ),
          ),
        ],
      ),
    );
  }
}
