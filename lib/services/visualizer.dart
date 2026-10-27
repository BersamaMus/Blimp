import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// How the Visualizer tab draws the music.
enum VisualizerStyle {
  bars('Bars', Icons.bar_chart_rounded),
  mirror('Mirror', Icons.align_vertical_center_rounded),
  wave('Wave', Icons.waves_rounded),
  radial('Radial', Icons.blur_circular_rounded),
  pulse('Pulse', Icons.radio_button_checked_rounded),
  particles('Particles', Icons.bubble_chart_rounded),
  starfield('Starfield', Icons.auto_awesome_rounded);

  const VisualizerStyle(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// The visualizer's two colours (low to high frequencies) for a broad genre.
(Color, Color) visualizerColors(String? genre) => switch (genre) {
      'Metal' => (const Color(0xFFEF4444), const Color(0xFFF97316)),
      'Rock' => (const Color(0xFFF97316), const Color(0xFFFACC15)),
      'Dance & Electronic' => (const Color(0xFF22D3EE), const Color(0xFFD946EF)),
      'Hip-Hop' => (const Color(0xFF8B5CF6), const Color(0xFFFBBF24)),
      'Pop' => (const Color(0xFFEC4899), const Color(0xFF8B5CF6)),
      'K-Pop' => (const Color(0xFFF472B6), const Color(0xFF22D3EE)),
      'R&B & Soul' => (const Color(0xFFA855F7), const Color(0xFFFB7185)),
      'Jazz' || 'Blues' => (const Color(0xFFF59E0B), const Color(0xFF14B8A6)),
      'Classical' || 'Soundtracks & Musicals' => (const Color(0xFFFCD34D), const Color(0xFFFEF3C7)),
      'Video Game Music' => (const Color(0xFF4ADE80), const Color(0xFF60A5FA)),
      'Chill' || 'Folk & Acoustic' => (const Color(0xFF2DD4BF), const Color(0xFF818CF8)),
      _ => (AppColors.accent, const Color(0xFF6366F1)),
    };

/// The visualizer's two colours picked from a cover's pixels ([rgba], four
/// bytes each): its most striking colour, then the most striking one of a
/// clearly different hue (or a neighbour of the first, for a cover in one
/// colour). Both are brightened to stand out on black. Null for a cover with
/// no colour to speak of (black and white, say).
(Color, Color)? artworkColors(Uint8List rgba) {
  const bins = 12;
  final weight = Float64List(bins);
  final red = Float64List(bins), green = Float64List(bins), blue = Float64List(bins);
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    final hsv = HSVColor.fromColor(Color.fromARGB(255, rgba[i], rgba[i + 1], rgba[i + 2]));
    // Greys and near-black say nothing about the cover's colour.
    if (hsv.saturation < 0.25 || hsv.value < 0.2) continue;
    final w = hsv.saturation * hsv.value;
    final bin = (hsv.hue / 360 * bins).floor() % bins;
    weight[bin] += w;
    red[bin] += rgba[i] * w;
    green[bin] += rgba[i + 1] * w;
    blue[bin] += rgba[i + 2] * w;
  }

  var first = 0;
  for (var b = 1; b < bins; b++) {
    if (weight[b] > weight[first]) first = b;
  }
  final total = weight.fold(0.0, (a, b) => a + b);
  // A few stray coloured pixels don't make a colourful cover.
  if (total < rgba.length / 4 * 0.04) return null;

  int distance(int a, int b) => min((a - b).abs(), bins - (a - b).abs());
  int? second;
  for (var b = 0; b < bins; b++) {
    if (distance(b, first) < 2 || weight[b] < total * 0.08) continue;
    if (second == null || weight[b] > weight[second]) second = b;
  }

  Color vivid(Color color) {
    final hsv = HSVColor.fromColor(color);
    return hsv.withSaturation(max(hsv.saturation, 0.55)).withValue(max(hsv.value, 0.9)).toColor();
  }

  Color binColor(int b) =>
      Color.fromARGB(255, (red[b] / weight[b]).round(), (green[b] / weight[b]).round(), (blue[b] / weight[b]).round());

  final low = vivid(binColor(first));
  if (second != null) return (low, vivid(binColor(second)));
  // One colour: the other end is the same hue moved round a little, lighter.
  final hsv = HSVColor.fromColor(low);
  return (low, hsv.withHue((hsv.hue + 40) % 360).withSaturation(hsv.saturation * 0.7).toColor());
}

/// One capture of what the player is outputting.
class AudioFrame {
  const AudioFrame(this.bands, this.fineBands, this.wave, this.volume, {this.wholePc = false});

  /// Frequency levels from low to high, each 0..1.
  final Float64List bands;

