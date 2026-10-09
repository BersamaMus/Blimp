import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../screens/now_playing_screen.dart';
import '../services/desktop_library.dart';
import '../services/music_controller.dart';
import '../theme.dart';
import 'marquee_text.dart';
import 'shelf.dart';
import 'song_artwork.dart';
import 'song_options.dart';
import 'volume_control.dart';

/// The bar above the tabs showing the current song. Tap or swipe up to open
/// the full player; swipe right for the next song, left for the previous;
/// tap or drag along the bar at the bottom to seek. Hidden until something is queued.
class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> with SingleTickerProviderStateMixin {
  /// Where the progress bar is being dragged to; the artist line shows that
  /// time meanwhile.
  final _seekTo = ValueNotifier<Duration?>(null);

  /// How far the bar is dragged sideways, in pixels.
  late final AnimationController _offset = AnimationController.unbounded(vsync: this);
  double _width = 1;

  /// 1 while sliding off to the next song, -1 to the previous, else 0.
  int _skipping = 0;

  @override
  void dispose() {
    _seekTo.dispose();
    _offset.dispose();
    super.dispose();
  }

  // Swiping right (dx > 0) goes to the next song, left to the previous.
  bool _canGo(AudioPlayer player, int direction) => direction > 0 ? player.hasNext : player.hasPrevious;

  void _onDragUpdate(DragUpdateDetails details, AudioPlayer player) {
    if (_skipping != 0) return;
    _offset.stop();
    var dx = _offset.value + details.delta.dx;
    // Resists when there's nothing that way.
    if (!_canGo(player, dx > 0 ? 1 : -1)) dx = _offset.value + details.delta.dx * 0.3;
    _offset.value = dx;
  }

  void _onDragEnd(DragEndDetails details, AudioPlayer player) {
    if (_skipping != 0) return;
    final velocity = details.primaryVelocity ?? 0;
    final dx = _offset.value;
    // A flick either way, or dragged far enough.
    final direction = velocity.abs() > 300 ? velocity.sign.toInt() : (dx.abs() > _width * 0.3 ? dx.sign.toInt() : 0);
    if (direction == 0 || !_canGo(player, direction)) {
      _offset.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOutBack);
      return;
    }
    _skipping = direction;
    _offset
        .animateTo(direction * _width, duration: const Duration(milliseconds: 180), curve: Curves.easeIn)
        .whenComplete(() async {
          await (direction > 0 ? player.seekToNext() : player.seekToPrevious());
          _skipping = 0;
          if (!mounted) return;
          // The new song slides in from the other side.
          _offset.value = -direction * _width;
          _offset.animateTo(0, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
        });
  }

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.playback, MusicAspect.library});
    final player = music.player;
    final song = music.currentSong;
    if (song == null) return const SizedBox.shrink();

    final textTheme = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth;
        // A desktop window has room for the time and volume beside the buttons.
        final wide = isDesktop && constraints.maxWidth >= 600;
        return GestureDetector(
          onTap: () => openNowPlaying(context),
          onSecondaryTap: () => showSongOptions(context, song),
          onVerticalDragEnd: (details) {
            if ((details.primaryVelocity ?? 0) < -200) openNowPlaying(context);
          },
          onHorizontalDragUpdate: (details) => _onDragUpdate(details, player),
          onHorizontalDragEnd: (details) => _onDragEnd(details, player),
          child: AnimatedBuilder(
            animation: _offset,
            builder: (context, child) => Transform.translate(
              offset: Offset(_offset.value, 0),
              // Fades as it goes. The card has no shadow, so fading is fine here.
              child: Opacity(opacity: (1 - _offset.value.abs() / _width).clamp(0.0, 1.0), child: child),
            ),
            // A floating rounded card above the tab bar.
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Material(
                color: AppColors.surfaceHigh,
                borderRadius: BorderRadius.circular(20),
                clipBehavior: Clip.antiAlias,
                child: SizedBox(
                  height: 70,
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: _SeekBar.thickness),
                        child: Row(
                          children: [
                            const SizedBox(width: 8),
                            Hero(
                              tag: 'now-playing-art',
                              child: SongArtwork(songId: song.id, size: 46, radius: 10),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  MarqueeText(
                                    song.title,
                                    textAlign: TextAlign.start,
                                    style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
                                  ),
                                  ValueListenableBuilder(
                                    valueListenable: _seekTo,
                                    // With the time showing, that shows where a drag will seek to.
                                    builder: (context, seekTo, _) => seekTo == null || wide
                                        ? HiResLine(
                                            hiRes: music.isHiRes(song),
                                            line: MarqueeText(
                                              song.artistName,
                                              textAlign: TextAlign.start,
                                              style: textTheme.bodyMedium,
                                            ),
                                          )
                                        : Text(
                                            '${formatDuration(seekTo)} / ${formatDuration(player.duration ?? Duration.zero)}',
                                            style: textTheme.bodyMedium?.copyWith(color: AppColors.accent),
                                          ),
                                  ),
                                ],
                              ),
                            ),
                            if (wide)
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                child: _TimeLabel(player: player, seekTo: _seekTo),
                              ),
                            IconButton(
                              iconSize: 28,
                              tooltip: 'Previous',
                              icon: const Icon(Icons.skip_previous_rounded),
                              onPressed: MusicScope.read(context).skipToPrevious,
                            ),
                            StreamBuilder<bool>(
                              stream: player.playingStream,
                              initialData: player.playing,
                              builder: (context, snapshot) {
                                final playing = snapshot.data ?? false;
                                return IconButton.filled(
                                  iconSize: 26,
                                  tooltip: playing ? 'Pause' : 'Play',
                                  icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                                  onPressed: playing ? player.pause : player.play,
                                );
                              },
                            ),
                            IconButton(
                              iconSize: 28,
                              tooltip: 'Next',
                              icon: const Icon(Icons.skip_next_rounded),
                              onPressed: player.hasNext ? player.seekToNext : null,
                            ),
                            if (wide) ...[const SizedBox(width: 12), VolumeControl(music: music)],
                            SizedBox(width: wide ? 12 : 4),
                          ],
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: _SeekBar(player: player, seekTo: _seekTo),
                      ),
                    ],
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

