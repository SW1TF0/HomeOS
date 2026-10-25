import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Apple-style colours: the iOS system greys for surfaces, black or white
/// text, system blue for actions and the iOS colours for device kinds.
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
  static const accent = Color(0xFF007AFF);

  /// Errors, deletes, devices that don't answer, alarms.
  static const danger = Color(0xFFFF3B30);

  static const green = Color(0xFF34C759);
  static const yellow = Color(0xFFFFCC00);
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
    text: Color(0xFFFFFFFF),
    textDim: Color(0xFF98989F),
    dot: Color(0xFF2C2C2E),
    onAccent: Color(0xFFFFFFFF),
    shadow: Color(0x00000000),
  );

  static const light = KJPalette(
    background: Color(0xFFF2F2F7),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFE5E5EA),
    border: Color(0xFFD1D1D6),
    text: Color(0xFF000000),
    textDim: Color(0xFF6C6C70),
    dot: Color(0xFFD1D1D6),
    onAccent: Color(0xFFFFFFFF),
    shadow: Color(0x12000000),
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

  /// Background of a device tile that is off: frosted glass, as in Apple Home.
  Color get tileOff => isDark ? const Color(0xB33A3A3C) : const Color(0x14000000);

  /// The white tile of a device that is on, as in Apple Home.
  Color get tileOn => const Color(0xFFFFFFFF);

  /// Text on [tileOn].
  Color get onTileOn => const Color(0xFF000000);

  /// Cards and buttons laid on the home wallpaper.
  Color get glass => isDark ? const Color(0x8C2C2C2E) : const Color(0xA6FFFFFF);

  List<BoxShadow> get cardShadow =>
      shadow.a == 0 ? const [] : [BoxShadow(color: shadow, blurRadius: 10, offset: const Offset(0, 2))];

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

/// Type styles. Inter (SIL OFL) for everything, the closest free font to
/// Apple's San Francisco, on the iOS type scale: 34 large titles, 17 body.
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
  const ios = CupertinoPageTransitionsBuilder();
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
    // iOS slide-in pages and swipe back everywhere, not only on Apple devices.
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: ios,
      TargetPlatform.iOS: ios,
      TargetPlatform.macOS: ios,
      TargetPlatform.windows: ios,
      TargetPlatform.linux: ios,
      TargetPlatform.fuchsia: ios,
    }),
    cupertinoOverrideTheme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: KJPalette.accent,
      scaffoldBackgroundColor: p.background,
      barBackgroundColor: p.surface,
    ),
    highlightColor: Colors.transparent,
    dividerColor: p.border,
    dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
    iconTheme: IconThemeData(color: p.text, size: 22),
    // The iOS back chevron instead of Android's arrow.
    actionIconTheme: ActionIconThemeData(
      backButtonIconBuilder: (_) => const Icon(CupertinoIcons.back, color: KJPalette.accent, size: 28),
      closeButtonIconBuilder: (_) => const Icon(CupertinoIcons.xmark, size: 22),
    ),
    cardTheme: CardThemeData(
        color: p.surface, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: p.text,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: NType.body(17, color: p.text, weight: 600),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: KJPalette.accent,
        foregroundColor: Colors.white,
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        textStyle: NType.body(17, weight: 600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: KJPalette.accent,
        side: const BorderSide(color: KJPalette.accent),
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: NType.body(17, weight: 500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: KJPalette.accent,
        shape: shape,
        textStyle: NType.body(17, weight: 400),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.isDark ? p.surfaceHigh : const Color(0xFFEFEFF4),
      labelStyle: NType.body(14, color: p.textDim),
      hintStyle: NType.body(14, color: p.textDim),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: KJPalette.accent, width: 1.5)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    // iOS sheets: grouped grey background, a small grabber and a dimmed page behind.
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.isDark ? p.surface : p.background,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: Colors.black.withValues(alpha: 0.35),
      showDragHandle: true,
      dragHandleColor: p.isDark ? const Color(0xFF5A5A5E) : const Color(0xFFC7C7CC),
      dragHandleSize: const Size(36, 5),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    ),
    // iOS alerts: small, rounded, frosted.
    dialogTheme: DialogThemeData(
      backgroundColor: p.isDark ? const Color(0xFF2C2C2E) : const Color(0xFFF9F9F9),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titleTextStyle: NType.body(17, color: p.text, weight: 600),
      contentTextStyle: NType.body(14, color: p.text),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.isDark ? p.surfaceHigh : const Color(0xFF1D1D1F),
      contentTextStyle: NType.body(14, color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    // As close to the iOS switch as a Material switch gets: green, white thumb, no outline or icon.
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? KJPalette.green : (p.isDark ? const Color(0xFF39393D) : p.surfaceHigh)),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      thumbIcon: WidgetStateProperty.all(null),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
      titleTextStyle: NType.body(17, color: p.text),
      subtitleTextStyle: NType.body(13, color: p.textDim),
      minLeadingWidth: 28,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.isDark ? const Color(0xFF2C2C2E) : const Color(0xF2F9F9F9),
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      textStyle: NType.body(17, color: p.text),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: KJPalette.accent, linearTrackColor: p.surfaceHigh),
  );
}
