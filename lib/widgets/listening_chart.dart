import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/listening_stats.dart';
import '../theme.dart';

/// Listening time per hour, day or month as a single-hue column chart. Tap a
/// column to see its exact value; tapping it again, or elsewhere, clears it.
class ListeningChart extends StatefulWidget {
  const ListeningChart({super.key, required this.buckets, this.height = 180});

  final List<StatsBucket> buckets;
  final double height;

  @override
  State<ListeningChart> createState() => _ListeningChartState();
}

class _ListeningChartState extends State<ListeningChart> {
  int? _selected;

  @override
  void didUpdateWidget(ListeningChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different period has different columns.
    if (oldWidget.buckets.length != widget.buckets.length) _selected = null;
  }

  String get _summary {
    final listened = widget.buckets.where((b) => b.listenedMs > 0);
    if (listened.isEmpty) return 'No listening';
    return listened.map((b) => '${b.title}: ${formatListeningTime(Duration(milliseconds: b.listenedMs))}').join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    return Semantics(
      label: 'Listening time chart',
      value: _summary,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final layout = _ChartLayout(constraints.maxWidth, widget.height, widget.buckets.length);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            // The whole column slot is the target, much bigger than the bar.
            onTapDown: (details) {
              final index = layout.indexAt(details.localPosition.dx);
              setState(() => _selected = index == _selected ? null : index);
            },
            child: CustomPaint(
              size: Size(constraints.maxWidth, widget.height),
              painter: _ChartPainter(
                buckets: widget.buckets,
                layout: layout,
                selected: _selected,
                textScaler: textScaler,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Where the plot area and each column slot sit.
class _ChartLayout {
  _ChartLayout(this.width, this.height, this.count);

  final double width, height;
  final int count;

  static const axisWidth = 40.0; // y labels on the left
  static const labelHeight = 22.0; // x labels below
  static const tooltipSpace = 44.0; // room above the tallest column

  double get plotLeft => axisWidth;
  double get plotTop => tooltipSpace;
  double get plotBottom => height - labelHeight;
  double get plotWidth => width - axisWidth;
  double get slot => count == 0 ? 0 : plotWidth / count;

  /// Never fill the slot: cap at 24 px and leave at least 2 px of air.
  double get barWidth => math.max(2.0, math.min(24.0, slot - 2));

  double slotCenter(int i) => plotLeft + slot * (i + 0.5);

  int? indexAt(double dx) {
    if (count == 0 || dx < plotLeft) return null;
    return ((dx - plotLeft) / slot).floor().clamp(0, count - 1);
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({required this.buckets, required this.layout, required this.selected, required this.textScaler});

  final List<StatsBucket> buckets;
  final _ChartLayout layout;
  final int? selected;
  final TextScaler textScaler;

  /// A round axis maximum in minutes: 1, 2, 5, 10, 15, 30, 60, then hours.
  static int _niceMaxMinutes(double minutes) {
    const steps = [1, 2, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 360, 480, 720, 960, 1440];
    for (final s in steps) {
      if (minutes <= s) return s;
    }
    return (minutes / 1440).ceil() * 1440;
  }

  static String _axisLabel(int minutes) =>
      minutes == 0 ? '0' : minutes % 60 == 0 ? '${minutes ~/ 60}h' : '${minutes}m';

  TextPainter _text(String text, TextStyle style) =>
      TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr, textScaler: textScaler)
        ..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final maxMs = buckets.fold(0, (m, b) => math.max(m, b.listenedMs));
    final maxMinutes = _niceMaxMinutes(math.max(1, maxMs / 60000));
    final plotHeight = layout.plotBottom - layout.plotTop;
    double yFor(double minutes) => layout.plotBottom - plotHeight * (minutes / maxMinutes);

    const axisStyle = TextStyle(fontSize: 11, color: AppColors.textTertiary);
    final grid = Paint()
      ..color = AppColors.divider
      ..strokeWidth = 1;

    // Recessive gridlines at 0, half and the maximum.
    for (final minutes in [0, maxMinutes ~/ 2, maxMinutes]) {
      final y = yFor(minutes.toDouble());
      canvas.drawLine(Offset(layout.plotLeft, y), Offset(size.width, y), grid);
      final label = _text(_axisLabel(minutes), axisStyle);
      label.paint(canvas, Offset(layout.plotLeft - 8 - label.width, y - label.height / 2));
    }

    final bar = Paint();
    final radius = Radius.circular(math.min(4, layout.barWidth / 2));
    for (final (i, b) in buckets.indexed) {
      final x = layout.slotCenter(i);
      if (b.axisLabel.isNotEmpty) {
        final label = _text(b.axisLabel, axisStyle);
        label.paint(canvas, Offset(x - label.width / 2, layout.plotBottom + 6));
      }
      if (b.listenedMs == 0) continue;
      final top = yFor(b.listenedMs / 60000);
      // While one column is selected, the rest step back.
      bar.color = selected == null || selected == i ? AppColors.accent : AppColors.accent.withValues(alpha: 0.35);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(x - layout.barWidth / 2, math.min(top, layout.plotBottom - 2), x + layout.barWidth / 2,
              layout.plotBottom),
          topLeft: radius,
          topRight: radius,
        ),
        bar,
      );
    }

    final index = selected;
    if (index != null && index < buckets.length) _paintTooltip(canvas, size, buckets[index], index, yFor);
  }

  void _paintTooltip(Canvas canvas, Size size, StatsBucket b, int index, double Function(double) yFor) {
    final title = _text(b.title, const TextStyle(fontSize: 12, color: AppColors.textSecondary));
    final value = _text(
      b.listenedMs == 0 ? 'No listening' : formatListeningTime(Duration(milliseconds: b.listenedMs)),
      const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white),
    );
    const pad = 8.0;
    final width = math.max(title.width, value.width) + pad * 2;
    final height = title.height + value.height + pad * 2;
    final x = layout.slotCenter(index);
    final columnTop = yFor(b.listenedMs / 60000);
    final left = (x - width / 2).clamp(0.0, size.width - width);
    final top = math.max(0.0, columnTop - height - 6);

    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(left, top, width, height), const Radius.circular(10)),
      Paint()..color = AppColors.surfaceHigh,
    );
    title.paint(canvas, Offset(left + pad, top + pad));
    value.paint(canvas, Offset(left + pad, top + pad + title.height));
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.buckets != buckets || old.selected != selected || old.layout.width != layout.width;
}

/// A ranked horizontal bar for one genre's share of listening time.
class ShareBar extends StatelessWidget {
  const ShareBar({super.key, required this.label, required this.share, required this.detail});

  final String label;

  /// 0 to 1.
  final double share;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      label: '$label, ${(share * 100).round()} percent, $detail',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodyLarge)),
                Text('${(share * 100).round()}%', style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 6),
            // A same-hue track behind the fill, like a meter.
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 8,
                child: LinearProgressIndicator(
                  value: share.clamp(0, 1),
                  color: AppColors.accent,
                  backgroundColor: AppColors.accentSoft,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(detail, style: textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
