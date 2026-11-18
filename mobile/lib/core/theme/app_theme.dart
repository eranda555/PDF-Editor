import 'dart:io';

import 'package:flutter/material.dart';

abstract final class AppColors {
  static const primary100 = Color(0xFF62EFE4);
  static const primary40 = Color(0xFF66D6D1);
  static const primary20 = Color(0xFFB2EFEA);
  static const primary10 = Color(0xFFE6F4F3);
  static const charcoal = Color(0xFF3B4948);
  static const coral = Color(0xFFEC8C6F);
  static const blush = Color(0xFFF3D6CE);
  static const background = Color(0xFFFAF8F7);
  static const surface = Colors.white;
}

ThemeData appTheme() {
  final font = Platform.isIOS ? '.SF Pro Text' : 'Suite Sans';
  return ThemeData(
    useMaterial3: true,
    fontFamily: font,
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: ColorScheme.fromSeed(seedColor: AppColors.primary100).copyWith(
      primary: AppColors.charcoal,
      secondary: AppColors.primary40,
      surface: AppColors.surface,
      onSurface: AppColors.charcoal,
      primaryContainer: AppColors.primary100,
      error: const Color(0xFF9C3E29),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.charcoal,
      centerTitle: false,
    ),
    textTheme: TextTheme(
      headlineSmall: TextStyle(
        fontFamily: Platform.isIOS ? '.SF Pro Display' : font,
        fontSize: 24,
        fontWeight: FontWeight.w700,
        letterSpacing: -.4,
        color: AppColors.charcoal,
      ),
      titleLarge: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: -.4,
      ),
      titleMedium: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      bodyMedium: const TextStyle(fontSize: 14, height: 1.45),
      labelLarge: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 1,
      shadowColor: AppColors.charcoal.withValues(alpha: .06),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary100,
        foregroundColor: AppColors.charcoal,
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.primary10,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    ),
  );
}

class ExecutionBadge extends StatelessWidget {
  const ExecutionBadge({super.key, this.cloud = false});
  final bool cloud;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: cloud ? AppColors.blush : AppColors.primary10,
      borderRadius: BorderRadius.circular(24),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          cloud ? Icons.cloud_outlined : Icons.shield_outlined,
          size: 14,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            cloud
                ? 'Encrypted Cloud • 1h expiry target'
                : 'Processed On-Device (Private)',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.charcoal,
            ),
          ),
        ),
      ],
    ),
  );
}
