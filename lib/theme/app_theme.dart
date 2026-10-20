import 'package:flutter/material.dart';

/// Colours from smarthomekj.eu: soft white and black surfaces, near-black
/// text, one blue for actions and iOS-style colours for device kinds.
@immutable
class KJPalette extends ThemeExtension<KJPalette> {
  const KJPalette({
    required this.background,
    required this.surface,
    required this.surfaceHigh,
    required this.border,
    required this.text,
    required this.textDim,
    required this.dot,
    required this.onAccent,
    required this.shadow,
  });

  /// Buttons, links, switches and anything selected.
  static const accent = Color(0xFF0071E3);

  /// Errors, deletes, devices that don't answer, alarms.
  static const danger = Color(0xFFFF3B30);

  static const green = Color(0xFF34C759);
  static const yellow = Color(0xFFFFB800);
  static const orange = Color(0xFFFF9500);
  static const purple = Color(0xFFAF52DE);
  static const blue = Color(0xFF007AFF);
  static const teal = Color(0xFF30B0C7);
  static const indigo = Color(0xFF5856D6);
  static const pink = Color(0xFFFF2D55);

  static const dark = KJPalette(
    background: Color(0xFF000000),
    surface: Color(0xFF1C1C1E),
    surfaceHigh: Color(0xFF2C2C2E),
    border: Color(0xFF38383A),
    text: Color(0xFFF5F5F7),
    textDim: Color(0xFF98989D),
    dot: Color(0xFF2C2C2E),
    onAccent: Color(0xFFFFFFFF),
    shadow: Color(0x00000000),
  );

  static const light = KJPalette(
    background: Color(0xFFF5F5F7),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFE8E8ED),
    border: Color(0xFFD2D2D7),
    text: Color(0xFF1D1D1F),
    textDim: Color(0xFF6E6E73),
    dot: Color(0xFFD2D2D7),
    onAccent: Color(0xFFFFFFFF),
    shadow: Color(0x14000000),
  );

  final Color background;
  final Color surface;
  final Color surfaceHigh;
  final Color border;
  final Color text;
  final Color textDim;
  final Color dot;
  final Color onAccent;

  /// Soft drop shadow under cards (none on the dark theme).
  final Color shadow;

  bool get isDark => background.computeLuminance() < 0.2;

  /// Background of a device tile that is off.
  Color get tileOff => isDark ? const Color(0xFF1C1C1E) : const Color(0xFFE3E3E8);

  /// The white tile of a device that is on, like in the site's phone demo.
  Color get tileOn => isDark ? const Color(0xFFF5F5F7) : const Color(0xFFFFFFFF);

  /// Text on [tileOn].
  Color get onTileOn => const Color(0xFF1D1D1F);

  List<BoxShadow> get cardShadow =>
      shadow.a == 0 ? const [] : [BoxShadow(color: shadow, blurRadius: 24, offset: const Offset(0, 6))];

  @override
  KJPalette copyWith() => this;

  @override
  KJPalette lerp(KJPalette? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return KJPalette(
      background: l(background, other.background),
      surface: l(surface, other.surface),
      surfaceHigh: l(surfaceHigh, other.surfaceHigh),
      border: l(border, other.border),
      text: l(text, other.text),
      textDim: l(textDim, other.textDim),
      dot: l(dot, other.dot),
      onAccent: l(onAccent, other.onAccent),
      shadow: l(shadow, other.shadow),
    );
  }
}

extension KJContext on BuildContext {
  KJPalette get palette => Theme.of(this).extension<KJPalette>() ?? KJPalette.dark;
}

/// Type styles. Inter (SIL OFL) for everything, close to the Apple system
/// font the site uses: big bold headings with tight letter spacing.
class NType {
  static const bodyFamily = 'Inter';

  static FontWeight _weight(double w) => FontWeight.values[((w / 100).round() - 1).clamp(0, 8)];

  /// Headings and big numbers.
  static TextStyle display(double size, {Color? color, double weight = 700, double? spacing}) => TextStyle(
        fontFamily: bodyFamily,
        fontSize: size,
        height: 1.1,
        color: color,
        letterSpacing: spacing ?? -size * 0.025,
        fontWeight: _weight(weight > 700 ? 700 : weight),
      );

  static TextStyle body(double size, {Color? color, double weight = 400, double spacing = 0, double height = 1.3}) =>
      TextStyle(
        fontFamily: bodyFamily,
        fontSize: size,
        height: height,
        color: color,
        letterSpacing: spacing == 0 && size >= 15 ? -size * 0.01 : spacing,
        fontWeight: _weight(weight),
      );

  /// Small section header.
  static TextStyle label({Color? color}) => body(13, color: color, weight: 600);
}

ThemeData buildAppTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? KJPalette.dark : KJPalette.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: KJPalette.accent,
    onPrimary: Colors.white,
    secondary: KJPalette.accent,
    onSecondary: Colors.white,
    error: KJPalette.danger,
    onError: Colors.white,
    surface: p.surface,
    onSurface: p.text,
    surfaceContainerHighest: p.surfaceHigh,
    outline: p.border,
  );
  final text = TextTheme(
    displayLarge: NType.display(64, color: p.text),
    displayMedium: NType.display(44, color: p.text),
    displaySmall: NType.display(32, color: p.text),
    headlineMedium: NType.display(26, color: p.text),
    headlineSmall: NType.display(22, color: p.text),
    titleLarge: NType.body(20, color: p.text, weight: 600),
    titleMedium: NType.body(16, color: p.text, weight: 600),
    titleSmall: NType.body(14, color: p.text, weight: 600),
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
    cardTheme: CardThemeData(
        color: p.surface, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22))),
    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: p.text,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: NType.display(22, color: p.text),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: KJPalette.accent,
        foregroundColor: Colors.white,
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        textStyle: NType.body(15, weight: 500),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: KJPalette.accent,
        side: const BorderSide(color: KJPalette.accent),
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: NType.body(15, weight: 500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: KJPalette.accent,
        shape: shape,
        textStyle: NType.body(15, weight: 500),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surfaceHigh,
      labelStyle: NType.body(14, color: p.textDim),
      hintStyle: NType.body(14, color: p.textDim),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: KJPalette.accent, width: 2)),
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
      titleTextStyle: NType.display(22, color: p.text),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.isDark ? p.surfaceHigh : const Color(0xFF1D1D1F),
      contentTextStyle: NType.body(14, color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? KJPalette.green : p.border),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.surfaceHigh,
      selectedColor: KJPalette.accent,
      labelStyle: NType.body(13, color: p.text, weight: 500),
      secondaryLabelStyle: NType.body(13, color: Colors.white, weight: 500),
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
    progressIndicatorTheme: ProgressIndicatorThemeData(color: KJPalette.accent, linearTrackColor: p.surfaceHigh),
  );
}
