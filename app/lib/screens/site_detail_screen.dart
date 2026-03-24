import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../providers/sites_provider.dart';
import '../providers/github_provider.dart';

class SiteDetailScreen extends StatefulWidget {
  final dynamic site;
  const SiteDetailScreen({super.key, required this.site});

  @override
  State<SiteDetailScreen> createState() => _SiteDetailScreenState();
}

class _SiteDetailScreenState extends State<SiteDetailScreen>
    with TickerProviderStateMixin {
  late TabController _tabCtrl;
  late Map<String, dynamic> _site;

  @override
  void initState() {
    super.initState();
    _site = Map<String, dynamic>.from(widget.site as Map);
    _tabCtrl = TabController(length: 5, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshSite() async {
    await context.read<SitesProvider>().fetchSites();
    final updated = context
        .read<SitesProvider>()
        .sites
        .firstWhere((s) => s['id'] == _site['id'], orElse: () => _site);
    if (mounted)
      setState(() => _site = Map<String, dynamic>.from(updated as Map));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // ── Header ─────────────────────────────────────────────────
          Container(
            decoration: const BoxDecoration(
              color: AppColors.surface,
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.arrow_back_ios_new,
                            size: 16, color: AppColors.textSecondary),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _site['name'] ?? '—',
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (_site['domain']?.isNotEmpty == true)
                              Text(
                                _site['domain'],
                                style: const TextStyle(
                                    color: AppColors.accent, fontSize: 13),
                              ),
                          ],
                        ),
                      ),
                      _StatusPill(_site['status'] ?? 'idle'),
                    ],
                  ),
                ),
                TabBar(
                  controller: _tabCtrl,
                  isScrollable: true,
                  labelColor: AppColors.accent,
                  unselectedLabelColor: AppColors.textMuted,
                  indicatorColor: AppColors.accent,
                  indicatorSize: TabBarIndicatorSize.tab,
                  labelStyle: GoogleFonts.inter(
                      fontSize: 13, fontWeight: FontWeight.w500),
                  tabs: const [
                    Tab(text: 'Général'),
                    Tab(text: 'GitHub'),
                    Tab(text: 'Hébergement'),
                    Tab(text: 'Domaine & SSL'),
                    Tab(text: 'NGINX'),
                  ],
                ),
              ],
            ),
          ),
          // ── Tab views ──────────────────────────────────────────────
          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: [
                _GeneralTab(
                    site: _site,
                    onSaved: (updated) {
                      setState(() => _site = updated);
                    }),
                _GitHubTab(
                    site: _site,
                    onSaved: (updated) {
                      setState(() => _site = updated);
                    }),
                _HostingTab(site: _site, onRefresh: _refreshSite),
                _DomainSslTab(site: _site, onRefresh: _refreshSite),
                _NginxTab(site: _site),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 1 — Général
// ─────────────────────────────────────────────────────────────────────────────
class _GeneralTab extends StatefulWidget {
  final Map<String, dynamic> site;
  final void Function(Map<String, dynamic>) onSaved;
  const _GeneralTab({required this.site, required this.onSaved});

  @override
  State<_GeneralTab> createState() => _GeneralTabState();
}

class _GeneralTabState extends State<_GeneralTab> {
  late TextEditingController _name;
  late TextEditingController _domain;
  late String _type;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.site['name'] ?? '');
    _domain = TextEditingController(text: widget.site['domain'] ?? '');
    _type = widget.site['site_type'] ?? 'web';
  }

  @override
  void dispose() {
    _name.dispose();
    _domain.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await context
        .read<SitesProvider>()
        .updateSite(widget.site['id'] as int, {
      'name': _name.text.trim(),
      'domain': _domain.text.trim(),
      'site_type': _type,
    });
    if (mounted) {
      setState(() => _saving = false);
      if (ok) {
        widget.onSaved({
          ...widget.site,
          'name': _name.text.trim(),
          'domain': _domain.text.trim(),
          'site_type': _type
        });
        _snack(context, 'Saved', success: true);
      } else {
        _snack(context, context.read<SitesProvider>().error ?? 'Error');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _TabScaffold(
      children: [
        _SectionTitle('Informations générales'),
        const SizedBox(height: 16),
        _FormRow(children: [
          _FormField('Nom du site', _name, hint: 'mon-app'),
          _FormField('Domaine', _domain, hint: 'app.example.com'),
        ]),
        const SizedBox(height: 14),
        _Select(
          label: 'Type de site',
          value: _type,
          items: const {
            'web': 'Web / Frontend',
            'api': 'API / Backend',
            'fullstack': 'Fullstack'
          },
          onChanged: (v) => setState(() => _type = v),
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(AppColors.background)))
              : const Text('Enregistrer'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 2 — GitHub
// ─────────────────────────────────────────────────────────────────────────────
class _GitHubTab extends StatefulWidget {
  final Map<String, dynamic> site;
  final void Function(Map<String, dynamic>) onSaved;
  const _GitHubTab({required this.site, required this.onSaved});

  @override
  State<_GitHubTab> createState() => _GitHubTabState();
}

class _GitHubTabState extends State<_GitHubTab> {
  late TextEditingController _tokenCtrl;
  String? _selectedRepo;
  String? _selectedBranch;
  bool _tokenVerified = false;
  bool _verifying = false;
  bool _deploying = false;

  @override
  void initState() {
    super.initState();
    _tokenCtrl = TextEditingController(text: widget.site['github_token'] ?? '');
    _selectedRepo = widget.site['github_repo']?.isNotEmpty == true
        ? widget.site['github_repo']
        : null;
    _selectedBranch = widget.site['github_branch'] ?? 'main';
  }

  @override
  void dispose() {
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    setState(() => _verifying = true);
    final ok =
        await context.read<GitHubProvider>().connect(_tokenCtrl.text.trim());
    if (ok && mounted) {
      context.read<GitHubProvider>().fetchRepos(_tokenCtrl.text.trim());
      setState(() {
        _tokenVerified = true;
        _verifying = false;
      });
    } else if (mounted) {
      setState(() => _verifying = false);
      _snack(context, 'Token invalide');
    }
  }

  Future<void> _saveAndDeploy() async {
    if (_selectedRepo == null) return;
    setState(() => _deploying = true);
    // Save github fields first
    await context.read<SitesProvider>().updateSite(widget.site['id'] as int, {
      'github_repo': _selectedRepo,
      'github_branch': _selectedBranch ?? 'main',
      'github_token': _tokenCtrl.text.trim(),
    });
    final result = await context
        .read<SitesProvider>()
        .deploySite(widget.site['id'] as int);
    if (mounted) {
      setState(() => _deploying = false);
      if (result['status'] == 'deploying' || result['status'] != null) {
        widget.onSaved({
          ...widget.site,
          'github_repo': _selectedRepo,
          'github_branch': _selectedBranch,
          'status': 'deploying',
        });
        _snack(context, 'Déploiement lancé en arrière-plan', success: true);
      } else {
        _snack(context, result['error'] ?? 'Erreur de déploiement');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final gh = context.watch<GitHubProvider>();
    return _TabScaffold(
      children: [
        _SectionTitle('Connexion GitHub'),
        const SizedBox(height: 4),
        const Text(
          'Utilisez un Personal Access Token (PAT) avec les droits repo.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _tokenCtrl,
                obscureText: true,
                style: GoogleFonts.jetBrainsMono(
                    color: AppColors.textPrimary, fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'GitHub Personal Access Token',
                  hintText: 'ghp_xxxxxxxxxxxxxxxxxxxx',
                ),
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton(
              onPressed: _verifying ? null : _verify,
              child: _verifying
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation(AppColors.background)))
                  : Text(gh.isConnected ? '✓ Vérifié' : 'Vérifier'),
              style: ElevatedButton.styleFrom(
                backgroundColor: gh.isConnected ? AppColors.accentGreen : null,
              ),
            ),
          ],
        ),
        if (gh.isConnected) ...[
          const SizedBox(height: 6),
          Text('Connecté en tant que @${gh.githubLogin}',
              style:
                  const TextStyle(color: AppColors.accentGreen, fontSize: 13)),
          const SizedBox(height: 20),
          _SectionTitle('Sélectionner un dépôt'),
          const SizedBox(height: 12),
          if (gh.isLoadingRepos)
            const Center(
                child: Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(color: AppColors.accent),
            ))
          else
            _RepoSelector(
              repos: gh.repos,
              selectedRepo: _selectedRepo,
              onSelected: (repo) {
                setState(() {
                  _selectedRepo = repo;
                  _selectedBranch = 'main';
                });
                context
                    .read<GitHubProvider>()
                    .fetchBranches(_tokenCtrl.text.trim(), repo);
              },
            ),
          if (_selectedRepo != null) ...[
            const SizedBox(height: 20),
            _SectionTitle('Branche'),
            const SizedBox(height: 10),
            if (gh.isLoadingBranches)
              const CircularProgressIndicator(color: AppColors.accent)
            else
              Wrap(
                spacing: 8,
                children: gh.branches
                    .map((b) => _BranchChip(
                          label: b,
                          selected: _selectedBranch == b,
                          onTap: () => setState(() => _selectedBranch = b),
                        ))
                    .toList(),
              ),
            const SizedBox(height: 28),
            _DeployButton(
              repo: _selectedRepo!,
              branch: _selectedBranch ?? 'main',
              deploying: _deploying,
              onDeploy: _saveAndDeploy,
            ),
          ],
        ],
      ],
    );
  }
}

class _RepoSelector extends StatefulWidget {
  final List<dynamic> repos;
  final String? selectedRepo;
  final void Function(String) onSelected;
  const _RepoSelector(
      {required this.repos,
      required this.selectedRepo,
      required this.onSelected});

  @override
  State<_RepoSelector> createState() => _RepoSelectorState();
}

class _RepoSelectorState extends State<_RepoSelector> {
  final _searchCtrl = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.repos.where((r) {
      final name = (r['full_name'] as String).toLowerCase();
      return _q.isEmpty || name.contains(_q.toLowerCase());
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchCtrl,
          onChanged: (v) => setState(() => _q = v),
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
          decoration: const InputDecoration(
            hintText: 'Rechercher un dépôt…',
            prefixIcon:
                Icon(Icons.search, size: 16, color: AppColors.textMuted),
          ),
        ),
        const SizedBox(height: 10),
        Container(
          constraints: const BoxConstraints(maxHeight: 260),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.border),
          ),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: filtered.length,
            itemBuilder: (_, i) {
              final r = filtered[i];
              final fullName = r['full_name'] as String;
              final isSelected = widget.selectedRepo == fullName;
              return _RepoTile(
                repo: r,
                isSelected: isSelected,
                onTap: () => widget.onSelected(fullName),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RepoTile extends StatefulWidget {
  final dynamic repo;
  final bool isSelected;
  final VoidCallback onTap;
  const _RepoTile(
      {required this.repo, required this.isSelected, required this.onTap});

  @override
  State<_RepoTile> createState() => _RepoTileState();
}

class _RepoTileState extends State<_RepoTile> {
  bool _hov = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.repo;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hov = true),
      onExit: (_) => setState(() => _hov = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? AppColors.accent.withOpacity(0.1)
                : _hov
                    ? AppColors.surfaceVariant
                    : Colors.transparent,
            border: Border(bottom: BorderSide(color: AppColors.borderLight)),
          ),
          child: Row(
            children: [
              Icon(
                r['private'] == true ? Icons.lock_outline : Icons.code,
                size: 14,
                color:
                    widget.isSelected ? AppColors.accent : AppColors.textMuted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r['full_name'] as String,
                      style: TextStyle(
                        color: widget.isSelected
                            ? AppColors.accent
                            : AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if ((r['description'] as String?)?.isNotEmpty == true)
                      Text(
                        r['description'] as String,
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (r['language'] != null)
                Text(r['language'] as String,
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 11)),
              if (widget.isSelected) ...[
                const SizedBox(width: 8),
                const Icon(Icons.check, size: 14, color: AppColors.accent),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _BranchChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _BranchChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accent.withOpacity(0.15)
                : AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
                color: selected ? AppColors.accent : AppColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.account_tree_outlined,
                  size: 12,
                  color: selected ? AppColors.accent : AppColors.textMuted),
              const SizedBox(width: 5),
              Text(label,
                  style: TextStyle(
                    color:
                        selected ? AppColors.accent : AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  )),
            ],
          ),
        ),
      );
}

class _DeployButton extends StatelessWidget {
  final String repo, branch;
  final bool deploying;
  final VoidCallback onDeploy;
  const _DeployButton(
      {required this.repo,
      required this.branch,
      required this.deploying,
      required this.onDeploy});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Prêt à déployer',
                      style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(
                    '$repo @ $branch',
                    style: GoogleFonts.jetBrainsMono(
                        color: AppColors.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            ElevatedButton.icon(
              onPressed: deploying ? null : onDeploy,
              icon: deploying
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation(AppColors.background)))
                  : const Icon(Icons.rocket_launch_outlined, size: 16),
              label: Text(deploying ? 'Déploiement…' : 'Déployer'),
            ),
          ],
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 3 — Hébergement
// ─────────────────────────────────────────────────────────────────────────────
class _HostingTab extends StatefulWidget {
  final Map<String, dynamic> site;
  final Future<void> Function() onRefresh;
  const _HostingTab({required this.site, required this.onRefresh});

  @override
  State<_HostingTab> createState() => _HostingTabState();
}

class _HostingTabState extends State<_HostingTab> {
  late TextEditingController _webCont, _webPort, _apiCont, _apiPort;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _webCont =
        TextEditingController(text: widget.site['web_container_name'] ?? '');
    _webPort =
        TextEditingController(text: widget.site['web_port']?.toString() ?? '');
    _apiCont =
        TextEditingController(text: widget.site['api_container_name'] ?? '');
    _apiPort =
        TextEditingController(text: widget.site['api_port']?.toString() ?? '');
  }

  @override
  void dispose() {
    for (final c in [_webCont, _webPort, _apiCont, _apiPort]) c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await context.read<SitesProvider>().updateSite(widget.site['id'] as int, {
      'web_container_name': _webCont.text.trim(),
      'web_port': _webPort.text.isEmpty ? null : int.tryParse(_webPort.text),
      'api_container_name': _apiCont.text.trim(),
      'api_port': _apiPort.text.isEmpty ? null : int.tryParse(_apiPort.text),
    });
    if (mounted) {
      setState(() => _saving = false);
      await widget.onRefresh();
      _snack(context, 'Hébergement mis à jour', success: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _TabScaffold(
      children: [
        _SectionTitle('Hébergement Web'),
        const SizedBox(height: 4),
        const Text(
            'Conteneur Docker servant le frontend statique ou l\'application web.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
        const SizedBox(height: 14),
        _FormRow(children: [
          _FormField('Nom du conteneur', _webCont, hint: 'ondes_site_mon-app'),
          _FormField('Port hôte', _webPort, hint: '3000', number: true),
        ]),
        const SizedBox(height: 24),
        _SectionTitle('Hébergement API'),
        const SizedBox(height: 4),
        const Text('Conteneur Docker servant l\'API backend.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
        const SizedBox(height: 14),
        _FormRow(children: [
          _FormField('Nom du conteneur', _apiCont, hint: 'ondes_api_mon-app'),
          _FormField('Port hôte', _apiPort, hint: '8000', number: true),
        ]),
        const SizedBox(height: 28),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(AppColors.background)))
              : const Text('Enregistrer'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 4 — Domaine & SSL
// ─────────────────────────────────────────────────────────────────────────────
class _DomainSslTab extends StatefulWidget {
  final Map<String, dynamic> site;
  final Future<void> Function() onRefresh;
  const _DomainSslTab({required this.site, required this.onRefresh});

  @override
  State<_DomainSslTab> createState() => _DomainSslTabState();
}

class _DomainSslTabState extends State<_DomainSslTab> {
  late TextEditingController _domainCtrl;
  late TextEditingController _emailCtrl;
  bool _requesting = false;
  String? _certResult;

  @override
  void initState() {
    super.initState();
    _domainCtrl = TextEditingController(text: widget.site['domain'] ?? '');
    _emailCtrl = TextEditingController(text: widget.site['ssl_email'] ?? '');
  }

  @override
  void dispose() {
    _domainCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _requestCert() async {
    if (_domainCtrl.text.isEmpty || _emailCtrl.text.isEmpty) {
      _snack(context, 'Domaine et email requis');
      return;
    }
    setState(() {
      _requesting = true;
      _certResult = null;
    });
    final result = await context.read<SitesProvider>().requestCertbot(
          widget.site['id'] as int,
          _domainCtrl.text.trim(),
          _emailCtrl.text.trim(),
        );
    if (mounted) {
      setState(() {
        _requesting = false;
        _certResult = result['status'] == 'success'
            ? '✓ Certificat obtenu avec succès'
            : '✗ ${result['message'] ?? result['error'] ?? 'Erreur inconnue'}';
      });
      if (result['status'] == 'success') await widget.onRefresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ssl = widget.site['ssl_enabled'] as bool? ?? false;
    final domain = widget.site['domain'] ?? '';

    return _TabScaffold(
      children: [
        // ── DNS Guide ─────────────────────────────────────────────────────
        _SectionTitle('Configuration DNS'),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Pour lier votre domaine, ajoutez un enregistrement A chez votre registrar :',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 14),
              _DnsRow(
                  type: 'A',
                  name: domain.isNotEmpty ? domain : '@',
                  value: 'IP_DE_VOTRE_SERVEUR'),
              const SizedBox(height: 8),
              _DnsRow(type: 'A', name: 'www', value: 'IP_DE_VOTRE_SERVEUR'),
              const SizedBox(height: 12),
              const Text(
                'Remplacez IP_DE_VOTRE_SERVEUR par l\'adresse IP publique de votre VPS. La propagation DNS peut prendre jusqu\'à 24h.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        // ── SSL / Certbot ─────────────────────────────────────────────────
        Row(
          children: [
            _SectionTitle('Certificat SSL (Let\'s Encrypt)'),
            const SizedBox(width: 10),
            if (ssl)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.accentGreen.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                  border:
                      Border.all(color: AppColors.accentGreen.withOpacity(0.3)),
                ),
                child: const Text('Actif',
                    style: TextStyle(
                        color: AppColors.accentGreen,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Certbot génère et renouvelle automatiquement un certificat TLS gratuit via Let\'s Encrypt. Le domaine doit déjà pointer vers ce serveur.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
        const SizedBox(height: 16),
        _FormRow(children: [
          _FormField('Domaine', _domainCtrl, hint: 'app.example.com'),
          _FormField('Email admin', _emailCtrl, hint: 'admin@example.com'),
        ]),
        const SizedBox(height: 20),
        ElevatedButton.icon(
          onPressed: _requesting ? null : _requestCert,
          icon: _requesting
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(AppColors.background)))
              : const Icon(Icons.security_outlined, size: 16),
          label: Text(_requesting
              ? 'En cours…'
              : ssl
                  ? 'Renouveler le certificat'
                  : 'Obtenir un certificat'),
        ),
        if (_certResult != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _certResult!.startsWith('✓')
                  ? AppColors.accentGreen.withOpacity(0.1)
                  : AppColors.accentRed.withOpacity(0.1),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _certResult!.startsWith('✓')
                    ? AppColors.accentGreen.withOpacity(0.3)
                    : AppColors.accentRed.withOpacity(0.3),
              ),
            ),
            child: Text(
              _certResult!,
              style: TextStyle(
                color: _certResult!.startsWith('✓')
                    ? AppColors.accentGreen
                    : AppColors.accentRed,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _DnsRow extends StatefulWidget {
  final String type, name, value;
  const _DnsRow({required this.type, required this.name, required this.value});

  @override
  State<_DnsRow> createState() => _DnsRowState();
}

class _DnsRowState extends State<_DnsRow> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.accent.withOpacity(0.15),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(widget.type,
                style: const TextStyle(
                    color: AppColors.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(widget.name,
                style: GoogleFonts.jetBrainsMono(
                    color: AppColors.textPrimary, fontSize: 13)),
          ),
          Text('→', style: const TextStyle(color: AppColors.textMuted)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(widget.value,
                style: GoogleFonts.jetBrainsMono(
                    color: AppColors.textSecondary, fontSize: 13)),
          ),
          GestureDetector(
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: widget.value));
              setState(() => _copied = true);
              await Future.delayed(const Duration(seconds: 2));
              if (mounted) setState(() => _copied = false);
            },
            child: Icon(
              _copied ? Icons.check : Icons.copy_outlined,
              size: 14,
              color: _copied ? AppColors.accentGreen : AppColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 5 — NGINX
// ─────────────────────────────────────────────────────────────────────────────
class _NginxTab extends StatefulWidget {
  final Map<String, dynamic> site;
  const _NginxTab({required this.site});

  @override
  State<_NginxTab> createState() => _NginxTabState();
}

class _NginxTabState extends State<_NginxTab> {
  String? _config;
  bool _loading = false;
  bool _applying = false;

  Future<void> _preview() async {
    setState(() {
      _loading = true;
      _config = null;
    });
    final cfg = await context
        .read<SitesProvider>()
        .nginxPreview(widget.site['id'] as int);
    if (mounted)
      setState(() {
        _loading = false;
        _config = cfg;
      });
  }

  Future<void> _apply() async {
    setState(() => _applying = true);
    final result = await context
        .read<SitesProvider>()
        .applyNginx(widget.site['id'] as int);
    if (mounted) {
      setState(() => _applying = false);
      if (result['status'] == 'success') {
        _snack(context, 'Configuration NGINX appliquée et rechargée',
            success: true);
      } else {
        _snack(context, result['message'] ?? result['error'] ?? 'Erreur NGINX');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _TabScaffold(
      children: [
        _SectionTitle('Reverse Proxy NGINX'),
        const SizedBox(height: 4),
        const Text(
          'Génère un bloc server{} NGINX qui redirige le trafic du domaine vers votre conteneur.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            ElevatedButton.icon(
              onPressed: _loading ? null : _preview,
              icon: _loading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation(AppColors.background)))
                  : const Icon(Icons.preview_outlined, size: 16),
              label: const Text('Aperçu de la config'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: (_config == null || _applying) ? null : _apply,
              icon: _applying
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation(AppColors.textPrimary)))
                  : const Icon(Icons.check_circle_outline, size: 16),
              label: const Text('Appliquer & Recharger'),
            ),
          ],
        ),
        if (_config != null) ...[
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('nginx.conf',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
              GestureDetector(
                onTap: () => Clipboard.setData(ClipboardData(text: _config!)),
                child: const Row(children: [
                  Icon(Icons.copy_outlined,
                      size: 13, color: AppColors.textMuted),
                  SizedBox(width: 4),
                  Text('Copier',
                      style:
                          TextStyle(color: AppColors.textMuted, fontSize: 12)),
                ]),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.border),
            ),
            child: SelectableText(
              _config!,
              style: GoogleFonts.jetBrainsMono(
                  color: const Color(0xFF22C55E), fontSize: 13, height: 1.6),
            ),
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared helpers
// ─────────────────────────────────────────────────────────────────────────────

class _TabScaffold extends StatelessWidget {
  final List<Widget> children;
  const _TabScaffold({required this.children});

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
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
            fontSize: 14,
            fontWeight: FontWeight.w600),
      );
}

class _FormRow extends StatelessWidget {
  final List<Widget> children;
  const _FormRow({required this.children});

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    for (int i = 0; i < children.length; i++) {
      if (i > 0) items.add(const SizedBox(width: 14));
      items.add(Expanded(child: children[i]));
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: items);
  }
}

class _FormField extends StatelessWidget {
  final String label;
  final TextEditingController ctrl;
  final String? hint;
  final bool number;
  const _FormField(this.label, this.ctrl, {this.hint, this.number = false});

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
            keyboardType: number ? TextInputType.number : TextInputType.text,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
            decoration: InputDecoration(hintText: hint),
          ),
        ],
      );
}

class _Select extends StatelessWidget {
  final String label, value;
  final Map<String, String> items;
  final void Function(String) onChanged;
  const _Select(
      {required this.label,
      required this.value,
      required this.items,
      required this.onChanged});

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
          DropdownButtonFormField<String>(
            value: value,
            dropdownColor: AppColors.surfaceVariant,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
            items: items.entries
                .map(
                    (e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                .toList(),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
            decoration: InputDecoration(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: AppColors.border)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: AppColors.border)),
            ),
          ),
        ],
      );
}

class _StatusPill extends StatelessWidget {
  final String status;
  const _StatusPill(this.status);

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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(status,
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

void _snack(BuildContext context, String msg, {bool success = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg),
    backgroundColor: success ? AppColors.accentGreen : AppColors.accentRed,
  ));
}

extension _ListInsertBetween<T> on List<T> {
  List<T> insertBetween(T separator) {
    final result = <T>[];
    for (int i = 0; i < length; i++) {
      if (i > 0) result.add(separator);
      result.add(this[i]);
    }
    return result;
  }
}
