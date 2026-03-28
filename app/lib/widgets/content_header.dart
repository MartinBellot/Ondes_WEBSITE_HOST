import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

/// macOS-native style content-area page header.
///
/// - [backLabel]: if non-null, shows a "← BackLabel" chevron button (macOS style).
///   Use it for detail screens. Tapping calls [onBack] (or Navigator.pop if null).
/// - [title]: main title in Poppins.
/// - [actions]: optional trailing widgets (buttons, icons, etc.).
/// - [bottom]: optional widget rendered below the title row (e.g. TabBar).
class ContentHeader extends StatelessWidget {
  final String title;
  final String? backLabel;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final PreferredSizeWidget? bottom;
  final double horizontalPadding;

  const ContentHeader({
    super.key,
    required this.title,
    this.backLabel,
    this.onBack,
    this.actions = const [],
    this.bottom,
    this.horizontalPadding = 28,
  });

  @override
  Widget build(BuildContext context) {
    // Dynamic padding so very small screens (mobile) get tighter spacing
    final hPad = MediaQuery.sizeOf(context).width < 700 ? 16.0 : horizontalPadding;
    // On iOS, push content below the notch / Dynamic Island
    final topInset = MediaQuery.of(context).padding.top;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          decoration: const BoxDecoration(
            color: GlassTokens.sidebarBg,
            border: Border(
              bottom: BorderSide(color: GlassTokens.cardBorder, width: 1),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 52 + topInset,
                child: Padding(
                  padding: EdgeInsets.only(top: topInset, left: hPad, right: hPad),
                  child: Row(
                    children: [
                      // ── Back chevron (macOS pattern) ───────────────
                      if (backLabel != null) ...[
                        _BackChevron(
                          label: backLabel!,
                          onTap: onBack ?? () => Navigator.of(context).pop(),
                        ),
                        const SizedBox(width: 16),
                        // Separator
                        Container(
                          width: 1,
                          height: 18,
                          color: GlassTokens.cardBorder,
                        ),
                        const SizedBox(width: 16),
                      ],
                      // ── Title (Poppins) ────────────────────────────
                      Expanded(
                        child: Text(
                          title,
                          style: GoogleFonts.poppins(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                            letterSpacing: -0.1,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // ── Actions ────────────────────────────────────
                      ...actions,
                    ],
                  ),
                ),
              ),
              // ── Optional bottom widget (TabBar etc.) ──────────────
              if (bottom != null) bottom!,
            ],
          ),
        ),
      ),
    );
  }
}

// ─── macOS-style back chevron ─────────────────────────────────────────────────
class _BackChevron extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _BackChevron({required this.label, required this.onTap});

  @override
  State<_BackChevron> createState() => _BackChevronState();
}

class _BackChevronState extends State<_BackChevron> {
  bool _hov = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hov = true),
      onExit:  (_) => setState(() => _hov = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: _hov ? 1.0 : 0.7,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.chevron_left_rounded,
                size: 18,
                color: AppColors.accent,
              ),
              Text(
                widget.label,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
