import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../providers/auth_provider.dart';
import '../screens/dashboard_screen.dart';
import '../screens/docker_manager_screen.dart';
import '../screens/terminal_screen.dart';

class Sidebar extends StatelessWidget {
  final int selectedIndex;

  const Sidebar({super.key, required this.selectedIndex});

  static const _items = [
    _NavItem(icon: Icons.dashboard_outlined,    label: 'Dashboard'),
    _NavItem(icon: Icons.inventory_2_outlined,  label: 'Containers'),
    _NavItem(icon: Icons.terminal_outlined,     label: 'Terminal'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Logo ─────────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(Icons.waves, color: Colors.black, size: 18),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Ondes',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          const SizedBox(height: 8),
          // ── Nav items ─────────────────────────────────────────────────────
          for (int i = 0; i < _items.length; i++)
            _SidebarTile(
              item: _items[i],
              isSelected: selectedIndex == i,
              onTap: () => _navigate(context, i),
            ),
          const Spacer(),
          const Divider(height: 1),
          // ── Logout ────────────────────────────────────────────────────────
          _SidebarTile(
            item: const _NavItem(icon: Icons.logout_outlined, label: 'Logout'),
            isSelected: false,
            isDestructive: true,
            onTap: () => context.read<AuthProvider>().logout(),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  void _navigate(BuildContext context, int index) {
    if (index == selectedIndex) return;
    final Widget screen;
    switch (index) {
      case 0: screen = const DashboardScreen();      break;
      case 1: screen = const DockerManagerScreen();  break;
      case 2: screen = const TerminalScreen();       break;
      default: return;
    }
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => screen,
        transitionDuration: Duration.zero,
      ),
    );
  }
}

// ─── Data ─────────────────────────────────────────────────────────────────────
class _NavItem {
  final IconData icon;
  final String label;
  const _NavItem({required this.icon, required this.label});
}

// ─── Tile with hover ──────────────────────────────────────────────────────────
class _SidebarTile extends StatefulWidget {
  final _NavItem item;
  final bool isSelected;
  final bool isDestructive;
  final VoidCallback onTap;

  const _SidebarTile({
    required this.item,
    required this.isSelected,
    required this.onTap,
    this.isDestructive = false,
  });

  @override
  State<_SidebarTile> createState() => _SidebarTileState();
}

class _SidebarTileState extends State<_SidebarTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final Color color;
    if (widget.isDestructive) {
      color = _hovering ? AppColors.accentRed : AppColors.textMuted;
    } else if (widget.isSelected) {
      color = AppColors.accent;
    } else {
      color = _hovering ? AppColors.textSecondary : AppColors.textMuted;
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit:  (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? AppColors.accent.withOpacity(0.1)
                : _hovering
                    ? AppColors.surfaceVariant
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(widget.item.icon, size: 16, color: color),
              const SizedBox(width: 10),
              Text(
                widget.item.label,
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: widget.isSelected ? FontWeight.w500 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
