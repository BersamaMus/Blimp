import 'package:flutter/material.dart';

import '../theme.dart';

/// A section heading with an optional teal action such as "See all".
class ShelfHeader extends StatelessWidget {
  const ShelfHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.actionIcon,
    this.onAction,
    this.extraActions = const [],
  });

  final String title;
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? onAction;

  /// Icon buttons shown before the main action.
  final List<Widget> extraActions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ...extraActions,
          if (actionLabel != null)
            actionIcon == null
                ? TextButton(onPressed: onAction, child: Text(actionLabel!))
                : TextButton.icon(onPressed: onAction, icon: Icon(actionIcon, size: 20), label: Text(actionLabel!)),
        ],
      ),
    );
  }
}

/// A stadium-shaped button: solid teal when [filled], otherwise a soft
/// teal-tinted "tonal" style for secondary actions.
class PillButton extends StatelessWidget {
  const PillButton({super.key, required this.label, this.icon, this.onPressed, this.filled = false});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      minimumSize: const Size(0, 40),
      backgroundColor: filled ? AppColors.accent : AppColors.accentSoft,
      foregroundColor: filled ? AppColors.onAccent : AppColors.accent,
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    );
    return icon == null
        ? FilledButton(style: style, onPressed: onPressed, child: Text(label))
        : FilledButton.icon(style: style, onPressed: onPressed, icon: Icon(icon, size: 20), label: Text(label));
  }
}

/// A row of pill-shaped filter chips; the selected one is filled with the
/// accent. [tonal] chips are quieter, outlined, for a second row of filters.
class ChipBar extends StatelessWidget {
  const ChipBar({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.tonal = false,
  });

  final List<String> labels;
  final int? selected;
  final ValueChanged<int> onSelected;
  final EdgeInsets padding;
  final bool tonal;

