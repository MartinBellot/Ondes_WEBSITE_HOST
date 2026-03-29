import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:universal_platform/universal_platform.dart';
import '../theme/app_theme.dart';
import '../providers/auth_provider.dart';
import '../providers/github_provider.dart';
import '../providers/stacks_provider.dart';
import '../screens/github_screen.dart';
import '../screens/dashboard_screen.dart';
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
    InfrastructureCanvasScreen(),
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
    final isMacOS  = UniversalPlatform.isMacOS;

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
              body: Stack(
                children: [
                  contentNavigator,
                  Positioned(
                    bottom: 0, left: 0, right: 0,
                    child: _GlassBottomBar(
                      index: idx,
                      onTap: _navigate,
                      onLogout: () => context.read<AuthProvider>().logout(),
                    ),
                  ),
                ],
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
typedef _NavItem = ({IconData icon, IconData activeIcon, String label});

class _GlassBottomBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;
  final VoidCallback onLogout;

  const _GlassBottomBar({
    required this.index,
    required this.onTap,
    required this.onLogout,
  });

  static const List<_NavItem> _items = [
    (icon: Icons.hub_outlined,          activeIcon: Icons.hub,          label: 'GitHub'),
    (icon: Icons.dashboard_outlined,    activeIcon: Icons.dashboard,    label: 'Dashboard'),
    (icon: Icons.account_tree_outlined, activeIcon: Icons.account_tree, label: 'Canvas'),
  ];

  Widget _buildNavItem(BuildContext context, int itemIndex) {
    final item = _items[itemIndex];
    final isSelected = index == itemIndex;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: isSelected ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      builder: (ctx, value, _) {
        return GestureDetector(
          onTap: () => onTap(itemIndex),
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: 70,
            height: 70,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedScale(
                  scale: 1.0 + (value * 0.15),
                  duration: const Duration(milliseconds: 300),
                  child: Icon(
                    isSelected ? item.activeIcon : item.icon,
                    color: Color.lerp(
                      Colors.white.withValues(alpha: 0.5),
                      Colors.white,
                      value,
                    ),
                    size: 26,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  item.label,
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    color: Color.lerp(
                      Colors.white.withValues(alpha: 0.5),
                      Colors.white,
                      value,
                    )!,
                    letterSpacing: isSelected ? 0.5 : 0,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: Container(
        height: 75,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.3),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.shadow.withValues(alpha: 0.2),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(
            _items.length,
            (i) => _buildNavItem(context, i),
          ),
        ),
      ),
    );
  }
}
