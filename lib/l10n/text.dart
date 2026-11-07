import 'package:flutter/widgets.dart' as w;
import 'package:flutter/widgets.dart' show BuildContext, InheritedWidget, InlineSpan, StatelessWidget, TextSpan, Widget;

import 'l10n.dart';

export 'l10n.dart' show tr, trf, tc, weekdayShort, weekdayLetter, monthShort, L10n;

/// Above the app: the language, so every [Text] is drawn again when it changes.
class L10nScope extends InheritedWidget {
  const L10nScope({super.key, required this.code, required super.child});
  final String code;

  static String of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<L10nScope>()?.code ?? L10n.code;

  @override
  bool updateShouldNotify(L10nScope old) => old.code != code;
}

/// Flutter's [w.Text], in the app's language (see [L10n]). Screens import this one instead.
class Text extends StatelessWidget {
  const Text(
    String this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : textSpan = null;

  const Text.rich(
    InlineSpan this.textSpan, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : data = null;

  final String? data;
  final InlineSpan? textSpan;
  final w.TextStyle? style;
  final w.StrutStyle? strutStyle;
  final w.TextAlign? textAlign;
  final w.TextDirection? textDirection;
  final bool? softWrap;
  final w.TextOverflow? overflow;
  final w.TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final w.TextWidthBasis? textWidthBasis;
  final w.TextHeightBehavior? textHeightBehavior;
  final w.Color? selectionColor;

  static InlineSpan _span(InlineSpan s) {
    if (s is! TextSpan) return s;
    return TextSpan(
      text: s.text == null ? null : tr(s.text!),
      style: s.style,
      recognizer: s.recognizer,
      mouseCursor: s.mouseCursor,
      semanticsLabel: s.semanticsLabel,
      children: s.children?.map(_span).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    L10nScope.of(context);
    if (data case final d?) {
      return w.Text(
        tr(d),
        style: style,
        strutStyle: strutStyle,
        textAlign: textAlign,
        textDirection: textDirection,
        softWrap: softWrap,
        overflow: overflow,
        textScaler: textScaler,
        maxLines: maxLines,
        semanticsLabel: semanticsLabel,
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        selectionColor: selectionColor,
      );
    }
    return w.Text.rich(
      _span(textSpan!),
      style: style,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      softWrap: softWrap,
      overflow: overflow,
      textScaler: textScaler,
      maxLines: maxLines,
      semanticsLabel: semanticsLabel,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      selectionColor: selectionColor,
    );
  }
}
