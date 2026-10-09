import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../screens/now_playing_screen.dart';
import '../services/media_library.dart';
import '../services/listening_stats.dart';
import '../services/music_controller.dart';
import '../theme.dart';
import 'shelf.dart';
import 'song_artwork.dart';
import 'song_options.dart';

/// A song row: artwork (or track number), title, subtitle and a menu button.
/// The playing song gets a soft teal highlight, teal title and moving bars.
class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.song,
    required this.onTap,
    this.subtitle,
    this.trackNumber,
    this.rank,
    this.showFavourite = false,
  });

  final Song song;
  final FutureOr<void> Function() onTap;

  /// Defaults to "Artist • Album".
  final String? subtitle;

  /// Shows a track number instead of artwork, as on album pages.
  final int? trackNumber;

  /// Shows a chart position before the artwork.
  final int? rank;

  /// Adds a heart button to favourite the song in one tap.
  final bool showFavourite;

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, {
      MusicAspect.playback,
      // Hi-res badges arrive as songs are checked.
      MusicAspect.library,
      if (showFavourite) MusicAspect.favourites,
    });
    final isCurrent = music.currentSong == song;
    final textTheme = Theme.of(context).textTheme;

    final Widget leading = trackNumber != null
        ? SizedBox(
            width: 32,
            child: isCurrent
                ? const Center(child: PlayingIndicator(size: 16))
                : Text(
                    '$trackNumber',
                    textAlign: TextAlign.center,
                    style: textTheme.titleMedium?.copyWith(color: AppColors.textSecondary),
                  ),
          )
        : SongArtwork(songId: song.id, size: 52);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Material(
        color: isCurrent ? AppColors.accentFaint : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.card),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => playAndOpen(context, onTap),
          onLongPress: () => showSongOptions(context, song),
          child: Padding(
            padding: const EdgeInsets.only(left: 12, top: 8, bottom: 8),
            child: Row(
              children: [
                if (rank != null)
                  SizedBox(
                    width: 32,
                    child: Text(
                      '$rank',
                      style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: AppColors.accent),
                    ),
                  ),
                leading,
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyLarge?.copyWith(color: isCurrent ? AppColors.accent : null),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (music.isHiRes(song)) ...[const HiResBadge(), const SizedBox(width: 6)],
                          Expanded(
                            child: Text(
                              [
                                subtitle ?? [song.artistName, ?song.album].join(' • '),
                                ?_timeLeft(music),
                              ].join(' • '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                      // How far through a podcast, audiobook or long mix is.
                      if (music.resumeProgress(song) case final progress?) ...[
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 3,
                            color: AppColors.accent,
                            backgroundColor: AppColors.surfaceHigh,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (isCurrent && trackNumber == null) ...[const SizedBox(width: 8), const PlayingIndicator(size: 16)],
                if (showFavourite)
                  IconButton(
                    tooltip: music.isFavourite(song) ? 'Remove from Favourites' : 'Add to Favourites',
                    icon: Icon(music.isFavourite(song) ? Icons.favorite : Icons.favorite_border),
                    color: music.isFavourite(song) ? AppColors.favourite : AppColors.textSecondary,
                    onPressed: () => music.toggleFavourite(song),
                  ),
                IconButton(
                  tooltip: 'More',
                  icon: const Icon(Icons.more_vert),
                  color: AppColors.textSecondary,
                  onPressed: () => showSongOptions(context, song),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// "12 min left" for a song partway through, as [ResumePoints] keeps.
  String? _timeLeft(MusicController music) {
    final at = music.resumeAt(song), length = song.duration;
    if (at == null || length == null) return null;
    final left = length - at;
    return left.inMinutes < 1 ? 'Under a minute left' : '${formatListeningTime(left)} left';
  }
}

/// Three bouncing bars that animate while audio is playing.
class PlayingIndicator extends StatefulWidget {
  const PlayingIndicator({super.key, this.size = 20, this.color});

  final double size;

  /// The theme's accent unless given.
  final Color? color;

  @override
  State<PlayingIndicator> createState() => _PlayingIndicatorState();
}

class _PlayingIndicatorState extends State<PlayingIndicator> {
  /// Steps through the loop on a timer at 12 fps. A tiny icon looks the same
  /// as at 60, and an animation running every frame would make the whole
  /// screen redraw every frame.
  static const _step = Duration(milliseconds: 83);
  static const _loop = Duration(milliseconds: 900);

  final _clock = Stopwatch();
  Timer? _timer;
  double _t = 0;
  StreamSubscription<bool>? _playingSub;
  bool _playing = false;

  /// False while a screen covers this one, like Flutter's tickers.
  ValueListenable<TickerModeData>? _tickerMode;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerMode?.removeListener(_update);
    _tickerMode = TickerMode.getValuesNotifier(context)..addListener(_update);
    if (_playingSub == null) {
      final player = MusicScope.read(context).player;
      _playing = player.playing;
      _playingSub = player.playingStream.listen((playing) {
        _playing = playing;
        _update();
      });
    }
    _update();
  }

  void _update() {
    final run = _playing && (_tickerMode?.value.enabled ?? true);
    if (run && _timer == null) {
      _clock.start();
      _timer = Timer.periodic(_step, (_) {
        setState(() => _t = (_clock.elapsedMilliseconds % _loop.inMilliseconds) / _loop.inMilliseconds);
      });
    } else if (!run && _timer != null) {
      _clock.stop();
      _timer!.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _playingSub?.cancel();
    _tickerMode?.removeListener(_update);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(painter: _BarsPainter(_t, widget.color ?? AppColors.accent)),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.t, this.color);

  final double t;
  final Color color;

  // Each bar's height follows its own repeating wave.
  static const _phases = [0.0, 0.55, 0.25];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final barWidth = size.width / 5;
    for (var i = 0; i < 3; i++) {
      final wave = ((t + _phases[i]) % 1.0);
      final height = size.height * (0.3 + 0.7 * (1 - (2 * wave - 1).abs()));
      final left = barWidth * (i * 2);
      canvas.drawRRect(
        RRect.fromLTRBR(left, size.height - height, left + barWidth, size.height, const Radius.circular(1)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.t != t || old.color != color;
}
