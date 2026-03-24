import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:timeago/timeago.dart' as timeago;
import '../providers/github_provider.dart';
import '../utils/oauth_launcher.dart';
import '../providers/stacks_provider.dart';
import '../theme/app_theme.dart';
import 'stack_detail_screen.dart';

class GitHubScreen extends StatefulWidget {
  const GitHubScreen({super.key});

  @override
  State<GitHubScreen> createState() => _GitHubScreenState();
}

class _GitHubScreenState extends State<GitHubScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;

  // ── Repo / branch / compose selection state ──────────────────────────────
  Map<String, dynamic>? _selectedRepo;
  String? _selectedBranch;
  String? _selectedComposeFile;
  Map<String, String> _envVars = {};
  bool _isDeploying = false;

  final _repoSearchCtrl = TextEditingController();
  String _repoFilter = '';
  Timer? _authPollTimer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final gh = context.read<GitHubProvider>();
      final stacks = context.read<StacksProvider>();
      // Fetch repos if profile is already loaded (e.g. navigating back to this tab).
      if (gh.connected && gh.repos.isEmpty) gh.fetchRepos();
      if (stacks.stacks.isEmpty) stacks.fetchStacks();
      // Also listen for the profile finishing load (covers cold-start race condition).
      gh.addListener(_onGitHubProviderChange);
    });
  }

  void _onGitHubProviderChange() {
    final gh = context.read<GitHubProvider>();
    if (gh.connected && gh.repos.isEmpty && !gh.isLoadingRepos) {
      gh.fetchRepos();
    }
  }

  @override
  void dispose() {
    _authPollTimer?.cancel();
    _tabController.dispose();
    _repoSearchCtrl.dispose();
    // Remove the profile-change listener safely.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Provider may already be disposed, wrap in try.
      try {
        context.read<GitHubProvider>().removeListener(_onGitHubProviderChange);
      } catch (_) {}
    });
    super.dispose();
  }

  // ── OAuth ─────────────────────────────────────────────────────────────────

  Future<void> _connectGitHub() async {
    final gh = context.read<GitHubProvider>();
    final data = await gh.requestAuthUrl();
    if (!gh.oauthConfigured) return;
    final url = data['auth_url'] as String;

    // Web: opens a popup and receives the result via postMessage.
    // Native: opens the system browser; we poll the profile endpoint.
    startOAuth(url, (success) async {
      if (!mounted) return;
      if (success) {
        await gh.onOAuthSuccess();
        if (mounted && gh.connected) _showConnectedSnack(gh.login);
      } else {
        _showErrorSnack();
      }
    });

    // On native platforms there is no popup/postMessage, so poll instead.
    if (!kIsWeb) _startAuthPolling(gh);
  }

  void _startAuthPolling(GitHubProvider gh) {
    _authPollTimer?.cancel();
    int attempts = 0;
    _authPollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      attempts++;
      await gh.loadProfile();
      if (!mounted) { timer.cancel(); return; }
      if (gh.connected) {
        timer.cancel();
        await gh.fetchRepos();
        if (mounted) _showConnectedSnack(gh.login);
      } else if (attempts >= 20) {
        // 60 seconds without success — give up silently.
        timer.cancel();
      }
    });
  }

  void _showConnectedSnack(String? login) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Connecté en tant que @${login ?? ''}'),
      backgroundColor: AppColors.accentGreen,
    ));
  }

  void _showErrorSnack() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Connexion GitHub refusée.'),
      backgroundColor: AppColors.accentRed,
    ));
  }

  // ── Repo click ─────────────────────────────────────────────────────────────

  void _selectRepo(Map<String, dynamic> repo) {
    setState(() {
      _selectedRepo = repo;
      _selectedBranch = null;
      _selectedComposeFile = null;
      _envVars = {};
    });
    final parts = (repo['full_name'] as String).split('/');
    context.read<GitHubProvider>().fetchBranches(parts[0], parts[1]);
    _showRepoBuildSheet(repo);
  }

  // ── Bottom sheet: branch → compose → env → deploy ────────────────────────

  void _showRepoBuildSheet(Map<String, dynamic> repo) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _RepoBuildSheet(
        repo: repo,
        onDeploy: _deployStack,
      ),
    );
  }

  Future<void> _deployStack(
      Map<String, dynamic> repo,
      String branch,
      String composeFile,
      Map<String, String> envVars,
      String projectName) async {
    setState(() => _isDeploying = true);
    final parts = (repo['full_name'] as String).split('/');
    final stack = await context.read<StacksProvider>().createStack({
      'name': projectName,
      'github_repo': repo['full_name'],
      'github_branch': branch,
      'compose_file': composeFile,
      'env_vars': envVars,
    });
    if (!mounted) return;
    if (stack == null) {
      setState(() => _isDeploying = false);
      return;
    }
    final stackId = (stack['id'] as num?)?.toInt();
    if (stackId == null) {
      setState(() => _isDeploying = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Erreur : id du stack manquant dans la réponse.'),
        backgroundColor: AppColors.accentRed,
      ));
      return;
    }
    // Close the sheet first, then navigate.
    Navigator.pop(context);
    _tabController.animateTo(1);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StackDetailScreen(stackId: stackId),
      ),
    );
    // Trigger deploy in background (WebSocket in StackDetailScreen will stream logs).
    context.read<StacksProvider>().deployStack(stackId);
    setState(() => _isDeploying = false);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final gh = context.watch<GitHubProvider>();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: const Text('GitHub',
            style: TextStyle(color: AppColors.textPrimary)),
        bottom: gh.connected
            ? TabBar(
                controller: _tabController,
                labelColor: AppColors.accent,
                unselectedLabelColor: AppColors.textSecondary,
                indicatorColor: AppColors.accent,
                tabs: const [
                  Tab(text: 'Dépôts'),
                  Tab(text: 'Mes Stacks'),
                ],
              )
            : null,
      ),
      body: gh.isProfileLoading
          ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
          : gh.connected
              ? TabBarView(
                  controller: _tabController,
                  children: [
                    _RepoListTab(
                      searchCtrl: _repoSearchCtrl,
                      filter: _repoFilter,
                      onFilterChanged: (v) =>
                          setState(() => _repoFilter = v.toLowerCase()),
                      onRepoTap: _selectRepo,
                    ),
                    const _StacksTab(),
                  ],
                )
              : _NotConnectedView(onConnect: _connectGitHub),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Not-connected view (handles both "wizard" and "connect" states)
