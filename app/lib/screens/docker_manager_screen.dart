import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../providers/docker_provider.dart';

class DockerManagerScreen extends StatefulWidget {
  const DockerManagerScreen({super.key});

  @override
  State<DockerManagerScreen> createState() => _DockerManagerScreenState();
}

class _DockerManagerScreenState extends State<DockerManagerScreen> {
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
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => context.read<DockerProvider>().fetchContainers(),
    );
  }

  @override
  void dispose() {
    for (final c in [_name, _image, _hPort, _cPort, _volHost, _volCont]) {
      c.dispose();
    }
    super.dispose();
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
      body: Column(
        children: [
          _Header('Deploy Container'),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Deploy form ───────────────────────────────────
                  Flexible(
                    flex: 2,
                    child: _DeployForm(
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
                  ),
                  const SizedBox(width: 20),
                  // ── Container list ────────────────────────────────
                  Flexible(
                    flex: 3,
                    child: Consumer<DockerProvider>(
                      builder: (_, docker, __) =>
                          _ContainerList(docker: docker),
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
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
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
            _Field('Docker Image', image, hint: 'nginx:alpine', required: true),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: _PortField('Host Port', hPort, hint: '8080')),
              const SizedBox(width: 12),
              Expanded(child: _PortField('Container Port', cPort, hint: '80')),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                  child:
                      _Field('Volume Host Path', volHost, hint: '/data/app')),
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

// ─── Container list ───────────────────────────────────────────────────────────
class _ContainerList extends StatelessWidget {
  final DockerProvider docker;
  const _ContainerList({required this.docker});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
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
                  child: CircularProgressIndicator(color: AppColors.accent)),
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
                .map((c) => _DockerRow(container: c, docker: docker)),
        ],
      ),
    );
  }
}

class _DockerRow extends StatelessWidget {
  final dynamic container;
  final DockerProvider docker;
  const _DockerRow({required this.container, required this.docker});

  @override
  Widget build(BuildContext context) {
    final isRunning = container['status'] == 'running';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.borderLight)),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: isRunning ? AppColors.accentGreen : AppColors.textMuted,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(container['name'] ?? '—',
                    style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
                Text(container['image'] ?? '—',
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 12)),
              ],
            ),
          ),
          _MiniBtn(
            label: isRunning ? 'Stop' : 'Start',
            color: isRunning ? AppColors.accentRed : AppColors.accentGreen,
            onTap: () => docker.performAction(
                container['id'], isRunning ? 'stop' : 'start'),
          ),
          const SizedBox(width: 6),
          _MiniBtn(
            label: 'Remove',
            color: AppColors.textMuted,
            onTap: () => docker.performAction(container['id'], 'remove'),
          ),
        ],
      ),
    );
  }
}

// ─── Shared small form helpers ────────────────────────────────────────────────
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

class _Header extends StatelessWidget {
  final String title;
  const _Header(this.title);

  @override
  Widget build(BuildContext context) => Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 28),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(bottom: BorderSide(color: AppColors.border)),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(title,
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
        ),
      );
}

class _MiniBtn extends StatefulWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _MiniBtn(
      {required this.label, required this.color, required this.onTap});

  @override
  State<_MiniBtn> createState() => _MiniBtnState();
}

class _MiniBtnState extends State<_MiniBtn> {
  bool _hov = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hov = true),
        onExit: (_) => setState(() => _hov = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _hov
                  ? widget.color.withOpacity(0.15)
                  : AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                color: _hov ? widget.color : AppColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      );
}
