import 'dart:math';

/// The equalizer on Windows, where mpv plays the music: a filter for each
/// band, with fixed bands (Android asks the phone what it has).
abstract final class DesktopEqualizer {
  /// Each band's center frequency in hertz, an octave apart.
  static const frequencies = [31.0, 62.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];

  static const minDecibels = -12.0;
  static const maxDecibels = 12.0;

  /// What to tell mpv for [gains] in decibels, by band; null when they're
  /// all flat, so the music then passes through untouched. Bands too high
  /// for a song of [sampleRate] are left out: it has no sound up there, and
  /// mpv would drop the equalizer for the whole song.
  static String? filter(List<double> gains, {int? sampleRate}) {
    final bands = [
      for (final (i, gain) in gains.indexed)
        if (i < frequencies.length && gain.abs() >= 0.05 && (sampleRate == null || frequencies[i] * 2 < sampleRate))
          'equalizer=f=${frequencies[i].round()}:t=o:w=1:g=${gain.toStringAsFixed(1)}',
    ];
    return bands.isEmpty ? null : bands.join(',');
  }

  /// How much to turn the volume down by for [gains], in decibels: as much
  /// as the highest boost, so the loudest moments don't distort.
  static double headroom(List<double> gains) => gains.fold(0, max);
}
