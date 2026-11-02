import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'media_library.dart';

/// What the sound of a lossless file says about where it came from.
enum LosslessVerdict {
  /// Nothing suspicious.
  genuine,

  /// Cut off where a very high bitrate MP3 or AAC would be, which some real
  /// masters are too.
  possiblyLossy,

  /// Cut off where an MP3 or AAC would be.
  likelyLossy,

  /// A hi-res file with nothing above what a CD can hold.
  upscaled,

  /// Too quiet, or it couldn't be read.
  unknown,
}

class LosslessResult {
  const LosslessResult(this.verdict, [this.cutoffHz]);

  final LosslessVerdict verdict;

  /// Where the sound stops, if it stops sharply.
  final int? cutoffHz;
}

/// Finds lossless files made from lossy ones. Lossy encoders throw away the
/// highest sounds above a fixed point, so the music stops at a cliff that
/// converting back to FLAC can't undo. Real recordings fade away gradually
/// instead. A cliff is a strong sign rather than proof, so the check never
/// claims more than that.
abstract final class LosslessCheck {
  /// Where in a song to listen, as fractions of its length: several places,
  /// as a song can be quiet or simple for a while.
  static const _places = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9];

  static const _pieceSeconds = 0.75;

  /// Frequencies are grouped into bands this wide, in hertz.
  static const _bandHz = 250;

  /// The lowest cut-off looked for. Lossy files don't go lower, and music
  /// with little treble has nothing higher to see anyway.
  static const _lowestCutHz = 10000;

  /// How far the music must drop across the cut-off, in decibels. Only the
  /// silence above it is compared, so the drop is a real cliff.
  static const _cliffDb = 20.0;

  /// How far below the loudest band sound still counts as music. Lower down
  /// is only a file's background noise, whose shape means nothing.
  static const _audibleDb = 80.0;

  /// Bands either side of a cut-off that aren't compared, as even a sharp
  /// filter takes a moment to fall.
  static const _gapBands = 2;

  /// Bands below a cut-off that show how loud the music is there.
  static const _levelBands = 5;

  /// Below this a very high bitrate lossy file is the likely reason.
  static const _likelyBelowHz = 19500;

  /// Up to this could be a high bitrate lossy file or a careful master.
  static const _possibleBelowHz = 20600;

  /// What a hi-res file made from CD audio stops at, at the very most: the
  /// conversion rolls off over a few kilohertz above the 22 kHz a CD holds.
  static const _upscaledBelowHz = 28000;

  /// Quieter frames than this have nothing to say about the treble.
  static const _quietFrame = 0.001;

  static const _fewestFrames = 20;

  /// Whether [song]'s file holds lossless audio.
  static Future<bool> isLossless(Song song) async {
    final extension = (song.fileName ?? song.uri).split('.').last.toLowerCase();
    if (const {'flac', 'wav', 'aif', 'aiff', 'alac'}.contains(extension)) return true;
    if (extension != 'm4a') return false;
    // M4A can be either.
    return (await MediaLibrary.getAudioFormat(song))?.mime == 'audio/alac';
  }

  /// Listens to [song]; [LosslessVerdict.unknown] if it can't be decoded.
  static Future<LosslessResult> check(Song song) async {
    final seconds = (song.duration?.inMilliseconds ?? 0) / 1000;
    if (seconds < _pieceSeconds * 2) return const LosslessResult(LosslessVerdict.unknown);
    final audio = await MediaLibrary.readAudio(song, [for (final place in _places) place * seconds], _pieceSeconds);
    if (audio == null) return const LosslessResult(LosslessVerdict.unknown);
    return Isolate.run(() => judge(audio.pieces, audio.rate));
  }

  /// Judges the sound of [pieces], taken at [rate] samples a second.
  static LosslessResult judge(List<Float32List> pieces, int rate) {
    final bands = _spectrum(pieces, rate);
    if (bands == null) return const LosslessResult(LosslessVerdict.unknown);
    final cutoff = _findCliff(bands);
    if (cutoff == null) return const LosslessResult(LosslessVerdict.genuine);
    if (cutoff < _likelyBelowHz) return LosslessResult(LosslessVerdict.likelyLossy, cutoff);
    if (cutoff < _possibleBelowHz) return LosslessResult(LosslessVerdict.possiblyLossy, cutoff);
    // Past 48 kHz a song has room for more than a CD holds.
    if (rate > 48000 && cutoff < _upscaledBelowHz) return LosslessResult(LosslessVerdict.upscaled, cutoff);
    return const LosslessResult(LosslessVerdict.genuine);
  }

  /// How loud each band of frequencies is on average, in decibels; null if
  /// the song's too quiet to tell.
  static List<double>? _spectrum(List<Float32List> pieces, int rate) {
    // About a tenth of a second, whatever the sample rate.
    var size = 4096;
    while (size * 12 < rate) {
      size *= 2;
    }
    final window = [for (var i = 0; i < size; i++) 0.5 - 0.5 * cos(2 * pi * i / size)];
    final power = Float64List(size ~/ 2);
    final (re, im) = (Float64List(size), Float64List(size));
    var frames = 0;
    for (final piece in pieces) {
      for (var at = 0; at + size <= piece.length; at += size ~/ 2) {
        var sum = 0.0;
        for (var i = 0; i < size; i++) {
          final sample = piece[at + i];
          sum += sample * sample;
          re[i] = sample * window[i];
          im[i] = 0;
        }
        if (sqrt(sum / size) < _quietFrame) continue;
        _fft(re, im);
        for (var i = 0; i < power.length; i++) {
          power[i] += re[i] * re[i] + im[i] * im[i];
        }
        frames++;
      }
    }
    if (frames < _fewestFrames) return null;

    final hzPerBin = rate / size;
    final count = (rate / 2 / _bandHz).floor();
    final (sums, counts) = (Float64List(count), Int32List(count));
    for (var i = 0; i < power.length; i++) {
      final band = (i * hzPerBin) ~/ _bandHz;
      if (band < count) {
        sums[band] += power[i];
        counts[band]++;
      }
    }
    return [
      for (var band = 0; band < count; band++)
        // The tiny amount keeps silence a number.
        10 * log(sums[band] / max(1, counts[band]) / frames / size / size + 1e-16) / ln10,
    ];
  }

  /// Where [bands] fall off the sharpest cliff with silence all the way
  /// above it, in hertz; null if they don't.
  static int? _findCliff(List<double> bands) {
    int? cutoff;
    var deepest = _cliffDb;
    final audible = bands.reduce(max) - _audibleDb;
    for (var band = _lowestCutHz ~/ _bandHz; band + _gapBands < bands.length; band++) {
      final below = bands.sublist(band - _levelBands, band)..sort();
      // The middle one, so one lone whine doesn't look like the music.
      final level = below[_levelBands ~/ 2];
      final above = bands.sublist(band + _gapBands).reduce(max);
      if (level >= audible && level - above >= deepest) {
        deepest = level - above;
        cutoff = band * _bandHz;
      }
    }
    return cutoff;
  }

  /// A Fourier transform, in place: [re] and [im] are a power of two long.
  static void _fft(Float64List re, Float64List im) {
    final n = re.length;
    for (var i = 1, j = 0; i < n; i++) {
      var bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        final (r, m) = (re[i], im[i]);
        re[i] = re[j];
        im[i] = im[j];
        re[j] = r;
        im[j] = m;
      }
    }
    for (var length = 2; length <= n; length <<= 1) {
      final angle = -2 * pi / length;
      final half = length >> 1;
      for (var k = 0; k < half; k++) {
        final (wr, wi) = (cos(angle * k), sin(angle * k));
        for (var i = k; i < n; i += length) {
          final j = i + half;
          final tr = re[j] * wr - im[j] * wi;
          final ti = re[j] * wi + im[j] * wr;
          re[j] = re[i] - tr;
          im[j] = im[i] - ti;
          re[i] += tr;
          im[i] += ti;
        }
      }
    }
  }
}

