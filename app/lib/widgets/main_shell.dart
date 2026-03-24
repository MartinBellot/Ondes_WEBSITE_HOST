import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../providers/auth_provider.dart';
import '../screens/sites_screen.dart';
import '../screens/dashboard_screen.dart';
import '../screens/docker_manager_screen.dart';
import '../screens/terminal_screen.dart';
import 'sidebar.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  // All tab screens — kept alive simultaneously via IndexedStack
  static const List<Widget> _screens = [
    SitesScreen(),
    DashboardScreen(),
    DockerManagerScreen(),
    TerminalScreen(),
  ];

  void _navigate(int index) {
    if (index == _index) return;
    setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 700;

    if (isMobile) {
      return Scaffold(
        body: IndexedStack(
          index: _index,
          children: _screens,
        ),
        bottomNavigationBar: _AppBottomBar(
          index: _index,
          onTap: _navigate,
          onLogout: () => context.read<AuthProvider>().logout(),
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          Sidebar(
            selectedIndex: _index,
            onNavigate: _navigate,
          ),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: _screens,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Bottom navigation bar (mobile only) ─────────────────────────────────────
class _AppBottomBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;
  final VoidCallback onLogout;

  const _AppBottomBar({
    required this.index,
    required this.onTap,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: onTap,
        backgroundColor: AppColors.surface,
        // ignore: deprecated_member_use
        indicatorColor: AppColors.accent.withOpacity(0.15),
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.web_outlined),
            selectedIcon: Icon(Icons.web),
            label: 'Sites',
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
            icon: Icon(Icons.terminal_outlined),
            selectedIcon: Icon(Icons.terminal),
            label: 'Terminal',
          ),
        ],
      ),
    );
  }
}
