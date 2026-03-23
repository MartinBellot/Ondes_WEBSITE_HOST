import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ─── Design tokens ────────────────────────────────────────────────────────────
class AppColors {
  static const background    = Color(0xFF0D1117);
  static const surface       = Color(0xFF161B22);
  static const surfaceVariant= Color(0xFF1C2128);
  static const border        = Color(0xFF30363D);
  static const borderLight   = Color(0xFF21262D);
  static const accent        = Color(0xFF58A6FF);
  static const accentGreen   = Color(0xFF3FB950);
  static const accentRed     = Color(0xFFF85149);
  static const accentYellow  = Color(0xFFD29922);
  static const textPrimary   = Color(0xFFF0F6FC);
  static const textSecondary = Color(0xFF8B949E);
  static const textMuted     = Color(0xFF6E7681);
}

class AppTheme {
  static ThemeData dark() {
    final base = ThemeData.dark();
    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: const ColorScheme.dark(
        background: AppColors.background,
        surface:    AppColors.surface,
        primary:    AppColors.accent,
        error:      AppColors.accentRed,
        onBackground: AppColors.textPrimary,
        onSurface:  AppColors.textPrimary,
        onPrimary:  Color(0xFF0D1117),
        outline:    AppColors.border,
      ),
      textTheme: GoogleFonts.interTextTheme(base.textTheme).copyWith(
        bodyLarge:   GoogleFonts.inter(color: AppColors.textPrimary,   fontSize: 16),
        bodyMedium:  GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 14),
        bodySmall:   GoogleFonts.inter(color: AppColors.textMuted,     fontSize: 12),
        titleLarge:  GoogleFonts.inter(color: AppColors.textPrimary,   fontSize: 20, fontWeight: FontWeight.w600),
        titleMedium: GoogleFonts.inter(color: AppColors.textPrimary,   fontSize: 16, fontWeight: FontWeight.w500),
        labelLarge:  GoogleFonts.inter(color: AppColors.textPrimary,   fontSize: 14, fontWeight: FontWeight.w500),
      ),
      cardTheme: CardTheme(
        color: AppColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: AppColors.border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceVariant,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.accentRed),
        ),
        labelStyle: GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 14),
        hintStyle:  GoogleFonts.inter(color: AppColors.textMuted,     fontSize: 14),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: AppColors.background,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          textStyle: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w500),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          side: const BorderSide(color: AppColors.border),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          textStyle: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: 1,
        space: 1,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.surface,
        elevation: 0,
        titleTextStyle: GoogleFonts.inter(
          color: AppColors.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: const IconThemeData(color: AppColors.textSecondary),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.surfaceVariant,
        contentTextStyle: GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: const BorderSide(color: AppColors.border),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
