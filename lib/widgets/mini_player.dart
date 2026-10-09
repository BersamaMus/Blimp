import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../screens/now_playing_screen.dart';
import '../services/music_controller.dart';
import '../theme.dart';
import 'marquee_text.dart';
import 'shelf.dart';
import 'song_artwork.dart';

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
        return GestureDetector(
          onTap: () => openNowPlaying(context),
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
                                    builder: (context, seekTo, _) => seekTo == null
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
                            const SizedBox(width: 4),
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

/// The song's progress along the bottom edge. Tap or drag anywhere along it
/// to jump there; it thickens while dragged.
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
        return GestureDetector(
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
          child: SizedBox(
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
                      height: _drag == null ? _SeekBar.thickness : _SeekBar.thickness + 3,
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
        );
      },
    );
  }
}
