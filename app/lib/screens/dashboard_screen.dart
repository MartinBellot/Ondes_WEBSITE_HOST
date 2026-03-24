import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../providers/docker_provider.dart';
import '../widgets/metric_card.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => context.read<DockerProvider>().fetchContainers(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PageHeader(
            title: 'Dashboard',
            action: Consumer<DockerProvider>(
              builder: (_, docker, __) =>
                  _RefreshButton(docker.fetchContainers),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Consumer<DockerProvider>(
                builder: (context, docker, _) {
                  final running = docker.containers
                      .where((c) => c['status'] == 'running')
                      .length;
                  final total = docker.containers.length;
                  final stopped = total - running;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Overview',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 16,
                        runSpacing: 16,
                        children: [
                          SizedBox(
                            width: 220,
                            child: MetricCard(
                              title: 'Running',
                              value: docker.isLoading ? '…' : '$running',
                              icon: Icons.play_circle_outline,
                              iconColor: AppColors.accentGreen,
                              subtitle: 'Active containers',
                            ),
                          ),
                          SizedBox(
                            width: 220,
                            child: MetricCard(
                              title: 'Total',
                              value: docker.isLoading ? '…' : '$total',
                              icon: Icons.inventory_2_outlined,
                              subtitle: '$stopped stopped',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 36),
                      const Text(
                        'Containers',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _ContainerTable(docker: docker),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Container table ──────────────────────────────────────────────────────────
class _ContainerTable extends StatelessWidget {
  final DockerProvider docker;
  const _ContainerTable({required this.docker});

  @override
  Widget build(BuildContext context) {
    if (docker.isLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: CircularProgressIndicator(color: AppColors.accent),
        ),
      );
    }
    if (docker.containers.isEmpty) {
      return _EmptyState(
          'No containers found.\nDeploy one from the Containers tab.');
    }
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: docker.containers
            .map((c) => _ContainerRow(container: c, docker: docker))
            .toList(),
      ),
    );
  }
}

class _ContainerRow extends StatelessWidget {
  final dynamic container;
  final DockerProvider docker;
  const _ContainerRow({required this.container, required this.docker});

  @override
  Widget build(BuildContext context) {
    final isRunning = container['status'] == 'running';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.borderLight)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: isRunning ? AppColors.accentGreen : AppColors.textMuted,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              container['name'] ?? '—',
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Text(
            container['image'] ?? '—',
            style:
                const TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
          const SizedBox(width: 16),
          _ChipButton(
            label: isRunning ? 'Stop' : 'Start',
            color: isRunning ? AppColors.accentRed : AppColors.accentGreen,
            onTap: () => docker.performAction(
              container['id'],
              isRunning ? 'stop' : 'start',
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Shared UI pieces ─────────────────────────────────────────────────────────
class _PageHeader extends StatelessWidget {
  final String title;
  final Widget? action;
  const _PageHeader({required this.title, this.action});

  @override
  Widget build(BuildContext context) => Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 28),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(bottom: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (action != null) action!,
          ],
        ),
      );
}

class _RefreshButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _RefreshButton(this.onPressed);

  @override
  Widget build(BuildContext context) => TextButton.icon(
        onPressed: onPressed,
        icon:
            const Icon(Icons.refresh, size: 14, color: AppColors.textSecondary),
        label: const Text(
          'Refresh',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
      );
}

class _EmptyState extends StatelessWidget {
  final String message;
  const _EmptyState(this.message);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Center(
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 14),
          ),
        ),
      );
}

class _ChipButton extends StatefulWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ChipButton(
      {required this.label, required this.color, required this.onTap});

  @override
  State<_ChipButton> createState() => _ChipButtonState();
}

class _ChipButtonState extends State<_ChipButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _hovering
                  ? widget.color.withOpacity(0.15)
                  : widget.color.withOpacity(0.08),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: widget.color.withOpacity(0.3)),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                color: widget.color,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      );
}
