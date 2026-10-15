import 'package:flutter/material.dart';

/// Colours in the spirit of Nothing OS: black and white, greys, one red.
@immutable
class NothingPalette extends ThemeExtension<NothingPalette> {
  const NothingPalette({
    required this.background,
    required this.surface,
    required this.surfaceHigh,
    required this.border,
    required this.text,
    required this.textDim,
    required this.dot,
    required this.onAccent,
  });

  static const red = Color(0xFFD71921);

  static const dark = NothingPalette(
    background: Color(0xFF000000),
    surface: Color(0xFF111111),
    surfaceHigh: Color(0xFF1C1C1C),
    border: Color(0xFF2A2A2A),
    text: Color(0xFFFFFFFF),
    textDim: Color(0xFF8C8C8C),
    dot: Color(0xFF262626),
    onAccent: Color(0xFFFFFFFF),
  );

  static const light = NothingPalette(
    background: Color(0xFFF3F3F3),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFE9E9E9),
    border: Color(0xFFDADADA),
    text: Color(0xFF000000),
    textDim: Color(0xFF6E6E6E),
    dot: Color(0xFFD4D4D4),
    onAccent: Color(0xFFFFFFFF),
  );

  final Color background;
  final Color surface;
  final Color surfaceHigh;
  final Color border;
  final Color text;
  final Color textDim;
  final Color dot;
  final Color onAccent;
  Color get accent => red;

  @override
  NothingPalette copyWith() => this;

  @override
  NothingPalette lerp(NothingPalette? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return NothingPalette(
      background: l(background, other.background),
      surface: l(surface, other.surface),
      surfaceHigh: l(surfaceHigh, other.surfaceHigh),
      border: l(border, other.border),
      text: l(text, other.text),
      textDim: l(textDim, other.textDim),
      dot: l(dot, other.dot),
      onAccent: l(onAccent, other.onAccent),
    );
  }
}

extension NothingContext on BuildContext {
  NothingPalette get palette => Theme.of(this).extension<NothingPalette>() ?? NothingPalette.dark;
}

/// Type styles. Doto is a free (SIL OFL) dot-matrix font used for headings and
/// numbers; Space Grotesk (SIL OFL) is used for everything else.
class NType {
  static const dotFamily = 'Doto';
  static const bodyFamily = 'SpaceGrotesk';

  static TextStyle dot(double size, {Color? color, double weight = 800, double spacing = 0}) => TextStyle(
        fontFamily: dotFamily,
        fontSize: size,
        height: 1.05,
        color: color,
        letterSpacing: spacing,
        fontVariations: [FontVariation('wght', weight), const FontVariation('ROND', 100)],
      );

  static TextStyle body(double size, {Color? color, double weight = 400, double spacing = 0, double height = 1.3}) =>
      TextStyle(
        fontFamily: bodyFamily,
        fontSize: size,
        height: height,
        color: color,
        letterSpacing: spacing,
        fontWeight: FontWeight.values[((weight / 100).round() - 1).clamp(0, 8)],
        fontVariations: [FontVariation('wght', weight)],
      );

  /// Small all-caps label, like the section headers in Nothing OS.
  static TextStyle label({Color? color}) => body(11, color: color, weight: 500, spacing: 1.8);
}

ThemeData buildNothingTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? NothingPalette.dark : NothingPalette.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.text,
    onPrimary: p.background,
    secondary: NothingPalette.red,
    onSecondary: Colors.white,
    error: NothingPalette.red,
    onError: Colors.white,
    surface: p.surface,
    onSurface: p.text,
    surfaceContainerHighest: p.surfaceHigh,
    outline: p.border,
  );
  final text = TextTheme(
    displayLarge: NType.dot(64, color: p.text),
    displayMedium: NType.dot(44, color: p.text),
    displaySmall: NType.dot(32, color: p.text),
    headlineMedium: NType.dot(26, color: p.text),
    headlineSmall: NType.dot(22, color: p.text),
    titleLarge: NType.body(20, color: p.text, weight: 500),
    titleMedium: NType.body(16, color: p.text, weight: 500),
    titleSmall: NType.body(14, color: p.text, weight: 500),
    bodyLarge: NType.body(16, color: p.text),
    bodyMedium: NType.body(14, color: p.text),
    bodySmall: NType.body(12, color: p.textDim),
    labelLarge: NType.body(14, color: p.text, weight: 500),
    labelMedium: NType.body(12, color: p.text, weight: 500),
    labelSmall: NType.label(color: p.textDim),
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(999));
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.background,
    canvasColor: p.background,
    fontFamily: NType.bodyFamily,
    textTheme: text,
    extensions: [p],
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    dividerColor: p.border,
    dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
    iconTheme: IconThemeData(color: p.text, size: 22),
    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: p.text,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: NType.dot(24, color: p.text),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.text,
        foregroundColor: p.background,
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        textStyle: NType.body(14, weight: 500, spacing: 0.4),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.text,
        side: BorderSide(color: p.border),
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: NType.body(14, weight: 500, spacing: 0.4),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.text,
        shape: shape,
        textStyle: NType.body(14, weight: 500, spacing: 0.4),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surfaceHigh,
      labelStyle: NType.body(14, color: p.textDim),
      hintStyle: NType.body(14, color: p.textDim),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: p.text, width: 1)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: p.border,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      titleTextStyle: NType.dot(24, color: p.text),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.text,
      contentTextStyle: NType.body(14, color: p.background),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : p.textDim),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? NothingPalette.red : p.surfaceHigh),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.surfaceHigh,
      selectedColor: p.text,
      labelStyle: NType.body(13, color: p.text, weight: 500),
      secondaryLabelStyle: NType.body(13, color: p.background, weight: 500),
      side: BorderSide.none,
      shape: shape,
      showCheckmark: false,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: p.text,
      textColor: p.text,
      titleTextStyle: NType.body(15, color: p.text, weight: 500),
      subtitleTextStyle: NType.body(13, color: p.textDim),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: NothingPalette.red, linearTrackColor: p.surfaceHigh),
  );
}
