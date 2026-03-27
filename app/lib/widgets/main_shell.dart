import 'dart:ui';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../providers/auth_provider.dart';
import '../providers/github_provider.dart';
import '../providers/stacks_provider.dart';
import '../screens/github_screen.dart';
import '../screens/dashboard_screen.dart';
import '../screens/docker_manager_screen.dart';
import '../screens/terminal_screen.dart';
import '../screens/infrastructure_canvas_screen.dart';
import 'sidebar.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  /// Inner Navigator key — scoped to the content area (right of the sidebar).
  ///
  /// Push detail screens here instead of using Navigator.push(context, …)
  /// so that routes stay within the content panel and never cover the sidebar
  /// or the macOS traffic-light buttons.
  ///
  ///   MainShell.contentNavKey.currentState!.push(
  ///     MaterialPageRoute(builder: (_) => StackDetailScreen(stackId: id)),
  ///   );
  static final contentNavKey = GlobalKey<NavigatorState>();

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  // ValueNotifier drives which tab is shown; changing it does NOT rebuild the
  // Navigator widget (avoiding a route-stack reset), only _TabRoot rebuilds.
  final _tabNotifier = ValueNotifier<int>(0);

  static const List<Widget> _screens = [
    GitHubScreen(),
    DashboardScreen(),
    DockerManagerScreen(),
    InfrastructureCanvasScreen(),
    TerminalScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final gh = context.read<GitHubProvider>();
      await gh.loadProfile();
      if (gh.connected && gh.repos.isEmpty) gh.fetchRepos();
      if (mounted) context.read<StacksProvider>().fetchStacks();
    });
  }

  @override
  void dispose() {
    _tabNotifier.dispose();
    super.dispose();
  }

  void _navigate(int index) {
    if (_tabNotifier.value == index) return;
    // Pop any detail routes that might be open before switching tabs.
    while (MainShell.contentNavKey.currentState?.canPop() == true) {
      MainShell.contentNavKey.currentState!.pop();
    }
    _tabNotifier.value = index;
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 700;
    final isMacOS  = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

    final bg = isMacOS
        ? const BoxDecoration(color: Colors.transparent)
        : const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF0D1117), Color(0xFF0D1520), Color(0xFF0D1117)],
            ),
          );

    // The content navigator wraps the IndexedStack.  Pushing a route to
    // contentNavKey renders the new route INSIDE the content panel only —
    // the sidebar is unaffected and the window chrome is never covered.
    final contentNavigator = Navigator(
      key: MainShell.contentNavKey,
      onGenerateRoute: (_) => PageRouteBuilder(
        pageBuilder: (_, __, ___) => _TabRoot(
          tabNotifier: _tabNotifier,
          screens: _screens,
        ),
        transitionDuration: Duration.zero,
      ),
    );

    return Stack(
      children: [
        // ── Background ─────────────────────────────────────────────────
        Positioned.fill(child: Container(decoration: bg)),
        if (!isMacOS) ...[
          Positioned(
            top: -120, right: -120,
            child: _AccentBlob(size: 420, color: AppColors.accentBlue.withValues(alpha: 0.06)),
          ),
          Positioned(
            bottom: -80, left: -80,
            child: _AccentBlob(size: 320, color: AppColors.accentPurple.withValues(alpha: 0.04)),
          ),
        ],
        // ── Shell ───────────────────────────────────────────────────────
        if (isMobile)
          ValueListenableBuilder<int>(
            valueListenable: _tabNotifier,
            builder: (_, idx, __) => Scaffold(
              backgroundColor: Colors.transparent,
              body: contentNavigator,
              bottomNavigationBar: _GlassBottomBar(
                index: idx,
                onTap: _navigate,
                onLogout: () => context.read<AuthProvider>().logout(),
              ),
            ),
          )
        else
          Scaffold(
            backgroundColor: Colors.transparent,
            body: Row(
              children: [
                ValueListenableBuilder<int>(
                  valueListenable: _tabNotifier,
                  builder: (_, idx, __) => Sidebar(
                    selectedIndex: idx,
                    onNavigate: _navigate,
                  ),
                ),
                Expanded(child: contentNavigator),
              ],
            ),
          ),
      ],
    );
  }
}

// ─── Root route of the content Navigator ─────────────────────────────────────
/// Listens to [tabNotifier] and rebuilds the IndexedStack on tab changes
/// without disturbing the outer Navigator stack.
class _TabRoot extends StatelessWidget {
  final ValueNotifier<int> tabNotifier;
  final List<Widget> screens;
  const _TabRoot({required this.tabNotifier, required this.screens});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: tabNotifier,
      builder: (_, idx, __) =>
          IndexedStack(index: idx, children: screens),
    );
  }
}

// ─── Accent blob ──────────────────────────────────────────────────────────────
class _AccentBlob extends StatelessWidget {
  final double size;
  final Color color;
  const _AccentBlob({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [color, Colors.transparent]),
      ),
    );
  }
}

// ─── Glass bottom bar (mobile) ────────────────────────────────────────────────
class _GlassBottomBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;
  final VoidCallback onLogout;

  const _GlassBottomBar({
    required this.index,
    required this.onTap,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          decoration: const BoxDecoration(
            color: GlassTokens.sidebarBg,
            border: Border(top: BorderSide(color: GlassTokens.cardBorder, width: 1)),
          ),
          child: NavigationBar(
            selectedIndex: index,
            onDestinationSelected: onTap,
            backgroundColor: Colors.transparent,
            indicatorColor: AppColors.accent.withValues(alpha: 0.15),
            shadowColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.hub_outlined),
                selectedIcon: Icon(Icons.hub),
                label: 'GitHub',
              ),
              NavigationDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard),
                label: 'Dashboard',
              ),
              NavigationDestination(
                icon: Icon(Icons.inventory_2_outlined),
                selectedIcon: Icon(Icons.inventory_2),
                label: 'Containers',
              ),
              NavigationDestination(
                icon: Icon(Icons.account_tree_outlined),
                selectedIcon: Icon(Icons.account_tree),
                label: 'Canvas',
              ),
              NavigationDestination(
                icon: Icon(Icons.terminal_outlined),
                selectedIcon: Icon(Icons.terminal),
                label: 'Terminal',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