// ─────────────────────────────────────────────────────────────────────────────

class _NotConnectedView extends StatefulWidget {
  final VoidCallback onConnect;
  const _NotConnectedView({required this.onConnect});

  @override
  State<_NotConnectedView> createState() => _NotConnectedViewState();
}

class _NotConnectedViewState extends State<_NotConnectedView> {
  final _clientIdCtrl = TextEditingController();
  final _clientSecretCtrl = TextEditingController();
  bool _secretVisible = false;
  bool _showWizard = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<GitHubProvider>().loadConfig();
    });
  }

  @override
  void dispose() {
    _clientIdCtrl.dispose();
    _clientSecretCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final id = _clientIdCtrl.text.trim();
    final secret = _clientSecretCtrl.text.trim();
    if (id.isEmpty || secret.isEmpty) {
      setState(() => _saveError = 'Veuillez remplir les deux champs.');
      return;
    }
    final err = await context.read<GitHubProvider>().saveConfig(id, secret);
    if (!mounted) return;
    setState(() {
      _saveError = err;
      if (err == null) _showWizard = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final gh = context.watch<GitHubProvider>();

    if (gh.isConfigLoading) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.accent));
    }

    if (!gh.oauthConfigured || _showWizard) {
      return _buildWizard(gh);
    }

    return _buildConnectView(gh);
  }

  // ── Wizard ──────────────────────────────────────────────────────────────

  Widget _buildWizard(GitHubProvider gh) {
    final callbackUrl = gh.callbackUrl ?? '';

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Back button only when reconfiguring
              if (_showWizard)
                TextButton.icon(
                  onPressed: () => setState(() => _showWizard = false),
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: const Text('Retour'),
                  style: TextButton.styleFrom(
                      foregroundColor: AppColors.textSecondary),
                ),
              const SizedBox(height: 8),
              const Row(children: [
                Icon(Icons.settings_outlined,
                    size: 28, color: AppColors.accent),
                SizedBox(width: 12),
                Text('Configuration OAuth GitHub',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary)
                ),
              ]),
              const SizedBox(height: 8),
              const Text(
                'Créez une OAuth App sur GitHub et copiez les identifiants '
                'ci-dessous. Aucun fichier .env requis.',
                style:
                    TextStyle(fontSize: 14, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 24),

              // Step 1 — Navigate to GitHub
              const _WizardStep(
                number: '1',
                title: 'Ouvrir GitHub Developer Settings',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _InstructionRow(
                      icon: Icons.open_in_new,
                      text: 'github.com → Settings → Developer settings → OAuth Apps → New OAuth App',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Step 2 — Fill the form
               _WizardStep(
                number: '2',
                title: 'Remplir le formulaire GitHub',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Application name
                    const _FormFieldGuide(
                      label: 'Application name',
                      hint: 'Le nom qu\'affichera GitHub aux utilisateurs lors de la demande d\'autorisation.',
                      value: 'Ondes HOST',
                      copiable: true,
                    ),
                    const SizedBox(height: 12),
                    // Homepage URL
                    const _FormFieldGuide(
                      label: 'Homepage URL',
                      hint: 'URL principale de l\'application (doit être une URL valide).',
                      value: 'http://localhost:3000',
                      copiable: true,
                    ),
                    const SizedBox(height: 12),
                    // Application description
                    const _FormFieldGuide(
                      label: 'Application description',
                      hint: 'Optionnelle — description affichée sur la page d\'autorisation.',
                      value: 'Self-hosted infrastructure dashboard',
                      copiable: true,
                    ),
                    const SizedBox(height: 12),
                    // Authorization callback URL
                    _FormFieldGuide(
                      label: 'Authorization callback URL',
                      hint: 'URL vers laquelle GitHub redirige après l\'authentification. Doit correspondre exactement.',
                      value: callbackUrl.isNotEmpty ? callbackUrl : 'http://localhost:8000/api/github/oauth/callback/',
                      copiable: true,
                      highlighted: true,
                    ),
                    const SizedBox(height: 12),
                    // Enable Device Flow
                    const _InstructionRow(
                      icon: Icons.toggle_off_outlined,
                      text: 'Enable Device Flow — laisser décoché (non requis pour cette application).',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Step 3 — Enter credentials
              _WizardStep(
                number: '3',
                title: 'Copiez vos identifiants ici',
                child: Column(
                  children: [
                    TextField(
                      controller: _clientIdCtrl,
                      style:
                          const TextStyle(color: AppColors.textPrimary),
                      decoration: _inputDecoration('Client ID'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _clientSecretCtrl,
                      obscureText: !_secretVisible,
                      style:
                          const TextStyle(color: AppColors.textPrimary),
                      decoration: _inputDecoration('Client Secret').copyWith(
                        suffixIcon: IconButton(
                          icon: Icon(
                            _secretVisible
                                ? Icons.visibility_off
                                : Icons.visibility,
                            color: AppColors.textSecondary,
                          ),
                          onPressed: () =>
                              setState(() => _secretVisible = !_secretVisible),
                        ),
                      ),
                    ),
                    if (_saveError != null) ...[
                      const SizedBox(height: 8),
                      Text(_saveError!,
                          style: const TextStyle(
                              color: AppColors.accentRed, fontSize: 13)),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: gh.isConfigSaving ? null : _save,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: gh.isConfigSaving
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white))
                            : const Text('Enregistrer et continuer',
                                style: TextStyle(fontSize: 15)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: AppColors.textSecondary),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.accent.withOpacity(0.3)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.accent.withOpacity(0.3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.accent),
        ),
      );

  // ── Connect button ───────────────────────────────────────────────────────

  Widget _buildConnectView(GitHubProvider gh) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.hub_outlined, size: 72, color: AppColors.accent),
            const SizedBox(height: 20),
            const Text('Connectez votre compte GitHub',
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 12),
            const Text(
              'Parcourez vos dépôts, sélectionnez un docker-compose '
              'et déployez en un clic.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: widget.onConnect,
              icon: const Icon(Icons.hub),
              label: const Text('Se connecter avec GitHub'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                padding: const EdgeInsets.symmetric(
                    horizontal: 28, vertical: 14),
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () {
                _clientIdCtrl.text = gh.clientId ?? '';
                setState(() => _showWizard = true);
              },
              icon: const Icon(Icons.settings_outlined, size: 16),
              label: const Text('Reconfigurer OAuth App'),
              style: TextButton.styleFrom(
                  foregroundColor: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Wizard helper widgets ─────────────────────────────────────────────────────

/// A single GitHub form field guide row: label + hint + optional copiable value.
class _FormFieldGuide extends StatelessWidget {
  final String label;
  final String hint;
  final String value;
  final bool copiable;
  final bool highlighted;

  const _FormFieldGuide({
    required this.label,
    required this.hint,
    required this.value,
    this.copiable = false,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          if (highlighted)
            const Icon(Icons.star, size: 13, color: AppColors.accent)
          else
            const Icon(Icons.label_outline, size: 13, color: AppColors.textSecondary),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: highlighted ? AppColors.accent : AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ]),
        const SizedBox(height: 3),
        Text(hint,
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 6),
        if (copiable)
          _CopyableField(value: value, compact: true)
        else
          Text(value,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
      ],
    );
  }
}

/// A simple instruction row with an icon.
class _InstructionRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InstructionRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: AppColors.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        ),
      ],
    );
  }
}

class _WizardStep extends StatelessWidget {
  final String number;
  final String title;
  final Widget child;

  const _WizardStep(
      {required this.number, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accent.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            CircleAvatar(
              radius: 13,
              backgroundColor: AppColors.accent,
              child: Text(number,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13)),
            ),
            const SizedBox(width: 10),
            Text(title,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 15)),
          ]),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _CopyableField extends StatelessWidget {
  final String value;
  final bool compact;
  const _CopyableField({required this.value, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: 10, vertical: compact ? 6 : 10),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(value,
                style: TextStyle(
                    color: AppColors.accent,
                    fontFamily: 'monospace',
                    fontSize: compact ? 12 : 13)),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 16, color: AppColors.textSecondary),
            tooltip: 'Copier',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Copié !'),
                    duration: Duration(seconds: 2)),
              );
            },
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Repo list tab
// ─────────────────────────────────────────────────────────────────────────────

