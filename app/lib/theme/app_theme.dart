import 'package:flutter/material.dart';

/// Static brand theme for MeshChameleon.
///
/// Quiet green-neutral surfaces anchored on the existing dark artwork
/// with a restrained green accent for primary actions.
/// Light mode gets its own near-neutral, equally intentional palette. Static
/// by design: no wallpaper-derived dynamic color this round.
abstract final class MeshChameleonTheme {
  static const lightStatus = StatusColors(
    attention: Color(0xFF7A5800),
    attentionContainer: Color(0xFFFFE08A),
    onAttentionContainer: Color(0xFF261A00),
  );
  static const darkStatus = StatusColors(
    attention: Color(0xFFF5CB6B),
    attentionContainer: Color(0xFF4C3900),
    onAttentionContainer: Color(0xFFFFE9A8),
  );

  static ThemeData light() => _build(
        brightness: Brightness.light,
        scheme: const ColorScheme.light(
          primary: Color(0xFF1F7A45),
          onPrimary: Color(0xFFFFFFFF),
          primaryContainer: Color(0xFFA9F0C4),
          onPrimaryContainer: Color(0xFF00210E),
          secondary: Color(0xFF0E6B57),
          onSecondary: Color(0xFFFFFFFF),
          secondaryContainer: Color(0xFF9FE9CE),
          onSecondaryContainer: Color(0xFF002018),
          tertiary: Color(0xFF33691E),
          onTertiary: Color(0xFFFFFFFF),
          tertiaryContainer: Color(0xFFC4F09B),
          onTertiaryContainer: Color(0xFF112700),
          error: Color(0xFFBA1A1A),
          onError: Color(0xFFFFFFFF),
          errorContainer: Color(0xFFFFDAD6),
          onErrorContainer: Color(0xFF410002),
          surface: Color(0xFFF7FAF6),
          onSurface: Color(0xFF161D17),
          surfaceContainerLowest: Color(0xFFFFFFFF),
          surfaceContainerLow: Color(0xFFF0F4EE),
          surfaceContainer: Color(0xFFEAEFE8),
          surfaceContainerHigh: Color(0xFFE4EAE1),
          surfaceContainerHighest: Color(0xFFDFE5DC),
          onSurfaceVariant: Color(0xFF3F4941),
          outline: Color(0xFF6F7A6F),
          outlineVariant: Color(0xFF7F8A80),
          shadow: Color(0xFF000000),
          scrim: Color(0xFF000000),
          inverseSurface: Color(0xFF2B322C),
          onInverseSurface: Color(0xFFECF2EA),
          inversePrimary: Color(0xFF8FD5A6),
          surfaceTint: Color(0xFF1F7A45),
        ),
        status: lightStatus,
      );

  static ThemeData dark() => _build(
        brightness: Brightness.dark,
        scheme: const ColorScheme.dark(
          primary: Color(0xFF8FD5A6),
          onPrimary: Color(0xFF00391D),
          primaryContainer: Color(0xFF245139),
          onPrimaryContainer: Color(0xFFB5F1C7),
          secondary: Color(0xFF3FE6BA),
          onSecondary: Color(0xFF00382B),
          secondaryContainer: Color(0xFF0E4E3B),
          onSecondaryContainer: Color(0xFF8AF0CB),
          tertiary: Color(0xFFB9D98A),
          onTertiary: Color(0xFF244400),
          tertiaryContainer: Color(0xFF354E1E),
          onTertiaryContainer: Color(0xFFD4F4A6),
          error: Color(0xFFFFB4AB),
          onError: Color(0xFF690005),
          errorContainer: Color(0xFF93000A),
          onErrorContainer: Color(0xFFFFDAD6),
          surface: Color(0xFF081713),
          onSurface: Color(0xFFE4EEE8),
          surfaceContainerLowest: Color(0xFF06140F),
          surfaceContainerLow: Color(0xFF0D1C17),
          surfaceContainer: Color(0xFF11211A),
          surfaceContainerHigh: Color(0xFF172820),
          surfaceContainerHighest: Color(0xFF203028),
          onSurfaceVariant: Color(0xFFB7C9BE),
          outline: Color(0xFF87968C),
          outlineVariant: Color(0xFF5F7366),
          shadow: Color(0xFF000000),
          scrim: Color(0xFF000000),
          inverseSurface: Color(0xFFE4EEE8),
          onInverseSurface: Color(0xFF2B322C),
          inversePrimary: Color(0xFF1F7A45),
          surfaceTint: Color(0xFF8FD5A6),
        ),
        status: darkStatus,
      );

  static ThemeData _build({
    required Brightness brightness,
    required ColorScheme scheme,
    required StatusColors status,
  }) {
    final base = ThemeData(
        brightness: brightness, useMaterial3: true, colorScheme: scheme);
    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      extensions: [status],
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        subtitleTextStyle:
            TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 2),
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
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
        actionTextColor: scheme.inversePrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: TextStyle(color: scheme.onInverseSurface),
        waitDuration: const Duration(milliseconds: 400),
      ),
      textTheme: base.textTheme.copyWith(
        headlineSmall:
            base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
        titleLarge:
            base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        titleMedium:
            base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Semantic status pairs not covered by the base scheme.
///
/// Amber means attention/recovery, never "low signal" or "unhealthy by
/// itself"; pair with text. Healthy green is the primary role; failure and
/// destruction use the error roles.
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({
    required this.attention,
    required this.attentionContainer,
    required this.onAttentionContainer,
  });

  final Color attention;
  final Color attentionContainer;
  final Color onAttentionContainer;

  static StatusColors of(BuildContext context) =>
      Theme.of(context).extension<StatusColors>() ??
      (Theme.of(context).brightness == Brightness.dark
          ? MeshChameleonTheme.darkStatus
          : MeshChameleonTheme.lightStatus);

  @override
  StatusColors copyWith({
    Color? attention,
    Color? attentionContainer,
    Color? onAttentionContainer,
  }) =>
      StatusColors(
        attention: attention ?? this.attention,
        attentionContainer: attentionContainer ?? this.attentionContainer,
        onAttentionContainer: onAttentionContainer ?? this.onAttentionContainer,
      );

  @override
  StatusColors lerp(covariant StatusColors? other, double t) {
    if (other == null) return this;
    return StatusColors(
      attention: Color.lerp(attention, other.attention, t)!,
      attentionContainer:
          Color.lerp(attentionContainer, other.attentionContainer, t)!,
      onAttentionContainer:
          Color.lerp(onAttentionContainer, other.onAttentionContainer, t)!,
    );
  }
}
