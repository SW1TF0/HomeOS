import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;

import '../../state/history.dart';
import '../../theme/app_theme.dart';
import '../../util/clock_text.dart';
import '../../l10n/text.dart';

/// A reading over the last day or week, as in the Health app: the line with a soft fill, the lowest and highest
/// value, and a finger dragged across it shows the value at that time.
class HistoryChart extends StatefulWidget {
  const HistoryChart({
    super.key,
    required this.series,
    required this.from,
    required this.to,
    required this.color,
    this.h24 = true,
    this.height = 150,
  });

  final Series series;
  final DateTime from;
  final DateTime to;
  final Color color;
  final bool h24;
  final double height;

  @override
  State<HistoryChart> createState() => _HistoryChartState();
}

class _HistoryChartState extends State<HistoryChart> {
  /// Where the finger is, from 0 (left) to 1 (right). Null when nothing is touched.
  double? _at;

  List<(DateTime, double)> get _points => widget.series.since(widget.from);

  static String number(double v) {
    final a = v.abs();
    if (a >= 100 || v == v.roundToDouble()) return v.round().toString();
    return v.toStringAsFixed(a >= 10 ? 1 : (a >= 1 ? 1 : 2));
  }

  String _withUnit(double v) {
    final u = widget.series.unit;
    if (u.isEmpty) return number(v);
    return u == '°' || u == '%' ? '${number(v)}$u' : '${number(v)} $u';
  }

  (DateTime, double)? _nearest(List<(DateTime, double)> points, double at) {
    if (points.isEmpty) return null;
    final span = widget.to.difference(widget.from).inMilliseconds;
    final t = widget.from.add(Duration(milliseconds: (span * at).round()));
    var best = points.first;
    for (final p in points) {
      if ((p.$1.difference(t)).abs() < (best.$1.difference(t)).abs()) best = p;
    }
    return best;
  }

  String _when(DateTime t) {
    final day = widget.to.difference(widget.from) > const Duration(hours: 30);
    return day ? '${weekdayShort(t.weekday)} ${clockText(t, widget.h24)}' : clockText(t, widget.h24);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final points = _points;
    final touched = _at == null ? null : _nearest(points, _at!);
    final shown = touched ?? (points.isEmpty ? null : points.last);
    final values = points.map((e) => e.$2);
    final low = values.isEmpty ? null : values.reduce(math.min);
    final high = values.isEmpty ? null : values.reduce(math.max);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(shown == null ? '—' : _withUnit(shown.$2),
            key: const Key('chart-value'), style: NType.display(28, color: p.text)),
        const SizedBox(width: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              touched != null
                  ? _when(touched.$1)
                  : (low == null || high == null || low == high ? 'Now' : 'Low ${_withUnit(low)} · High ${_withUnit(high)}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NType.body(13, color: p.textDim),
            ),
          ),
        ),
      ]),
      const SizedBox(height: 10),
      LayoutBuilder(builder: (context, c) {
        void touch(Offset local) => setState(() => _at = (local.dx / c.maxWidth).clamp(0.0, 1.0));
        return GestureDetector(
          onHorizontalDragStart: (d) => touch(d.localPosition),
          onHorizontalDragUpdate: (d) => touch(d.localPosition),
          onHorizontalDragEnd: (_) => setState(() => _at = null),
          onTapDown: (d) => touch(d.localPosition),
          onTapUp: (_) => setState(() => _at = null),
          child: SizedBox(
            width: c.maxWidth,
            height: widget.height,
            child: CustomPaint(
              painter: _ChartPainter(
                points: points,
                from: widget.from,
                to: widget.to,
                color: widget.color,
                grid: p.border,
                label: p.textDim,
                touched: touched,
                h24: widget.h24,
              ),
            ),
          ),
        );
      }),
    ]);
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.points,
    required this.from,
    required this.to,
    required this.color,
    required this.grid,
    required this.label,
    required this.touched,
    required this.h24,
  });

  final List<(DateTime, double)> points;
  final DateTime from;
  final DateTime to;
  final Color color;
  final Color grid;
  final Color label;
  final (DateTime, double)? touched;
  final bool h24;

  static const _axis = 18.0;

  @override
  void paint(Canvas canvas, Size size) {
    final chart = Rect.fromLTWH(0, 6, size.width, size.height - _axis - 6);
    final span = to.difference(from).inMilliseconds.toDouble();
    final values = points.map((p) => p.$2);
    var low = values.isEmpty ? 0.0 : values.reduce(math.min);
    var high = values.isEmpty ? 1.0 : values.reduce(math.max);
    if (high - low < 1e-6) {
      low -= 1;
      high += 1;
    }
    final pad = (high - low) * 0.12;
    low -= pad;
    high += pad;
    double x(DateTime t) => chart.left + chart.width * (t.difference(from).inMilliseconds / span).clamp(0.0, 1.0);
    double y(double v) => chart.bottom - chart.height * ((v - low) / (high - low));

    // Three faint lines across, and the times along the bottom.
    final line = Paint()
      ..color = grid
      ..strokeWidth = 0.5;
    for (var i = 0; i <= 2; i++) {
      final gy = chart.top + chart.height * i / 2;
      canvas.drawLine(Offset(chart.left, gy), Offset(chart.right, gy), line);
    }
    final week = to.difference(from) > const Duration(hours: 30);
    for (var i = 0; i < 4; i++) {
      final t = from.add(Duration(milliseconds: (span * (i + 0.5) / 4).round()));
      final text = week ? weekdayShort(t.weekday) : clockText(DateTime(t.year, t.month, t.day, t.hour), h24);
      final tp = TextPainter(
        text: TextSpan(text: text, style: NType.body(10.5, color: label)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x(t) - tp.width / 2, size.height - tp.height));
    }
    if (points.isEmpty) return;

    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final o = Offset(x(points[i].$1), y(points[i].$2));
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    if (points.length == 1) path.lineTo(x(points.first.$1) + 1, y(points.first.$2));
    final fill = Path.from(path)
      ..lineTo(x(points.last.$1), chart.bottom)
      ..lineTo(x(points.first.$1), chart.bottom)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0.02)],
        ).createShader(chart),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    final mark = touched ?? points.last;
    final at = Offset(x(mark.$1), y(mark.$2));
    if (touched != null) {
      canvas.drawLine(Offset(at.dx, chart.top), Offset(at.dx, chart.bottom), Paint()
        ..color = color.withValues(alpha: 0.5)
        ..strokeWidth = 1);
    }
    canvas.drawCircle(at, 5.5, Paint()..color = Colors.white);
    canvas.drawCircle(at, 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.points != points || old.touched != touched || old.color != color || old.from != from || old.grid != grid;
}
