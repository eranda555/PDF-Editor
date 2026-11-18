import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const lightStatusBar = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
);

abstract final class AppColors {
  static const slate = Color(0xff284b5e);
  static const plum = Color(0xff845460);
  static const canvas = Color(0xfff4f6f9);
  static const surface = Colors.white;
  static const ink = Color(0xff0f172a);
  static const muted = Color(0xff475569);
  static const border = Color(0xffe2e8f0);
  static const hint = Color(0xff94a3b8);
  static const privateFill = Color(0xffecfdf5);
  static const privateText = Color(0xff047857);
  static const privateBorder = Color(0xffa7f3d0);
  static const cloudFill = Color(0xfffffbeb);
  static const cloudText = Color(0xffb45309);
  static const cloudBorder = Color(0xfffde68a);
  static const selection = Color(0xffdae4e6);
  static const error = Color(0xffba1a1a);
  static const red = Color(0xffdc322f);
  static const green = Color(0xff378344);
  static const word = Color(0xff2b579a);
  static const gold = Color(0xff986707);
  // Match the stroke color written into the exported PDF.
  static const annotationInk = Color(0xff3b4948);
  static const violet = Color(0xff8e44ad);
  static const blue = Color(0xff2563eb);
  static const amber = Color(0xffa95607);
}

abstract final class Ui {
  static const xs = 4.0,
      sm = 8.0,
      gutter = 12.0,
      md = 16.0,
      lg = 24.0,
      touch = 48.0;
  static const cardRadius = BorderRadius.all(Radius.circular(md));
  static const inputRadius = BorderRadius.all(Radius.circular(sm));
  static const shadow = BoxShadow(
    color: Color(0x0a0f172a),
    offset: Offset(0, 3),
    blurRadius: 10,
  );
  static const card = BoxDecoration(
    color: AppColors.surface,
    borderRadius: cardRadius,
    border: Border.fromBorderSide(BorderSide(color: AppColors.border)),
    boxShadow: [shadow],
  );
  static const search = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(32)),
    borderSide: BorderSide(color: AppColors.border),
  );
}

TextStyle _type(
  String family,
  double size,
  double line,
  FontWeight weight, [
  double tracking = 0,
]) => TextStyle(
  fontFamily: family,
  fontFamilyFallback: const ['Inter', 'Suite Sans'],
  fontSize: size,
  height: line / size,
  fontWeight: weight,
  letterSpacing: tracking,
  color: AppColors.ink,
);

ThemeData appTheme() {
  const heading = 'Plus Jakarta Sans', body = 'Inter';
  final type = TextTheme(
    displaySmall: _type(heading, 36, 44, FontWeight.w700, -.72),
    headlineMedium: _type(heading, 28, 36, FontWeight.w700, -.56),
    headlineSmall: _type(heading, 24, 32, FontWeight.w700, -.24),
    titleLarge: _type(heading, 20, 26, FontWeight.w700, -.2),
    titleMedium: _type(heading, 18, 24, FontWeight.w700, -.2),
    titleSmall: _type(heading, 15, 20, FontWeight.w600, -.2),
    bodyLarge: _type(body, 16, 24, FontWeight.w400),
    bodyMedium: _type(body, 14, 20, FontWeight.w400),
    bodySmall: _type(
      body,
      12.5,
      12.5 * 1.35,
      FontWeight.w400,
    ).copyWith(color: AppColors.muted),
    labelLarge: _type(body, 14, 20, FontWeight.w600, .14),
    labelMedium: _type(body, 12, 16, FontWeight.w600, .24),
    labelSmall: _type(body, 11, 15, FontWeight.w500),
  );
  final scheme = ColorScheme.fromSeed(seedColor: AppColors.slate).copyWith(
    primary: AppColors.slate,
    onPrimary: AppColors.surface,
    primaryContainer: AppColors.selection,
    onPrimaryContainer: AppColors.slate,
    secondary: AppColors.red,
    surface: AppColors.surface,
    onSurface: AppColors.ink,
    onSurfaceVariant: AppColors.muted,
    outline: AppColors.hint,
    outlineVariant: AppColors.border,
    error: AppColors.error,
  );
  const field = OutlineInputBorder(
    borderRadius: Ui.inputRadius,
    borderSide: BorderSide(color: AppColors.border),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.canvas,
    fontFamily: body,
    fontFamilyFallback: const ['Suite Sans'],
    textTheme: type,
    appBarTheme: AppBarTheme(
      systemOverlayStyle: lightStatusBar,
      elevation: 0,
      scrolledUnderElevation: .5,
      shape: const Border(bottom: BorderSide(color: AppColors.border)),
      backgroundColor: AppColors.surface,
      foregroundColor: AppColors.slate,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: type.titleLarge,
    ),
    cardTheme: const CardThemeData(
      color: AppColors.surface,
      elevation: 1,
      shadowColor: Color(0x142b4f60),
      shape: RoundedRectangleBorder(
        borderRadius: Ui.cardRadius,
        side: BorderSide(color: AppColors.border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.slate,
        foregroundColor: AppColors.surface,
        minimumSize: const Size(Ui.touch, Ui.touch),
        shape: const StadiumBorder(),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(Ui.touch, Ui.touch),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: const BorderSide(color: AppColors.border),
      backgroundColor: AppColors.surface,
      selectedColor: AppColors.slate,
      showCheckmark: false,
      labelStyle: WidgetStateTextStyle.resolveWith(
        (states) => type.labelMedium!.copyWith(
          color: states.contains(WidgetState.selected)
              ? AppColors.surface
              : AppColors.slate,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      hintStyle: type.bodyMedium!.copyWith(color: AppColors.hint),
      prefixIconColor: AppColors.hint,

      filled: true,
      fillColor: AppColors.surface,
      border: field,
      enabledBorder: field,
      focusedBorder: const OutlineInputBorder(
        borderRadius: Ui.inputRadius,
        borderSide: BorderSide(color: AppColors.slate, width: 2),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 64,
      backgroundColor: AppColors.surface,
      indicatorColor: AppColors.selection,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? AppColors.slate
              : AppColors.hint,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => type.labelSmall!.copyWith(
          color: states.contains(WidgetState.selected)
              ? AppColors.slate
              : AppColors.muted,
        ),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ui.lg)),
      ),
    ),
  );
}

class ExecutionBadge extends StatelessWidget {
  const ExecutionBadge({super.key, this.cloud = false});
  final bool cloud;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: cloud ? AppColors.cloudFill : AppColors.privateFill,
      border: Border.all(
        color: cloud ? AppColors.cloudBorder : AppColors.privateBorder,
      ),
      borderRadius: Ui.cardRadius,
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: Ui.sm, vertical: Ui.xs),
      child: Text(
        cloud ? 'Encrypted cloud \u2022 1h' : 'Processed on-device (private)',
        semanticsLabel: cloud
            ? 'Encrypted cloud, one-hour expiry target'
            : null,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall!.copyWith(
          color: cloud ? AppColors.cloudText : AppColors.privateText,
        ),
      ),
    ),
  );
}
