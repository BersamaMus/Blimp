import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'media_library.dart';

/// What the start and end of a song really sound like, so fading between
/// songs can go by the music and not just the clock.
class SongEdges {
  const SongEdges({this.quietStart = Duration.zero, this.quietEnd = Duration.zero, this.fadesOut = false});

  /// How much silence the song opens with.
  final Duration quietStart;

  /// How much silence it ends with.
  final Duration quietEnd;

  /// Whether the song already dies away by itself, so needs no fading.
  final bool fadesOut;

  /// Quieter than this is silence: about -50 dB of full volume.
  static const _silence = 0.00316;

  /// Each stretch judged is this long.
  static const _windowMs = 50;

  /// Less silence than this is left alone: it's part of the song's timing.
  static const _shortestGap = 500;

  /// A little of the silence is kept, so a first note isn't clipped.
  static const _margin = 100;

  /// An ending this long or longer, under half the song's loud level, counts
  /// as the song fading out by itself.
  static const _shortestFadeMs = 2000;

  /// How much of each end is looked at. Silence longer than this at the very
  /// end still counts; a hidden track after a long gap keeps its place, as
  /// it's what the end then sounds like.
  static const _readSeconds = 12.0;

  /// Songs too short to have an end of their own to look at are left alone.
  static const _shortestSong = Duration(seconds: 30);

  /// Looks at [song]'s two ends; null if it's short or can't be decoded.
  static Future<SongEdges?> of(Song song) async {
    final duration = song.duration;
    if (duration == null || duration < _shortestSong) return null;
    // Loudness doesn't need every sample.
    const every = 8;
    final start = await MediaLibrary.readAudio(song, const [0], _readSeconds, every: every);
    // Decoders land some way before where they're sent, so this reads on for
    // longer than is left: it has to reach the song's true end.
    final end = await MediaLibrary.readAudio(
      song,
      [duration.inMilliseconds / 1000 - _readSeconds],
      _readSeconds * 3,
      every: every,
    );
    if (start == null || end == null) return null;
    final (head, tail, rate) = (start.pieces.single, end.pieces.single, end.rate);
    return Isolate.run(() => measure(head: head, tail: tail, rate: rate));
  }

  /// Works out the edges from the first and last of a song's samples.
  /// [tail] runs up to the song's last sample.
  static SongEdges measure({required Float32List head, required Float32List tail, required int rate}) {
    final start = _levels(head, rate);
    final end = _levels(tail, rate);

    final firstSound = start.indexWhere((level) => level >= _silence);
    final lastSound = end.lastIndexWhere((level) => level >= _silence);
    final quietStartMs = (firstSound < 0 ? 0 : firstSound) * _windowMs - _margin;
    final quietEndMs = (end.length - 1 - lastSound) * _windowMs - _margin;

    return SongEdges(
      quietStart: Duration(milliseconds: quietStartMs >= _shortestGap ? quietStartMs : 0),
      quietEnd: Duration(milliseconds: quietEndMs >= _shortestGap ? quietEndMs : 0),
      fadesOut: lastSound >= 0 && _diesAway(end.sublist(0, lastSound + 1)),
    );
  }

  /// How loud each window of [samples] is, as the root mean square.
  static List<double> _levels(Float32List samples, int rate) {
    final size = max(1, rate * _windowMs ~/ 1000);
    return [
      for (var at = 0; at + size <= samples.length; at += size)
        () {
          var sum = 0.0;
          for (var i = at; i < at + size; i++) {
            sum += samples[i] * samples[i];
          }
          return sqrt(sum / size);
        }(),
    ];
  }

  /// Whether [levels], which end on the last sound, spend their last
  /// moments well below their loud parts.
  static bool _diesAway(List<double> levels) {
    final sounds = levels.where((level) => level >= _silence).toList()..sort();
    if (sounds.isEmpty) return false;
    final loud = sounds[sounds.length * 9 ~/ 10];
    final lastLoud = levels.lastIndexWhere((level) => level >= loud / 2);
    return (levels.length - 1 - lastLoud) * _windowMs >= _shortestFadeMs;
  }
}
