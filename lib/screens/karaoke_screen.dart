import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/lyrics.dart';
import '../services/media_library.dart';
import '../services/music_controller.dart';
import '../theme.dart';
import '../widgets/shelf.dart';

/// Opens the playing song's lyrics full screen, to sing along.
Future<void> openKaraoke(BuildContext context) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 300),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, _, _) => const KaraokeScreen(),
      transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
    ),
  );
}

/// The lyrics big and centred, a line at a time: the line being sung fills
/// with colour as it's sung, word by word when the lyrics time each word,
/// with the next lines below. It follows the player onto the next song.
class KaraokeScreen extends StatelessWidget {
  const KaraokeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.playback});
    final song = music.currentSong;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: FutureBuilder<Color?>(
        future: song == null ? null : MediaLibrary.getDominantColor(song.id),
        builder: (context, snapshot) => TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: backdropColor(snapshot.data)),
          duration: const Duration(milliseconds: 600),
          builder: (context, color, child) => DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [color!, Colors.black],
              ),
            ),
            child: child,
          ),
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 16, 0),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Close',
                        icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(song?.title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.titleMedium),
                            Text(song?.artistName ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodySmall),
                          ],
                        ),
                      ),
                      const Icon(Icons.mic_external_on_rounded, color: AppColors.accent),
                    ],
                  ),
                ),
                Expanded(
                  child: song == null
                      ? const SizedBox.shrink()
                      : FutureBuilder<Lyrics?>(
                          key: ValueKey(song.id),
                          future: MediaLibrary.getLyrics(song),
                          builder: (context, snapshot) => switch (snapshot.data) {
                            final lyrics? when lyrics.synced => _SingAlong(lyrics: lyrics),
                            _ when snapshot.connectionState != ConnectionState.done => const SizedBox.shrink(),
                            _ => const MessageView(
                                icon: Icons.lyrics_outlined,
                                text: 'This song has no timed lyrics to sing along to.',
                              ),
                          },
                        ),
                ),
                const _Controls(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SingAlong extends StatefulWidget {
  const _SingAlong({required this.lyrics});

  final Lyrics lyrics;

  @override
  State<_SingAlong> createState() => _SingAlongState();
}

class _SingAlongState extends State<_SingAlong> with SingleTickerProviderStateMixin {
  /// Read from the player every frame, so the colour sweeps smoothly rather
  /// than in the steps position updates come in.
  final _position = ValueNotifier(Duration.zero);
  late final Ticker _ticker;
  MusicController? _music;
  // The ticker only runs while playing, to save the battery while paused.
  // A seek while paused still comes through here.
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _positionSub;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      final music = _music;
      if (music != null) _position.value = music.player.position;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final music = MusicScope.read(context);
    if (identical(music, _music)) return;
    _music = music;
    _playingSub?.cancel();
    _positionSub?.cancel();
    _playingSub = music.player.playingStream.listen((playing) {
      if (playing && !_ticker.isActive) _ticker.start();
      if (!playing && _ticker.isActive) _ticker.stop();
    });
    _positionSub = music.player.positionStream.listen((position) {
      if (!_ticker.isActive) _position.value = position;
    });
  }

  @override
  void dispose() {
    _playingSub?.cancel();
    _positionSub?.cancel();
    _ticker.dispose();
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = widget.lyrics;
    final lines = lyrics.lines;
    final width = MediaQuery.sizeOf(context).width;
    // Big, but not so big a long line needs more than a few rows.
    final size = (width / 14).clamp(26.0, 46.0);
    final sungStyle = TextStyle(fontSize: size, height: 1.25, fontWeight: FontWeight.w800, letterSpacing: -0.5);
    final comingStyle = TextStyle(
      fontSize: size * 0.62,
      height: 1.3,
      fontWeight: FontWeight.w700,
      color: Colors.white.withValues(alpha: 0.45),
    );

    return ValueListenableBuilder<Duration>(
      valueListenable: _position,
      builder: (context, position, _) {
        final index = lyrics.lineAt(position);
        final songEnd = _music?.player.duration;
        final next = index + 1 < lines.length ? lines[index + 1] : null;
        final untilNext = next == null ? null : next.time! - position;
        final current = index >= 0 ? lines[index] : null;
        // Between lines: before the first, on an instrumental gap, or long
        // after a line was sung with the next still a way off.
        final resting = current == null ||
            current.text.isEmpty ||
            (untilNext != null && position - current.time! > _fillTime(current, lyrics.endOf(index, songEnd: songEnd)) + const Duration(seconds: 3));

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, 0.15), end: Offset.zero).animate(animation),
              child: child,
            ),
          ),
          child: Padding(
            key: ValueKey((index, resting)),
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (resting) ...[
                  Text('♪', style: sungStyle.copyWith(color: AppColors.accent)),
                  const SizedBox(height: 12),
                  _Countdown(left: untilNext),
                ] else
                  _SungLine(
                    text: current.text,
                    filled: _filled(current, position, lyrics.endOf(index, songEnd: songEnd)),
                    style: sungStyle,
                  ),
                const SizedBox(height: 28),
                for (final line in lines.skip(index + 1).where((l) => l.text.isNotEmpty).take(2))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(line.text, textAlign: TextAlign.center, style: comingStyle),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// How long a line without word timings takes to fill: until the next
  /// line, but no slower than singing at an easy pace, so a line followed
  /// by a long instrumental doesn't crawl.
  static Duration _fillTime(LyricLine line, Duration? end) {
    final pace = Duration(milliseconds: 600 + line.text.characters.length * 110);
    final until = end == null ? pace : end - line.time!;
    return until < pace ? until : pace;
  }

  /// How many of [line]'s characters have been sung at [position],
  /// fractional partway through one.
  static double _filled(LyricLine line, Duration position, Duration? end) {
    double share(Duration from, Duration to) =>
        to <= from ? 1 : ((position - from).inMicroseconds / (to - from).inMicroseconds).clamp(0.0, 1.0);

    final words = line.words;
    if (words == null) {
      return line.text.characters.length * share(line.time!, line.time! + _fillTime(line, end));
    }
    var filled = 0.0;
    for (final (i, word) in words.indexed) {
      if (position < word.time) break;
      // The last word is held a second at most, however long the line lasts.
      final wordEnd = i + 1 < words.length
          ? words[i + 1].time
          : switch (end) {
              final end? when end - word.time < const Duration(seconds: 1) => end,
              _ => word.time + const Duration(seconds: 1),
            };
      filled += word.text.characters.length * share(word.time, wordEnd);
    }
    return filled;
  }
}

