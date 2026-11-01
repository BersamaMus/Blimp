import 'package:flutter/material.dart';

/// A full-screen page that can be dragged down past a threshold to close it,
/// like a sheet. Let go sooner and it settles back. For a route that slides
/// up from the bottom, so closing carries on from where the drag left it.
class DragToClose extends StatefulWidget {
  const DragToClose({super.key, required this.child});

  final Widget child;

  @override
  State<DragToClose> createState() => _DragToCloseState();
}

class _DragToCloseState extends State<DragToClose> with SingleTickerProviderStateMixin {
  late final AnimationController _settle = AnimationController(vsync: this, duration: const Duration(milliseconds: 200))
    ..addListener(() => setState(() => _dragOffset = _settleFrom * (1 - _settle.value)))
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) _setCovering(true);
    });
  double _dragOffset = 0;
  double _settleFrom = 0;

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  /// Whether the screens underneath are hidden. Covered, they're neither
  /// painted nor animated (a playing song's bars in a list behind would
  /// otherwise redraw the whole screen every frame); dragging the page
  /// down shows them again. The route does the same around its own
  /// open and close animations.
  void _setCovering(bool covering) {
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent || route.animation?.status != AnimationStatus.completed) return;
    if (route.overlayEntries.isNotEmpty) route.overlayEntries.first.opaque = covering;
  }

  void _onDragEnd(DragEndDetails details) {
    if (_dragOffset > 140 || (details.primaryVelocity ?? 0) > 700) {
      Navigator.pop(context);
    } else {
      _settleFrom = _dragOffset;
      _settle.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragStart: (_) => _setCovering(false),
      onVerticalDragUpdate: (d) => setState(() => _dragOffset = (_dragOffset + d.delta.dy).clamp(0, double.infinity)),
      onVerticalDragEnd: _onDragEnd,
      child: Transform.translate(
        offset: Offset(0, _dragOffset),
        child: widget.child,
      ),
    );
  }
}
