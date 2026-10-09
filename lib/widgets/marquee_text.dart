import 'package:flutter/material.dart';

/// A single line of text, centred by default. When it's too long to fit, it
/// scrolls sideways in a loop, like a news ticker, pausing on the start each
/// time round so it can be read.
class MarqueeText extends StatefulWidget {
  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.speed = 35,
    this.gap = 48,
    this.startDelay = const Duration(milliseconds: 1500),
    this.textAlign = TextAlign.center,
  });

  final String text;
  final TextStyle? style;

  /// Scroll speed in logical pixels per second.
  final double speed;

  /// Space between the end of the text and its next repeat.
  final double gap;

  final Duration startDelay;

  /// Where the text sits while it fits; scrolling text always starts at the
  /// left.
  final TextAlign textAlign;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this);

  /// Distance of one loop (text width plus gap); null while the text fits.
  double? _loopWidth;
  int _startToken = 0;

  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new song starts again from the beginning.
    if (oldWidget.text != widget.text) _loopWidth = null;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Starts (or stops) scrolling after layout says whether the text fits.
  void _update(double? loopWidth) {
    if (loopWidth == _loopWidth) return;
    _loopWidth = loopWidth;
    final token = ++_startToken;
    _controller
      ..stop()
      ..value = 0;
    if (loopWidth == null) return;
    _controller.duration = Duration(milliseconds: (loopWidth / widget.speed * 1000).round());
    Future.delayed(widget.startDelay, () => _scroll(token));
  }

  /// Scrolls once round, rests on the start for [MarqueeText.startDelay],
  /// and goes again. The rest also lets the screen stop redrawing for a
  /// while, which a nonstop scroll never would.
  void _scroll(int token) {
    if (!mounted || token != _startToken) return;
    // A stopped scroll never completes, ending the loop.
    _controller.forward(from: 0).then((_) => Future.delayed(widget.startDelay, () => _scroll(token)));
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final textWidth = painter.width, textHeight = painter.height;
        painter.dispose();

        final fits = textWidth <= constraints.maxWidth;
        final scrolls = !fits && !reduceMotion;
        // Changing the animation must wait until this build is done.
        final loopWidth = scrolls ? textWidth + widget.gap : null;
        if (loopWidth != _loopWidth) WidgetsBinding.instance.addPostFrameCallback((_) => _update(loopWidth));

        if (!scrolls) {
          return Text(
            widget.text,
            style: style,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            textAlign: widget.textAlign,
          );
        }

        final line = Text(widget.text, style: style, maxLines: 1, softWrap: false);
        // Its own layer, so each animation frame repaints only this line.
        return RepaintBoundary(
          child: SizedBox(
            width: constraints.maxWidth,
            height: textHeight,
            child: ClipRect(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) => Transform.translate(
                  offset: Offset(-_controller.value * (textWidth + widget.gap), 0),
                  child: child,
                ),
                // Two copies side by side, so the loop is seamless.
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  maxWidth: double.infinity,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [line, SizedBox(width: widget.gap), line],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
