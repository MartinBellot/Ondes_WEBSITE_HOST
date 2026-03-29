import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../providers/docker_provider.dart';
import '../services/api_service.dart';
import '../widgets/content_header.dart';
import '../widgets/metric_card.dart';
import '../widgets/glass_card.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _api = ApiService();
  Map<String, dynamic>? _dockerStatus;

  // Deploy form state
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _image = TextEditingController();
  final _hPort = TextEditingController();
  final _cPort = TextEditingController(text: '80');
  final _volHost = TextEditingController();
  final _volCont = TextEditingController();
  bool _deploying = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<DockerProvider>().fetchContainers();
      _loadDockerStatus();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    for (final c in [_name, _image, _hPort, _cPort, _volHost, _volCont]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadDockerStatus() async {
    try {
      final status = await _api.dockerStatus();
      if (mounted) setState(() => _dockerStatus = status);
    } catch (_) {}
  }

  Future<void> _deploy() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _deploying = true);

    final ok = await context.read<DockerProvider>().createContainer({
      'name': _name.text.trim(),
      'image': _image.text.trim(),
      'host_port': int.parse(_hPort.text.trim()),
      'container_port': int.parse(_cPort.text.trim()),
      'volume_host': _volHost.text.trim(),
      'volume_container': _volCont.text.trim(),
    });

    if (mounted) {
      setState(() => _deploying = false);
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Container deployed successfully'),
            backgroundColor: AppColors.accentGreen,
          ),
        );
        _name.clear();
        _image.clear();
        _hPort.clear();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text(context.read<DockerProvider>().error ?? 'Deploy failed'),
            backgroundColor: AppColors.accentRed,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          if (_dockerStatus != null && _dockerStatus!['available'] == false)
            _DockerUnavailableBanner(
                helpText: _dockerStatus!['help'] as String? ?? ''),
          ContentHeader(
            title: 'Dashboard',
            actions: [
              Consumer<DockerProvider>(
                builder: (_, docker, __) => TextButton.icon(
                  onPressed: docker.fetchContainers,
                  icon: const Icon(Icons.refresh,
                      size: 14, color: AppColors.textSecondary),
                  label: const Text('Refresh',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 13)),
                ),
              ),
            ],
            bottom: TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: 'Overview'),
                Tab(text: 'Deploy Container'),
              ],
              labelColor: AppColors.accent,
              unselectedLabelColor: AppColors.textMuted,
              indicatorColor: AppColors.accent,
              dividerColor: Colors.transparent,
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                const _OverviewTab(),
                _DeployTab(
                  formKey: _formKey,
                  name: _name,
                  image: _image,
                  hPort: _hPort,
                  cPort: _cPort,
                  volHost: _volHost,
                  volCont: _volCont,
                  deploying: _deploying,
                  onDeploy: _deploy,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Overview tab ─────────────────────────────────────────────────────────────
class _OverviewTab extends StatelessWidget {
  const _OverviewTab();

  @override
  Widget build(BuildContext context) {
    return Consumer<DockerProvider>(
      builder: (context, docker, _) {
        final running =
            docker.containers.where((c) => c['status'] == 'running').length;
        final total = docker.containers.length;
        final stopped = total - running;

        return SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Overview',
                  style: Theme.of(context).textTheme.headlineSmall),
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
              Text('Containers',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              _ContainerTable(docker: docker),
            ],
          ),
        );
      },
    );
  }
}

// ─── Deploy tab ───────────────────────────────────────────────────────────────
class _DeployTab extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController name, image, hPort, cPort, volHost, volCont;
  final bool deploying;
  final VoidCallback onDeploy;

  const _DeployTab({
    required this.formKey,
    required this.name,
    required this.image,
    required this.hPort,
    required this.cPort,
    required this.volHost,
    required this.volCont,
    required this.deploying,
    required this.onDeploy,
  });

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 700;
    return SingleChildScrollView(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      child: isMobile
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _DeployForm(
                  formKey: formKey,
                  name: name,
                  image: image,
                  hPort: hPort,
                  cPort: cPort,
                  volHost: volHost,
                  volCont: volCont,
                  deploying: deploying,
                  onDeploy: onDeploy,
                ),
                const SizedBox(height: 20),
                Consumer<DockerProvider>(
                  builder: (_, docker, __) => _ContainerList(docker: docker),
                ),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  flex: 2,
                  child: _DeployForm(
                    formKey: formKey,
                    name: name,
                    image: image,
                    hPort: hPort,
                    cPort: cPort,
                    volHost: volHost,
                    volCont: volCont,
                    deploying: deploying,
                    onDeploy: onDeploy,
                  ),
                ),
                const SizedBox(width: 20),
                Flexible(
                  flex: 3,
                  child: Consumer<DockerProvider>(
                    builder: (_, docker, __) => _ContainerList(docker: docker),
                  ),
                ),
              ],
            ),
    );
  }
}

