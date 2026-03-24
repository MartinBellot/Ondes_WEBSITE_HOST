import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../providers/sites_provider.dart';
import 'site_detail_screen.dart';

class SitesScreen extends StatefulWidget {
  const SitesScreen({super.key});

  @override
  State<SitesScreen> createState() => _SitesScreenState();
}

class _SitesScreenState extends State<SitesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => context.read<SitesProvider>().fetchSites(),
    );
  }

  void _createSite() {
    showDialog(
      context: context,
      builder: (_) => _NewSiteDialog(
        onCreate: (data) async {
          final site = await context.read<SitesProvider>().createSite(data);
          if (site != null && mounted) {
            Navigator.of(context).pop();
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => SiteDetailScreen(site: site),
            ));
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Header
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
                    'Mes Sites',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Consumer<SitesProvider>(
                  builder: (_, sites, __) => TextButton.icon(
                    onPressed: sites.isLoading
                        ? null
                        : () => context.read<SitesProvider>().fetchSites(),
                    icon: const Icon(Icons.refresh,
                        size: 14, color: AppColors.textSecondary),
                    label: const Text('Refresh',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 13)),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _createSite,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Nouveau site'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                  ),
                ),
              ],
            ),
          ),
          // Body
          Expanded(
            child: Consumer<SitesProvider>(
              builder: (context, sites, _) {
                if (sites.isLoading && sites.sites.isEmpty) {
                  return const Center(
                    child: CircularProgressIndicator(color: AppColors.accent),
                  );
                }
                if (sites.sites.isEmpty) {
                  return _EmptyState(onCreateTap: _createSite);
                }
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${sites.sites.length} site${sites.sites.length > 1 ? 's' : ''}',
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 13),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 16,
                        runSpacing: 16,
                        children: sites.sites
                            .map<Widget>((s) => SiteCard(
                                  site: s,
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => SiteDetailScreen(site: s),
                                    ),
                                  ),
                                  onDelete: () async {
                                    final confirmed = await _confirmDelete(
                                        context, s['name']);
                                    if (confirmed && context.mounted) {
                                      context
                                          .read<SitesProvider>()
                                          .deleteSite(s['id'] as int);
                                    }
                                  },
                                ))
                            .toList(),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context, String name) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.surfaceVariant,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: AppColors.border),
            ),
            title: const Text('Supprimer le site',
                style: TextStyle(color: AppColors.textPrimary)),
            content: Text(
              'Voulez-vous supprimer "$name" ? Les conteneurs associés ne seront pas supprimés.',
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Annuler',
                    style: TextStyle(color: AppColors.textSecondary)),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentRed),
                child: const Text('Supprimer'),
              ),
            ],
          ),
        ) ??
        false;
  }
}

// ─── Site Card ────────────────────────────────────────────────────────────────
class SiteCard extends StatefulWidget {
  final dynamic site;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const SiteCard(
      {super.key,
      required this.site,
      required this.onTap,
      required this.onDelete});

  @override
  State<SiteCard> createState() => _SiteCardState();
}

