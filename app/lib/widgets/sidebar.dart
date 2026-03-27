import 'dart:ui';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../providers/auth_provider.dart';

class Sidebar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onNavigate;

  const Sidebar({
    super.key,
    required this.selectedIndex,
    required this.onNavigate,
  });

  static const _items = [
    _NavItem(icon: Icons.hub_outlined,          selectedIcon: Icons.hub,           label: 'GitHub'),
    _NavItem(icon: Icons.dashboard_outlined,    selectedIcon: Icons.dashboard,     label: 'Dashboard'),
    _NavItem(icon: Icons.inventory_2_outlined,  selectedIcon: Icons.inventory_2,   label: 'Containers'),
    _NavItem(icon: Icons.account_tree_outlined, selectedIcon: Icons.account_tree,  label: 'Canvas'),
    _NavItem(icon: Icons.terminal_outlined,     selectedIcon: Icons.terminal,      label: 'Terminal'),
  ];

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          width: 220,
          decoration: const BoxDecoration(
            color: GlassTokens.sidebarBg,
            border: Border(right: BorderSide(color: GlassTokens.cardBorder, width: 1)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) const SizedBox(height: 28),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                child: Row(
                  children: [
                    Text(
                      'ONDES',
                      style: GoogleFonts.poppins(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'HOST',
                      style: GoogleFonts.poppins(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              const SizedBox(height: 12),
              for (int idx = 0; idx < _items.length; idx++)
                _SidebarTile(
                  item: _items[idx],
                  isSelected: selectedIndex == idx,
                  onTap: () => onNavigate(idx),
                ),
              const Spacer(),
              const Divider(height: 1),
              _SidebarTile(
                item: const _NavItem(
                  icon: Icons.logout_outlined,
                  selectedIcon: Icons.logout,
                  label: 'Logout',
                ),
                isSelected: false,
                isDestructive: true,
                onTap: () => context.read<AuthProvider>().logout(),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  const _NavItem({required this.icon, required this.selectedIcon, required this.label});
}

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
    final Color foreground;
    if (widget.isDestructive) {
      foreground = _hovering ? AppColors.accentRed : AppColors.textMuted;
    } else if (widget.isSelected) {
      foreground = AppColors.accent;
    } else {
      foreground = _hovering ? AppColors.textSecondary : AppColors.textMuted;
    }

    final icon = widget.isSelected ? widget.item.selectedIcon : widget.item.icon;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit:  (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? AppColors.accent.withValues(alpha: 0.12)
                : _hovering
                    ? const Color(0x0FFFFFFF)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: widget.isSelected
                ? Border.all(color: AppColors.accent.withValues(alpha: 0.2), width: 1)
                : null,
          ),
          child: Row(
            children: [
              Icon(icon, size: 16, color: foreground),
              const SizedBox(width: 10),
              Text(
                widget.item.label,
                style: TextStyle(
                  color: foreground,
                  fontSize: 13,
                  fontWeight: widget.isSelected ? FontWeight.w600 : FontWeight.w400,
                  fontFamily: GoogleFonts.inter().fontFamily,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