  /// The same in more, narrower bands, for the bar styles.
  final Float64List fineBands;

  /// The waveform, each point -1..1.
  final Float64List wave;

  /// The music volume step; at 0 nothing is heard, so nothing moves.
  final int volume;

  /// Windows: this version can't share just Blimp's audio, so this is
  /// everything the PC plays, other apps' sound included.
  final bool wholePc;
}

const _channel = EventChannel('blimp/visualizer');

/// Captures of the audio playing in [audioSessionId], about 20 a second.
/// Errors if Android won't allow it (for example, without the microphone
/// permission it requires). On Windows the session is ignored: it's Blimp's
/// own audio (windows/runner/visualizer.cpp), and [volume] gives the
/// in-app volume, as a step 0..100, in place of Android's.
///
/// Heights follow how loud the music is compared with its loud parts, so a
/// buildup sits visibly below the drop that follows.
Stream<AudioFrame> audioFrames(int audioSessionId, {int Function()? volume}) =>
    _channel.receiveBroadcastStream(audioSessionId).map((event) {
      final step = event['volume'] as int? ?? volume?.call() ?? 1;
      final gain = _loudness.gain((event['rms'] as num).toDouble(), step);
      final bands = event['bands'] as Float64List;
      final fineBands = event['fineBands'] as Float64List;
      final wave = event['wave'] as Float64List;
      for (final values in [bands, fineBands, wave]) {
        for (var i = 0; i < values.length; i++) {
          values[i] *= gain;
        }
      }
      return AudioFrame(bands, fineBands, wave, step, wholePc: event['wholePc'] == true);
    });

/// Kept while the app runs, so reopening the tab mid-buildup doesn't take
/// the buildup for the loudest part.
final _loudness = _Loudness();

/// Turns the music's loudness into a 0..1 height scale, against a reference:
/// the loudest it has been lately. The reference jumps up at once on anything
/// louder and sinks back very slowly, so it holds through a whole buildup.
class _Loudness {
  /// How far below the reference the scale reaches its floor. It curves, so
  /// the drop towers over a buildup 7 dB quieter (about 57% height) while
  /// quiet parts keep moving.
  static const _rangeDb = 24.0;

  /// Music within this much of the reference shows at full height.
  static const _headroomDb = 2.0;

  /// The least any music is scaled to, so a slow, quiet buildup still moves
  /// instead of flattening out.
  static const _floor = 0.2;

  /// Android reports silence as -96 dB; anything this quiet shows nothing.
  static const _silenceDb = -90.0;

  /// How fast the reference sinks after a loud passage, so a quieter song
  /// still fills the view after a while.
  static const _decayDbPerSecond = 0.1;

  /// With nothing to go on yet, assume the music is this far below its loud
  /// parts, so a quiet intro isn't taken for the loudest the song gets.
  static const _startBelowDb = 4.0;

  /// How long the loudness reading takes to catch up with a volume change.
  static const _volumeSettle = Duration(milliseconds: 800);

  final _clock = Stopwatch()..start();
  double? _referenceDb;
  double? _lastRmsDb;
  double _lastGain = 1;
  int? _volume;
  double? _rmsBeforeVolumeChange;
  final _sinceVolumeChange = Stopwatch();

  double gain(double rmsDb, int volume) {
    final dt = _clock.elapsedMicroseconds / 1e6;
    _clock.reset();

    // Loudness is measured after the volume is applied. When the volume
    // changes, hold still until the reading settles, then move the reference
    // by as much as the reading moved, so the music doesn't look quieter or
    // louder than it was.
    if (_volume != null && volume != _volume && _lastRmsDb != null) {
      _rmsBeforeVolumeChange ??= _lastRmsDb;
      _sinceVolumeChange
        ..reset()
        ..start();
    }
    _volume = volume;
    if (_rmsBeforeVolumeChange case final before?) {
      if (_sinceVolumeChange.elapsed < _volumeSettle) return _lastGain;
      _referenceDb = _referenceDb! + rmsDb - before;
      _rmsBeforeVolumeChange = null;
      _sinceVolumeChange.stop();
    }

    if (rmsDb <= _silenceDb) return _lastGain = 0;

    _lastRmsDb = rmsDb;
    final reference = _referenceDb;
    _referenceDb = reference == null ? rmsDb + _startBelowDb : max(rmsDb, reference - _decayDbPerSecond * dt);

    final below = _referenceDb! - _headroomDb - rmsDb;
    final closeness = (1 - below / (_rangeDb - _headroomDb)).clamp(0.0, 1.0);
    return _lastGain = _floor + (1 - _floor) * closeness * closeness;
  }
}
