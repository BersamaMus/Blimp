import 'package:flutter/widgets.dart';

/// Zooms the whole UI with the window's height, so a maximized or full
/// screen window shows the same layout bigger, rather than the same size
/// with more empty space around it.
class WindowScale extends StatelessWidget {
  const WindowScale({super.key, required this.child});

  final Widget child;

  /// The window height the layout is drawn at its own size for. About the
  /// default window's; anything shorter isn't shrunk.
  static const designHeight = 760.0;

  /// So a very tall screen doesn't make everything huge.
  static const maxScale = 2.0;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final scale = (media.size.height / designHeight).clamp(1.0, maxScale);
    if (scale == 1) return child;
    final size = media.size / scale;
    return FittedBox(
      alignment: Alignment.topLeft,
      child: SizedBox.fromSize(
        size: size,
        child: MediaQuery(
          // Everything below sees the smaller, zoomed size. The pixel ratio
          // goes up to match, so artwork is decoded sharp enough for it.
          data: media.copyWith(
            size: size,
            devicePixelRatio: media.devicePixelRatio * scale,
            padding: media.padding / scale,
            viewPadding: media.viewPadding / scale,
            viewInsets: media.viewInsets / scale,
          ),
          child: child,
        ),
      ),
    );
  }
}
