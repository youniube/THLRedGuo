import 'package:flutter/material.dart';

import 'package:THLRedLook/utils/theme/app_colors.dart';

Future<T?> showDanmakuDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  ThemeData? theme,
}) => showDialog<T>(
  context: context,
  builder: (context) => Theme(
    data: DanmakuSettingsTheme.data(theme ?? Theme.of(context)),
    child: Builder(builder: builder),
  ),
);

abstract final class DanmakuSettingsTheme {
  static Color accent(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark
      ? AppColors.hongguoRedLight
      : AppColors.hongguoRedDark;

  static Color border(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark
      ? AppColors.darkControlBorder
      : AppColors.textTertiaryLight;

  static RoundedRectangleBorder tileShape(
    BuildContext context, {
    bool selected = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: BorderSide(color: selected ? accent(scheme) : border(scheme)),
    );
  }

  static ButtonStyle action(BuildContext context, {bool primary = false}) =>
      _action(Theme.of(context).colorScheme, primary: primary);

  static ButtonStyle _action(ColorScheme scheme, {bool primary = false}) =>
      OutlinedButton.styleFrom(
        foregroundColor: primary ? accent(scheme) : scheme.onSurface,
        backgroundColor: primary
            ? AppColors.accentSubtle12
            : scheme.surfaceContainer,
        disabledForegroundColor: scheme.onSurface.withValues(alpha: .38),
        disabledBackgroundColor: scheme.surface,
        minimumSize: const Size(64, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ).copyWith(
        side: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return BorderSide(color: scheme.outlineVariant);
          }
          final focused = states.contains(WidgetState.focused);
          return BorderSide(
            color: primary || focused ? accent(scheme) : border(scheme),
            width: focused ? 2 : 1,
          );
        }),
      );

  static ThemeData data(ThemeData base) {
    final scheme = base.colorScheme.copyWith(
      primary: AppColors.hongguoRed,
      onPrimary: AppColors.white,
    );
    final selected = accent(scheme);
    final labelStyle = base.textTheme.labelLarge!.copyWith(
      fontWeight: FontWeight.w600,
      color: WidgetStateColor.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return scheme.onSurface.withValues(alpha: .38);
        }
        return states.contains(WidgetState.selected)
            ? selected
            : scheme.onSurface;
      }),
    );
    return base.copyWith(
      colorScheme: scheme,
      chipTheme: ChipThemeData(
        color: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return scheme.surface;
          return states.contains(WidgetState.selected)
              ? AppColors.accentSubtle12
              : scheme.surfaceContainer;
        }),
        labelStyle: labelStyle,
        secondaryLabelStyle: labelStyle,
        checkmarkColor: selected,
        deleteIconColor: scheme.onSurface,
        showCheckmark: true,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: WidgetStateBorderSide.resolveWith((states) {
          final focused = states.contains(WidgetState.focused);
          return BorderSide(
            color: states.contains(WidgetState.disabled)
                ? scheme.outlineVariant
                : states.contains(WidgetState.selected) || focused
                ? selected
                : border(scheme),
            width: focused ? 2 : 1,
          );
        }),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(style: _action(scheme)),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.onSurface,
          minimumSize: const Size(64, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.hongguoRedDark,
          foregroundColor: AppColors.white,
          minimumSize: const Size(64, 44),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      dialogTheme: base.dialogTheme.copyWith(
        backgroundColor: scheme.surface,
        surfaceTintColor: AppColors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: scheme.surfaceContainer,
        contentPadding: const EdgeInsets.all(16),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
        helperMaxLines: 3,
        errorMaxLines: 3,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border(scheme)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border(scheme)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: selected, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
      ),
    );
  }
}