class _SiteCardState extends State<SiteCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final site = widget.site;
    final status = site['status'] as String? ?? 'idle';
    final type = site['site_type'] as String? ?? 'web';
    final ssl = site['ssl_enabled'] as bool? ?? false;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 320,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: _hovering ? AppColors.surfaceVariant : AppColors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _hovering
                  ? AppColors.accent.withOpacity(0.4)
                  : AppColors.border,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top row: name + status dot
              Row(
                children: [
                  Expanded(
                    child: Text(
                      site['name'] ?? '—',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _StatusDot(status: status),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: widget.onDelete,
                    child: const Icon(Icons.delete_outline,
                        size: 16, color: AppColors.textMuted),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // Domain
              Text(
                site['domain']?.isNotEmpty == true
                    ? site['domain']
                    : 'Aucun domaine configuré',
                style: TextStyle(
                  color: site['domain']?.isNotEmpty == true
                      ? AppColors.accent
                      : AppColors.textMuted,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 14),
              // Tags row
              Wrap(
                spacing: 6,
                children: [
                  _Tag(label: _typeLabel(type), color: AppColors.accent),
                  if (ssl) _Tag(label: 'SSL ✓', color: AppColors.accentGreen),
                  if (site['github_repo']?.isNotEmpty == true)
                    _Tag(label: 'GitHub', color: AppColors.textSecondary),
                ],
              ),
              const SizedBox(height: 14),
              // GitHub repo
              if (site['github_repo']?.isNotEmpty == true)
                Row(
                  children: [
                    const Icon(Icons.code,
                        size: 13, color: AppColors.textMuted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        site['github_repo'],
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 14),
              // Port info
              Row(
                children: [
                  if (site['web_port'] != null)
                    _PortChip(label: 'Web', port: site['web_port']),
                  if (site['web_port'] != null && site['api_port'] != null)
                    const SizedBox(width: 6),
                  if (site['api_port'] != null)
                    _PortChip(label: 'API', port: site['api_port']),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'api':
        return 'API';
      case 'fullstack':
        return 'Fullstack';
      default:
        return 'Web';
    }
  }
}

class _StatusDot extends StatelessWidget {
  final String status;
  const _StatusDot({required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (status) {
      case 'running':
        color = AppColors.accentGreen;
        break;
      case 'deploying':
        color = AppColors.accentYellow;
        break;
      case 'error':
        color = AppColors.accentRed;
        break;
      default:
        color = AppColors.textMuted;
    }
    return Row(
      children: [
        Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(status, style: TextStyle(color: color, fontSize: 11)),
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;
  final Color color;
  const _Tag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 11, fontWeight: FontWeight.w500)),
      );
}

class _PortChip extends StatelessWidget {
  final String label;
  final dynamic port;
  const _PortChip({required this.label, required this.port});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(
          '$label :$port',
          style: GoogleFonts.jetBrainsMono(
              color: AppColors.textSecondary, fontSize: 11),
        ),
      );
}

// ─── Empty State ──────────────────────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  final VoidCallback onCreateTap;
  const _EmptyState({required this.onCreateTap});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.web_asset_off_outlined,
                size: 48, color: AppColors.textMuted),
            const SizedBox(height: 16),
            const Text(
              'Aucun site pour le moment',
              style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 16,
                  fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            const Text(
              'Créez votre premier site pour commencer à héberger.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 14),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onCreateTap,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Créer un site'),
            ),
          ],
        ),
      );
}

// ─── New Site Dialog ──────────────────────────────────────────────────────────
class _NewSiteDialog extends StatefulWidget {
  final Future<void> Function(Map<String, dynamic>) onCreate;
  const _NewSiteDialog({required this.onCreate});

  @override
  State<_NewSiteDialog> createState() => _NewSiteDialogState();
}

class _NewSiteDialogState extends State<_NewSiteDialog> {
  final _nameCtrl = TextEditingController();
  final _domainCtrl = TextEditingController();
  String _type = 'web';
  bool _creating = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _domainCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surfaceVariant,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Container(
        width: 440,
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Nouveau site',
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 20),
            _DialogField('Nom du site', _nameCtrl, hint: 'mon-app'),
            const SizedBox(height: 14),
            _DialogField('Nom de domaine (optionnel)', _domainCtrl,
                hint: 'app.example.com'),
            const SizedBox(height: 14),
            const Text('Type',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500)),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              value: _type,
              dropdownColor: AppColors.surfaceVariant,
              style:
                  const TextStyle(color: AppColors.textPrimary, fontSize: 14),
              decoration: InputDecoration(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
              ),
              items: const [
                DropdownMenuItem(value: 'web', child: Text('Web / Frontend')),
                DropdownMenuItem(value: 'api', child: Text('API / Backend')),
                DropdownMenuItem(value: 'fullstack', child: Text('Fullstack')),
              ],
              onChanged: (v) => setState(() => _type = v ?? 'web'),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Annuler',
                      style: TextStyle(color: AppColors.textSecondary)),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: _creating
                      ? null
                      : () async {
                          if (_nameCtrl.text.trim().isEmpty) return;
                          setState(() => _creating = true);
                          await widget.onCreate({
                            'name': _nameCtrl.text.trim(),
                            'domain': _domainCtrl.text.trim(),
                            'site_type': _type,
                          });
                          if (mounted) setState(() => _creating = false);
                        },
                  child: _creating
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation(AppColors.background)))
                      : const Text('Créer'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DialogField extends StatelessWidget {
  final String label;
  final TextEditingController ctrl;
  final String? hint;
  const _DialogField(this.label, this.ctrl, {this.hint});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          TextFormField(
            controller: ctrl,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
            decoration: InputDecoration(hintText: hint),
          ),
        ],
      );
}