class _RepoListTab extends StatelessWidget {
  final TextEditingController searchCtrl;
  final String filter;
  final ValueChanged<String> onFilterChanged;
  final ValueChanged<Map<String, dynamic>> onRepoTap;

  const _RepoListTab({
    required this.searchCtrl,
    required this.filter,
    required this.onFilterChanged,
    required this.onRepoTap,
  });

  @override
  Widget build(BuildContext context) {
    final gh = context.watch<GitHubProvider>();

    final filtered = gh.repos.where((r) {
      final name = (r['full_name'] as String? ?? '').toLowerCase();
      final desc = (r['description'] as String? ?? '').toLowerCase();
      return name.contains(filter) || desc.contains(filter);
    }).toList();

    return Column(
      children: [
        // Header with user info + search
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              if (gh.avatarUrl != null)
                CircleAvatar(
                  backgroundImage: NetworkImage(gh.avatarUrl!),
                  radius: 18,
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('@${gh.login ?? ''}',
                        style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600)),
                    if (gh.name != null)
                      Text(gh.name!,
                          style: const TextStyle(
                              color: AppColors.textSecondary, fontSize: 12)),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: () => context.read<GitHubProvider>().disconnect(),
                icon: const Icon(Icons.link_off, size: 16),
                label: const Text('Déconnecter'),
                style: TextButton.styleFrom(
                    foregroundColor: AppColors.accentRed, iconColor: AppColors.accentRed),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: searchCtrl,
            onChanged: onFilterChanged,
            decoration: InputDecoration(
              hintText: 'Rechercher un dépôt…',
              hintStyle:
                  const TextStyle(color: AppColors.textSecondary),
              prefixIcon: const Icon(Icons.search,
                  color: AppColors.textSecondary, size: 20),
              filled: true,
              fillColor: AppColors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.accent),
              ),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
            ),
            style: const TextStyle(color: AppColors.textPrimary),
          ),
        ),
        const SizedBox(height: 8),
        if (gh.isLoadingRepos)
          const Expanded(
              child: Center(
                  child: CircularProgressIndicator(
                      color: AppColors.accent)))
        else
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 8),
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (_, i) =>
                  _RepoCard(repo: filtered[i], onTap: onRepoTap),
            ),
          ),
      ],
    );
  }
}

