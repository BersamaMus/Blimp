import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/listening_stats.dart';
import '../services/media_library.dart';
import '../services/music_controller.dart';
import '../services/song_dna.dart';
import '../theme.dart';
import 'shelf.dart';
import 'song_artwork.dart';

/// A card of everything Blimp knows about a song: its shape drawn as a
/// strand of DNA (from its waveform, in its artwork's colour), how and when
/// it's been played, and how it sounds.
Future<void> showSongDna(BuildContext context, Song song) {
  return showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9, maxWidth: 560),
    builder: (_) => _SongDnaCard(song: song),
  );
}

class _SongDnaCard extends StatelessWidget {
  const _SongDnaCard({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.stats, MusicAspect.favourites});
    final dna = music.songDnaOf(song);
    final textTheme = Theme.of(context).textTheme;
    final skipRate = dna.skipRate;
    final rating = music.rating(song);

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        children: [
          Row(
            children: [
              SongArtwork(songId: song.id, size: 56, radius: 10),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Song DNA', style: textTheme.labelMedium?.copyWith(color: AppColors.accent, letterSpacing: 1.2)),
                    Text(song.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: textTheme.titleMedium),
                    Text(song.artistName, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodyMedium),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Helix(song: song),
          const SizedBox(height: 16),
          _TileGrid(
            tiles: [
              ('Plays', '${dna.plays}'),
              ('Listened', formatListeningTime(dna.listened)),
              ('All-time rank', dna.rank == null ? '–' : '#${dna.rank}'),
              ('Skipped', skipRate == null ? '–' : '${(skipRate * 100).round()}%'),
            ],
          ),
          if (dna.plays > 0) ...[
            const _Heading('Plays in the last 12 months'),
            _MonthBars(plays: dna.playsByMonth),
          ],
          const _Heading('History'),
          _Fact('First played', _date(dna.firstPlayed) ?? 'Not yet'),
          _Fact('Last played', _date(dna.lastPlayed) ?? 'Not yet'),
          if (dna.peakHour case final hour?) _Fact('Usually played', partOfDay(hour)),
          _Fact('Added', _date(song.dateAdded)),
          _Fact('Your rating', rating == 0 ? 'Not rated' : '${'★' * rating}${'☆' * (5 - rating)}'),
          if (music.isFavourite(song)) const _Fact('Favourite', 'Yes ♥'),
          const _Heading('Sound'),
          FutureBuilder<AudioFormat?>(
            future: MediaLibrary.getAudioFormat(song),
            builder: (context, snapshot) {
              final format = snapshot.data;
              return Column(
                children: [
                  _Fact('Format', format?.label),
                  _Fact('Bitrate', format?.bitrateText),
                  _Fact('Length', switch (song.duration) {
                    final d? when d > Duration.zero => formatDuration(d),
                    _ => null,
                  }),
                  _Fact('Year', song.year?.toString()),
                  _Fact('Genre', song.genre),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  static String? _date(DateTime? date) {
    if (date == null) return null;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }
}

/// The song's waveform wound into a double helix: each rung's length is
/// how loud that part of the song is, in the artwork's colour.
class _Helix extends StatelessWidget {
  const _Helix({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: FutureBuilder(
        future: Future.wait([MediaLibrary.getWaveform(song.id), MediaLibrary.getDominantColor(song.id)]),
        builder: (context, snapshot) {
          final levels = snapshot.data?[0] as Uint8List? ?? MediaLibrary.cachedWaveform(song.id);
          final color = snapshot.data?[1] as Color?;
          return TweenAnimationBuilder<double>(
            // The strands wind in once the waveform's ready.
            key: ValueKey(levels != null),
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
            builder: (context, t, _) => CustomPaint(
              size: Size.infinite,
              painter: _HelixPainter(levels: levels, color: _bright(color), progress: t),
            ),
          );
        },
      ),
    );
  }

  /// Brightened, so a dark cover still shows on black.
  static Color _bright(Color? color) {
    if (color == null) return AppColors.accent;
    final hsv = HSVColor.fromColor(color);
    return hsv.withValue(max(hsv.value, 0.85)).withSaturation(max(hsv.saturation, 0.45)).toColor();
  }
}

class _HelixPainter extends CustomPainter {
  _HelixPainter({required this.levels, required this.color, required this.progress});

  /// Null while the waveform loads, or if the file can't be read: an even
  /// strand then.
  final Uint8List? levels;
  final Color color;

  /// How far it's wound in, 0..1.
  final double progress;

  static const _rungs = 64;
  static const _turns = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final amplitude = size.height * 0.42;
    final step = size.width / _rungs;
    final levels = this.levels;
    final other = HSVColor.fromColor(color);
    final second = other.withHue((other.hue + 50) % 360).toColor();

    final rung = Paint()..strokeCap = StrokeCap.round;
    final dot = Paint();
    for (var i = 0; i < _rungs; i++) {
      final x = (i + 0.5) * step;
      final level = levels == null
          ? 0.55
          : levels[(i / _rungs * levels.length).floor().clamp(0, levels.length - 1)] / 255;
      final angle = i / _rungs * _turns * 2 * pi - (1 - progress) * pi;
      // The two strands, a half turn apart; how near each is to the viewer
      // sets its size and brightness.
      final a = sin(angle), depth = cos(angle);
      final reach = amplitude * (0.35 + 0.65 * level) * progress;
      final top = Offset(x, centerY - a * reach), bottom = Offset(x, centerY + a * reach);
      rung
        ..strokeWidth = max(1.0, step * 0.25)
        ..color = Color.lerp(color, second, i / _rungs)!.withValues(alpha: 0.25 + 0.35 * level);
      canvas.drawLine(top, bottom, rung);
      dot.color = color.withValues(alpha: 0.55 + 0.45 * (depth + 1) / 2);
      canvas.drawCircle(top, 2 + 1.5 * (depth + 1) / 2, dot);
      dot.color = second.withValues(alpha: 0.55 + 0.45 * (1 - depth) / 2);
      canvas.drawCircle(bottom, 2 + 1.5 * (1 - depth) / 2, dot);
    }
  }

  @override
  bool shouldRepaint(_HelixPainter old) => old.levels != levels || old.color != color || old.progress != progress;
}

/// Big numbers, two to a row.
class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.tiles});

  final List<(String, String)> tiles;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    Widget tile((String, String) t) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(AppRadius.card)),
            child: Column(
              children: [
                FittedBox(child: Text(t.$2, style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
                const SizedBox(height: 2),
                Text(t.$1, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodySmall),
              ],
            ),
          ),
        );
    return Column(
      children: [
        for (var i = 0; i < tiles.length; i += 2) ...[
          if (i > 0) const SizedBox(height: 10),
          Row(
            children: [
              tile(tiles[i]),
              const SizedBox(width: 10),
              if (i + 1 < tiles.length) tile(tiles[i + 1]) else const Spacer(),
            ],
          ),
        ],
      ],
    );
  }
}

/// A small bar for each month's plays, this month on the right.
class _MonthBars extends StatelessWidget {
  const _MonthBars({required this.plays});

  final List<int> plays;

  static const _initials = ['J', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D'];

  @override
  Widget build(BuildContext context) {
    final most = plays.fold(1, max);
    final thisMonth = DateTime.now().month;
    final textTheme = Theme.of(context).textTheme;
    return SizedBox(
      height: 72,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final (i, count) in plays.indexed)
            Expanded(
              child: Tooltip(
                message: count == 1 ? '1 play' : '$count plays',
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      height: max(3.0, 48 * count / most),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: count == 0 ? AppColors.surfaceHigh : AppColors.accent,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(_initials[(thisMonth - 12 + i) % 12], style: textTheme.labelSmall),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: AppColors.accent, letterSpacing: 1.2),
      ),
    );
  }
}

/// A label and its value; left out when the value isn't known.
class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final value = this.value;
    if (value == null) return const SizedBox.shrink();
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 120, child: Text(label, style: textTheme.bodyMedium)),
          Expanded(child: Text(value, style: textTheme.bodyLarge)),
        ],
      ),
    );
  }
}