/// How far into the song it is, and how long the song is. While the bar is
/// dragged, the time it will seek to.
class _TimeLabel extends StatefulWidget {
  const _TimeLabel({required this.player, required this.seekTo});

  final AudioPlayer player;
  final ValueNotifier<Duration?> seekTo;

  @override
  State<_TimeLabel> createState() => _TimeLabelState();
}

class _TimeLabelState extends State<_TimeLabel> {
  /// What's showing, so a tick only rebuilds when the seconds change.
  String? _shown;

  // Its own clock, stopped with it: a player's position stream keeps its
  // timer running until the player itself goes. Often enough that the
  // seconds don't visibly lag.
  late final Timer _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
    if (_text(widget.player.position) != _shown) setState(() {});
  });

  String _text(Duration position) =>
      '${formatDuration(position)} / ${formatDuration(widget.player.duration ?? Duration.zero)}';

  @override
  void initState() {
    super.initState();
    _tick;
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return ValueListenableBuilder(
      valueListenable: widget.seekTo,
      builder: (context, seekTo, _) {
        final text = _text(seekTo ?? widget.player.position);
        if (seekTo == null) _shown = text;
        return Text(
          text,
          style: style?.copyWith(
            color: seekTo == null ? AppColors.textSecondary : AppColors.accent,
            // So the label doesn't jiggle as the digits change.
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );
      },
    );
  }
}

/// The song's progress along the bottom edge. Tap or drag anywhere along it
/// to jump there; it thickens while dragged. With a mouse, it also thickens
/// under the pointer, and shows the time there above it.
class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.player, required this.seekTo});

  final AudioPlayer player;
  final ValueNotifier<Duration?> seekTo;

  static const thickness = 5.0;

  /// The bar is thin, so it reacts to touches a little above it too.
  static const touchHeight = 20.0;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  // Twice a second is enough for a bar this size, and saves rebuilds while
  // the mini player is on screen.
  late final _position = widget.player.createPositionStream(
    minPeriod: const Duration(milliseconds: 500),
    maxPeriod: const Duration(milliseconds: 500),
  );

  /// 0..1 while being dragged.
  double? _drag;

  /// 0..1 where the mouse is over the bar.
  double? _hover;

  Duration get _total => widget.player.duration ?? Duration.zero;

  void _dragTo(Offset local, double width) {
    final fraction = (local.dx / width).clamp(0.0, 1.0);
    setState(() => _drag = fraction);
    widget.seekTo.value = _total * fraction;
  }

  void _seek() {
    final fraction = _drag;
    if (fraction != null) widget.player.seek(_total * fraction);
    setState(() => _drag = null);
    widget.seekTo.value = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final enabled = _total > Duration.zero;
        // Only with a mouse: a finger hides the bar, and the artist line
        // shows the time instead.
        final tipAt = _hover == null ? null : _drag ?? _hover;
        return MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
          onHover: enabled ? (e) => setState(() => _hover = (e.localPosition.dx / width).clamp(0.0, 1.0)) : null,
          onExit: (_) => setState(() => _hover = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: enabled ? (d) => _dragTo(d.localPosition, width) : null,
            onTapUp: enabled ? (_) => _seek() : null,
            onTapCancel: () {
              setState(() => _drag = null);
              widget.seekTo.value = null;
            },
            onHorizontalDragStart: enabled ? (d) => _dragTo(d.localPosition, width) : null,
            onHorizontalDragUpdate: enabled ? (d) => _dragTo(d.localPosition, width) : null,
            onHorizontalDragEnd: enabled ? (_) => _seek() : null,
            child: Stack(
              // The time sits above the bar, over the song's details.
              clipBehavior: Clip.none,
              children: [
                SizedBox(
                  height: _SeekBar.touchHeight,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: StreamBuilder<Duration>(
                      stream: _position,
                      builder: (context, snapshot) {
                        final total = _total.inMilliseconds;
                        final played = total > 0 ? (snapshot.data ?? Duration.zero).inMilliseconds / total : 0.0;
                        final value = (_drag ?? played).clamp(0.0, 1.0);
                        return seekSemantics(
                          position: snapshot.data ?? Duration.zero,
                          duration: _total,
                          onSeek: widget.player.seek,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            height: _drag == null && _hover == null ? _SeekBar.thickness : _SeekBar.thickness + 3,
                            color: AppColors.outline,
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: value,
                              heightFactor: 1,
                              child: ColoredBox(color: AppColors.accent),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                if (tipAt != null)
                  Positioned(
                    // Kept inside the card at either end.
                    left: (tipAt * width).clamp(28.0, max(28.0, width - 28)),
                    bottom: _SeekBar.thickness + 9,
                    child: IgnorePointer(
                      child: FractionalTranslation(
                        translation: const Offset(-0.5, 0),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.accent,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            formatDuration(_total * tipAt),
                            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: AppColors.onAccent,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