class _RepoCard extends StatelessWidget {
  final dynamic repo;
  final ValueChanged<Map<String, dynamic>> onTap;

  const _RepoCard({required this.repo, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final name = repo['full_name'] as String? ?? '';
    final desc = repo['description'] as String? ?? '';
    final isPrivate = repo['private'] as bool? ?? false;
    final lang = repo['language'] as String? ?? '';
    final pushed = repo['pushed_at'] as String?;
    final pushedAgo = pushed != null
        ? timeago.format(DateTime.parse(pushed), locale: 'fr')
        : '';

    return InkWell(
      onTap: () => onTap(Map<String, dynamic>.from(repo)),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.folder_outlined,
                    size: 18, color: AppColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(name,
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14)),
                ),
                if (isPrivate)
                  _Chip(
                      label: 'Privé',
                      color: AppColors.accentYellow.withOpacity(0.15),
                      textColor: AppColors.accentYellow),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right,
                    size: 18, color: AppColors.textSecondary),
              ],
            ),
            if (desc.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(desc,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12)),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                if (lang.isNotEmpty)
                  _Chip(
                      label: lang,
                      color: AppColors.accent.withOpacity(0.1),
                      textColor: AppColors.accent),
                const Spacer(),
                if (pushedAgo.isNotEmpty)
                  Text('Mis à jour $pushedAgo',
                      style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;

  const _Chip(
      {required this.label, required this.color, required this.textColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration:
          BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
      child: Text(label,
          style: TextStyle(
              color: textColor, fontSize: 11, fontWeight: FontWeight.w500)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Stacks tab
// ─────────────────────────────────────────────────────────────────────────────

class _StacksTab extends StatelessWidget {
  const _StacksTab();

  @override
  Widget build(BuildContext context) {
    final stacks = context.watch<StacksProvider>();

    if (stacks.isLoading) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (stacks.stacks.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.layers_outlined, size: 56, color: AppColors.textSecondary),
            SizedBox(height: 12),
            Text('Aucun stack déployé',
                style: TextStyle(
                    color: AppColors.textSecondary, fontSize: 16)),
            SizedBox(height: 8),
            Text("Sélectionnez un dépôt dans l'onglet Dépôts pour commencer.",
                style:
                    TextStyle(color: AppColors.textSecondary, fontSize: 13),
                textAlign: TextAlign.center),
          ],
        ),
      );
    }

    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: stacks.fetchStacks,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: stacks.stacks.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final s = stacks.stacks[i];
          return _StackCard(
            stack: s,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    StackDetailScreen(stackId: s['id'] as int),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _StackCard extends StatelessWidget {
  final dynamic stack;
  final VoidCallback onTap;

  const _StackCard({required this.stack, required this.onTap});

  static const _statusColors = {
    'running': AppColors.accentGreen,
    'error': AppColors.accentRed,
    'building': AppColors.accentYellow,
    'cloning': AppColors.accentYellow,
    'starting': AppColors.accentYellow,
    'stopped': AppColors.textSecondary,
    'idle': AppColors.textSecondary,
  };

  @override
  Widget build(BuildContext context) {
    final name = stack['name'] as String? ?? '';
    final status = stack['status'] as String? ?? 'idle';
    final repo = stack['github_repo'] as String? ?? '';
    final branch = stack['github_branch'] as String? ?? '';
    final color = _statusColors[status] ?? AppColors.textSecondary;
    final stacks = context.read<StacksProvider>();

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                  color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14)),
                  const SizedBox(height: 2),
                  Text('$repo@$branch',
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 12)),
                ],
              ),
            ),
            // Quick action: start/stop
            if (status == 'running')
              _QuickBtn(
                icon: Icons.stop,
                color: AppColors.accentRed,
                tooltip: 'Arrêter',
                onTap: () => stacks.stackAction(stack['id'] as int, 'stop'),
              )
            else if (status == 'stopped')
              _QuickBtn(
                icon: Icons.play_arrow,
                color: AppColors.accentGreen,
                tooltip: 'Démarrer',
                onTap: () => stacks.stackAction(stack['id'] as int, 'start'),
              ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right,
                size: 18, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _QuickBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  const _QuickBtn(
      {required this.icon,
      required this.color,
      required this.tooltip,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 20, color: color),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bottom sheet: branch → compose → env → project name → deploy
// ─────────────────────────────────────────────────────────────────────────────

typedef DeployCallback = Future<void> Function(
    Map<String, dynamic> repo,
    String branch,
    String composeFile,
    Map<String, String> envVars,
    String projectName);

class _RepoBuildSheet extends StatefulWidget {
  final Map<String, dynamic> repo;
  final DeployCallback onDeploy;

  const _RepoBuildSheet({required this.repo, required this.onDeploy});

  @override
  State<_RepoBuildSheet> createState() => _RepoBuildSheetState();
}

class _RepoBuildSheetState extends State<_RepoBuildSheet> {
  String? _branch;
  String? _composeFile;
  final Map<String, TextEditingController> _envControllers = {};
  final _nameCtrl = TextEditingController();
  bool _deploying = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl.text = widget.repo['name'] as String? ?? '';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    for (final c in _envControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onBranchSelected(String b) {
    setState(() {
      _branch = b;
      _composeFile = null;
      _envControllers.clear();
    });
    final parts = (widget.repo['full_name'] as String).split('/');
    context.read<GitHubProvider>().fetchComposeFiles(parts[0], parts[1], b);
  }

  void _onComposeSelected(String f) {
    setState(() => _composeFile = f);
    final template = context.read<GitHubProvider>().envTemplate;
    _envControllers.clear();
    for (final k in template.keys) {
      _envControllers[k] =
          TextEditingController(text: template[k]);
    }
  }

  Future<void> _deploy() async {
    if (_branch == null || _composeFile == null) return;
    setState(() => _deploying = true);
    final envVars = {
      for (final e in _envControllers.entries) e.key: e.value.text,
    };
    await widget.onDeploy(
        widget.repo, _branch!, _composeFile!, envVars, _nameCtrl.text.trim());
    setState(() => _deploying = false);
  }

  @override
  Widget build(BuildContext context) {
    final gh = context.watch<GitHubProvider>();
    final repoName = widget.repo['full_name'] as String? ?? '';

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (_, scrollCtrl) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          children: [
            // Handle
            const _SheetHandle(),
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Row(
                children: [
                  const Icon(Icons.folder_outlined,
                      color: AppColors.accent, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(repoName,
                        style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        color: AppColors.textSecondary),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.all(20),
                children: [
                  // ── Project name ──────────────────────────────
                  const _Label('Nom du projet'),
                  const SizedBox(height: 6),
                  _Input(controller: _nameCtrl, hint: 'mon-projet'),
                  const SizedBox(height: 20),

                  // ── Branch ───────────────────────────────────
                  const _Label('Branche'),
                  const SizedBox(height: 6),
                  if (gh.isLoadingBranches)
                    const _LoadingRow()
                  else if (gh.branches.isEmpty)
                    const Text('Aucune branche trouvée',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 13))
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: gh.branches
                          .map((b) => _ChoiceChip(
                                label: b,
                                selected: _branch == b,
                                onTap: () => _onBranchSelected(b),
                              ))
                          .toList(),
                    ),
                  const SizedBox(height: 20),

                  // ── Compose file ────────────────────────────
                  if (_branch != null) ...[
                    const _Label('Fichier docker-compose'),
                    const SizedBox(height: 6),
                    if (gh.isLoadingCompose)
                      const _LoadingRow()
                    else if (gh.composeFiles.isEmpty)
                      const Text(
                          'Aucun docker-compose trouvé dans ce dépôt',
                          style: TextStyle(
                              color: AppColors.accentYellow, fontSize: 13))
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: gh.composeFiles
                            .map((f) => _ChoiceChip(
                                  label: f,
                                  selected: _composeFile == f,
                                  onTap: () => _onComposeSelected(f),
                                ))
                            .toList(),
                      ),
                    const SizedBox(height: 20),
                  ],

                  // ── Env vars ────────────────────────────────
                  if (_composeFile != null &&
                      _envControllers.isNotEmpty) ...[
                    const _Label("Variables d'environnement"),
                    const SizedBox(height: 6),
                    ..._envControllers.entries.map((e) => Padding(
                          padding:
                              const EdgeInsets.only(bottom: 10),
                          child: Row(
                            children: [
                              Expanded(
                                  flex: 2,
                                  child: Text(e.key,
                                      style: const TextStyle(
                                          color: AppColors.textSecondary,
                                          fontSize: 13,
                                          fontFamily: 'monospace'))),
                              const SizedBox(width: 10),
                              Expanded(
                                  flex: 3,
                                  child: _Input(
                                      controller: e.value,
                                      hint: '')),
                            ],
                          ),
                        )),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
            // ── Deploy button ────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: (_branch != null &&
                          _composeFile != null &&
                          !_deploying)
                      ? _deploy
                      : null,
                  icon: _deploying
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white))
                      : const Icon(Icons.rocket_launch_outlined),
                  label:
                      Text(_deploying ? 'Déploiement…' : 'Déployer'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: const TextStyle(fontSize: 15),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Shared widgets ───────────────────────────────────────────────────────────

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();
  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 10),
          width: 40,
          height: 4,
          decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(4)),
        ),
      );
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8));
}

class _Input extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  const _Input({required this.controller, required this.hint});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: const TextStyle(
          color: AppColors.textPrimary, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle:
            const TextStyle(color: AppColors.textSecondary),
        filled: true,
        fillColor: AppColors.background,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:
              const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:
              const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:
              const BorderSide(color: AppColors.accent),
        ),
        contentPadding: const EdgeInsets.symmetric(
            horizontal: 12, vertical: 10),
      ),
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ChoiceChip(
      {required this.label,
      required this.selected,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent.withOpacity(0.2)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.border,
          ),
        ),
        child: Text(label,
            style: TextStyle(
                color: selected
                    ? AppColors.accent
                    : AppColors.textSecondary,
                fontSize: 13,
                fontWeight: selected
                    ? FontWeight.w600
                    : FontWeight.normal)),
      ),
    );
  }
}

class _LoadingRow extends StatelessWidget {
  const _LoadingRow();
  @override
  Widget build(BuildContext context) => const Row(
        children: [
          SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.accent)),
          SizedBox(width: 10),
          Text('Chargement…',
              style: TextStyle(
                  color: AppColors.textSecondary, fontSize: 13)),
        ],
      );
}