/// A line of lyrics coloured in up to [filled] characters, the character
/// partway through blending in.
class _SungLine extends StatelessWidget {
  const _SungLine({required this.text, required this.filled, required this.style});

  final String text;
  final double filled;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final chars = text.characters.toList();
    final whole = min(filled.floor(), chars.length);
    final part = filled - whole;
    return Text.rich(
      TextSpan(
        style: style.copyWith(color: Colors.white),
        children: [
          TextSpan(text: chars.take(whole).join(), style: const TextStyle(color: AppColors.accent)),
          if (whole < chars.length)
            TextSpan(text: chars[whole], style: TextStyle(color: Color.lerp(Colors.white, AppColors.accent, part))),
          if (whole + 1 < chars.length) TextSpan(text: chars.skip(whole + 1).join()),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}

/// Dots counting down the last three seconds before the next line.
class _Countdown extends StatelessWidget {
  const _Countdown({required this.left});

  /// Until the next line; null after the last.
  final Duration? left;

  @override
  Widget build(BuildContext context) {
    final left = this.left;
    final dots = left == null || left > const Duration(seconds: 3) ? 0 : (left.inMilliseconds / 1000).ceil();
    return SizedBox(
      height: 16,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < 3; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 12,
              height: 12,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < dots ? AppColors.accent : Colors.white.withValues(alpha: 0.12),
              ),
            ),
        ],
      ),
    );
  }
}

/// Play and pause, and how far through the song it is.
class _Controls extends StatelessWidget {
  const _Controls();

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.read(context);
    final player = music.player;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Previous',
            icon: const Icon(Icons.skip_previous_rounded),
            onPressed: music.skipToPrevious,
          ),
          StreamBuilder<bool>(
            stream: player.playingStream,
            initialData: player.playing,
            builder: (context, snapshot) {
              final playing = snapshot.data ?? false;
              return IconButton.filled(
                tooltip: playing ? 'Pause' : 'Play',
                iconSize: 32,
                style: IconButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: AppColors.onAccent),
                icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                onPressed: playing ? player.pause : player.play,
              );
            },
          ),
          IconButton(
            tooltip: 'Next',
            icon: const Icon(Icons.skip_next_rounded),
            onPressed: player.hasNext ? player.seekToNext : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: StreamBuilder<Duration>(
              stream: player.positionStream,
              builder: (context, snapshot) {
                final total = player.duration?.inMilliseconds ?? 0;
                final at = snapshot.data?.inMilliseconds ?? 0;
                return ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: total == 0 ? 0 : (at / total).clamp(0.0, 1.0),
                    minHeight: 4,
                    color: AppColors.accent,
                    backgroundColor: Colors.white.withValues(alpha: 0.15),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