  @override
  Widget build(BuildContext context) {
    // The space above and below each chip is part of its tap target, so it's
    // the 48 points tall Android asks for, though the chip looks smaller.
    final gap = tonal ? 7.0 : 8.0;
    return SizedBox(
      height: tonal ? 48 : 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: labels.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onSelected(i),
          excludeFromSemantics: true,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: gap),
            child: _chip(i),
          ),
        ),
      ),
    );
  }

  Widget _chip(int i) {
    final isSelected = i == selected;
    final (background, foreground) = switch ((tonal, isSelected)) {
      (false, true) => (AppColors.accent, AppColors.onAccent),
      (false, false) => (AppColors.surfaceHigh, Colors.white),
      (true, true) => (AppColors.accentSoft, AppColors.accent),
      (true, false) => (Colors.transparent, AppColors.textSecondary),
    };
    return Semantics(
      selected: isSelected,
      button: true,
      child: Material(
        color: background,
        shape: StadiumBorder(
          side: tonal ? BorderSide(color: isSelected ? AppColors.accent : AppColors.outline) : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onSelected(i),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: tonal ? 14 : 16),
            child: Center(
              child: Text(
                labels[i],
                style: TextStyle(fontSize: tonal ? 13 : 14, fontWeight: FontWeight.w600, color: foreground),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A horizontally scrolling row of cards.
class Shelf extends StatelessWidget {
  const Shelf({super.key, required this.height, required this.itemCount, required this.itemBuilder});

  final double height;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: itemCount,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: itemBuilder,
      ),
    );
  }
}

/// Artwork with a title and subtitle beneath, as used for albums and
/// (with [circle]) artists. Under a mouse, the artwork lifts a little and,
/// given [onPlay], shows a play button.
class MediaCard extends StatefulWidget {
  const MediaCard({
    super.key,
    required this.art,
    required this.title,
    this.subtitle,
    this.width = 160,
    this.circle = false,
    this.onTap,
    this.onLongPress,
    this.onPlay,
    this.hiRes = false,
  });

  final Widget art;
  final String title;
  final String? subtitle;
  final double width;
  final bool circle;

  /// Shows a [HiResBadge] before the subtitle.
  final bool hiRes;
  final VoidCallback? onTap;

  /// Also on a right-click.
  final VoidCallback? onLongPress;

  /// Plays it straight away, from the button shown while hovered.
  final VoidCallback? onPlay;

  @override
  State<MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<MediaCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final MediaCard(:width, :circle, :title, :subtitle, :hiRes, :onPlay) = widget;
    const fade = Duration(milliseconds: 150);
    return SizedBox(
      width: width,
      child: MouseRegion(
        cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          onSecondaryTap: widget.onLongPress,
          child: Column(
            crossAxisAlignment: circle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              SizedBox.square(
                dimension: width,
                child: AnimatedScale(
                  scale: _hovered ? 1.04 : 1,
                  duration: fade,
                  curve: Curves.easeOut,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      widget.art,
                      if (onPlay != null)
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: AnimatedOpacity(
                            opacity: _hovered ? 1 : 0,
                            duration: fade,
                            child: IgnorePointer(
                              ignoring: !_hovered,
                              child: IconButton.filled(
                                tooltip: 'Play',
                                style: IconButton.styleFrom(
                                  backgroundColor: AppColors.accent,
                                  foregroundColor: AppColors.onAccent,
                                  elevation: 4,
                                  shadowColor: Colors.black,
                                ),
                                icon: const Icon(Icons.play_arrow_rounded),
                                onPressed: onPlay,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                title,
                maxLines: circle ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                textAlign: circle ? TextAlign.center : TextAlign.start,
                style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600, height: 1.25),
              ),
              if (subtitle != null)
                HiResLine(
                  hiRes: hiRes,
                  center: circle,
                  line: Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: circle ? TextAlign.center : TextAlign.start,
                    style: textTheme.bodyMedium,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Centered icon, message and action, for empty and error states.
class MessageView extends StatelessWidget {
  const MessageView({super.key, required this.icon, required this.text, this.actionLabel, this.onAction});

  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: AppColors.accentSoft, shape: BoxShape.circle),
              child: Icon(icon, size: 40, color: AppColors.accent),
            ),
            const SizedBox(height: 20),
            Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
            if (actionLabel != null) ...[
              const SizedBox(height: 20),
              PillButton(label: actionLabel!, onPressed: onAction, filled: true),
            ],
          ],
        ),
      ),
    );
  }
}

/// Makes a custom seek bar a slider for screen readers: it reads out where
/// the song is ("1:23 of 3:45"), and swiping up or down moves 10 seconds.
Widget seekSemantics({
  required Duration position,
  required Duration duration,
  required ValueChanged<Duration> onSeek,
  required Widget child,
}) {
  const step = Duration(seconds: 10);
  Duration clamp(Duration d) => d < Duration.zero ? Duration.zero : (d > duration ? duration : d);
  String describe(Duration d) => '${formatDuration(d)} of ${formatDuration(duration)}';
  final enabled = duration > Duration.zero;
  return Semantics(
    slider: true,
    label: 'Seek',
    value: describe(position),
    increasedValue: describe(clamp(position + step)),
    decreasedValue: describe(clamp(position - step)),
    onIncrease: enabled ? () => onSeek(clamp(position + step)) : null,
    onDecrease: enabled ? () => onSeek(clamp(position - step)) : null,
    child: ExcludeSemantics(child: child),
  );
}

String formatDuration(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60);
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds' : '$minutes:$seconds';
}

/// "820 KB", "4.2 MB" and so on.
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

/// "1 song" / "5 songs • 23 minutes", as shown under collection headers.
String describeLength(int count, Duration total) {
  final songs = count == 1 ? '1 song' : '$count songs';
  final minutes = total.inMinutes;
  if (minutes == 0) return songs;
  if (minutes < 60) return '$songs • $minutes ${minutes == 1 ? 'minute' : 'minutes'}';
  final hours = total.inHours;
  final rest = minutes.remainder(60);
  return '$songs • $hours ${hours == 1 ? 'hour' : 'hours'}${rest > 0 ? ' $rest min' : ''}';
}

/// A rounded segmented control: the picked segment filled with the accent.
class SegmentedPills extends StatelessWidget {
  const SegmentedPills({super.key, required this.labels, this.icons, required this.selected, required this.onChanged});

  final List<String> labels;

  /// One per label, shown before it; optional.
  final List<IconData>? icons;
  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: const ShapeDecoration(color: AppColors.surface, shape: StadiumBorder()),
      child: Row(
        children: [
          for (final (i, label) in labels.indexed)
            Expanded(
              child: Semantics(
                selected: i == selected,
                button: true,
                child: Material(
                  color: i == selected ? AppColors.accent : Colors.transparent,
                  shape: const StadiumBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => onChanged(i),
                    child: SizedBox(
                      height: 38,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (icons case final icons?) ...[
                            Icon(icons[i], size: 18, color: i == selected ? AppColors.onAccent : AppColors.textSecondary),
                            const SizedBox(width: 8),
                          ],
                          Text(
                            label,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              color: i == selected ? AppColors.onAccent : AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
/// A small gold "HI-RES" tag, for lossless songs better than CD quality.
class HiResBadge extends StatelessWidget {
  const HiResBadge({super.key, this.fontSize = 9});

  final double fontSize;

  static const color = Color(0xFFF7B733);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Hi-res',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          'HI-RES',
          style: TextStyle(color: color, fontSize: fontSize, fontWeight: FontWeight.w800, letterSpacing: 0.4, height: 1.3),
        ),
      ),
    );
  }
}

/// [line] (a song's artist or other subtitle) with a [HiResBadge] before it
/// when [hiRes]. [center] keeps the two centred, as under the player's title.
class HiResLine extends StatelessWidget {
  const HiResLine({super.key, required this.hiRes, required this.line, this.center = false});

  final bool hiRes;
  final Widget line;
  final bool center;

  @override
  Widget build(BuildContext context) {
    if (!hiRes) return line;
    return Row(
      mainAxisSize: center ? MainAxisSize.min : MainAxisSize.max,
      mainAxisAlignment: center ? MainAxisAlignment.center : MainAxisAlignment.start,
      children: [
        const HiResBadge(),
        const SizedBox(width: 6),
        Flexible(child: line),
      ],
    );
  }
}