/// Answers already worked out, so checking again only listens to new files.
/// Kept apart from backups, as they can be worked out again from the songs.
class LosslessResults {
  LosslessResults._(this._file, this._saved);

  /// For tests: results that only live in memory.
  LosslessResults.inMemory() : _file = null, _saved = {};

  final File? _file;
  final Map<String, Object?> _saved;

  static Future<LosslessResults> open() async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/lossless_checks.json');
    var saved = <String, Object?>{};
    try {
      saved = (jsonDecode(await file.readAsString()) as Map).cast<String, Object?>();
    } on Object {
      // None yet, or unreadable: the songs are just listened to again.
    }
    return LosslessResults._(file, saved);
  }

  /// Changes when the file does, so an edited song is checked again.
  static String _keyOf(Song song) =>
      '${song.path ?? song.id}|${song.size}|${song.dateAdded?.millisecondsSinceEpoch}';

  LosslessResult? of(Song song) {
    if (_saved[_keyOf(song)] case [final int verdict, final int? cutoff]
        when verdict < LosslessVerdict.values.length && verdict != LosslessVerdict.unknown.index) {
      return LosslessResult(LosslessVerdict.values[verdict], cutoff);
    }
    return null;
  }

  /// Saves [result], unless it's unknown: that could be a drive that was
  /// unplugged for a moment, so the song is listened to again next time.
  void put(Song song, LosslessResult result) {
    if (result.verdict == LosslessVerdict.unknown) return;
    _saved[_keyOf(song)] = [result.verdict.index, result.cutoffHz];
  }

  Future<void> save() async => _file?.writeAsString(jsonEncode(_saved));
}