// ─── Container table (Overview tab) ──────────────────────────────────────────
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
      return const _EmptyState(
          'No containers found.\nDeploy one from the Deploy tab.');
    }
    return GlassCard(
      padding: EdgeInsets.zero,
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
        border: Border(bottom: BorderSide(color: GlassTokens.cardBorder)),
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
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              container['image'] ?? '—',
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 13),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
            ),
          ),
          const SizedBox(width: 16),
          _ChipButton(
            label: isRunning ? 'Stop' : 'Start',
            color: isRunning ? AppColors.accentRed : AppColors.accentGreen,
            onTap: () => docker.performAction(
                container['id'], isRunning ? 'stop' : 'start'),
          ),
          const SizedBox(width: 6),
          _ChipButton(
            label: 'Remove',
            color: AppColors.textMuted,
            onTap: () => docker.performAction(container['id'], 'remove'),
          ),
        ],
      ),
    );
  }
}

// ─── Deploy form ──────────────────────────────────────────────────────────────
class _DeployForm extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController name, image, hPort, cPort, volHost, volCont;
  final bool deploying;
  final VoidCallback onDeploy;

  const _DeployForm({
    required this.formKey,
    required this.name,
    required this.image,
    required this.hPort,
    required this.cPort,
    required this.volHost,
    required this.volCont,
    required this.deploying,
    required this.onDeploy,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'New Container',
              style: GoogleFonts.inter(
                color: AppColors.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 20),
            _Field('Container Name', name, hint: 'my-api', required: true),
            const SizedBox(height: 14),
            _Field('Docker Image', image,
                hint: 'nginx:alpine', required: true),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: _PortField('Host Port', hPort, hint: '8080')),
              const SizedBox(width: 12),
              Expanded(
                  child: _PortField('Container Port', cPort, hint: '80')),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                  child: _Field('Volume Host Path', volHost,
                      hint: '/data/app')),
              const SizedBox(width: 12),
              Expanded(
                  child: _Field('Volume Container Path', volCont,
                      hint: '/app/data')),
            ]),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 40,
              child: ElevatedButton.icon(
                onPressed: deploying ? null : onDeploy,
                icon: deploying
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation(AppColors.background),
                        ),
                      )
                    : const Icon(Icons.rocket_launch_outlined, size: 16),
                label: Text(deploying ? 'Deploying…' : 'Deploy'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Container list (Deploy tab) ─────────────────────────────────────────────
class _ContainerList extends StatelessWidget {
  final DockerProvider docker;
  const _ContainerList({required this.docker});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'All Containers',
              style: GoogleFonts.inter(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Divider(height: 1),
          if (docker.isLoading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                  child:
                      CircularProgressIndicator(color: AppColors.accent)),
            )
          else if (docker.containers.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: Text('No containers',
                    style: TextStyle(color: AppColors.textMuted)),
              ),
            )
          else
            ...docker.containers
                .map((c) => _ContainerRow(container: c, docker: docker)),
        ],
      ),
    );
  }
}

// ─── Docker unavailable banner ────────────────────────────────────────────────
class _DockerUnavailableBanner extends StatelessWidget {
  final String helpText;
  const _DockerUnavailableBanner({required this.helpText});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: AppColors.accentYellow.withValues(alpha: 0.08),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: AppColors.accentYellow, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Docker non disponible',
                    style: TextStyle(
                        color: AppColors.accentYellow,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
                if (helpText.isNotEmpty)
                  Text(helpText,
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Shared small widgets ─────────────────────────────────────────────────────
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
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _hovering
                  ? widget.color.withValues(alpha: 0.15)
                  : widget.color.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(4),
              border:
                  Border.all(color: widget.color.withValues(alpha: 0.3)),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                color: widget.color,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      );
}

class _Field extends StatelessWidget {
  final String label;
  final TextEditingController ctrl;
  final String? hint;
  final bool required;

  const _Field(this.label, this.ctrl, {this.hint, this.required = false});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          TextFormField(
            controller: ctrl,
            style:
                GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 14),
            decoration: InputDecoration(hintText: hint),
            validator: required
                ? (v) => (v == null || v.isEmpty) ? 'Required' : null
                : null,
          ),
        ],
      );
}

class _PortField extends StatelessWidget {
  final String label;
  final TextEditingController ctrl;
  final String? hint;

  const _PortField(this.label, this.ctrl, {this.hint});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          TextFormField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            style:
                GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 14),
            decoration: InputDecoration(hintText: hint),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Required';
              final p = int.tryParse(v);
              if (p == null || p < 1 || p > 65535) return 'Invalid';
              return null;
            },
          ),
        ],
      );
}
