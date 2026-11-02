import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:blimp/services/desktop_library.dart';
import 'package:blimp/services/lossless_check.dart';
import 'package:blimp/services/media_library.dart';
import 'package:flutter_test/flutter_test.dart';

/// Nine pieces of sound with [tones] random tones, up to [topHz], each as
/// loud as [level] says at its frequency.
List<Float32List> sound(int rate, double topHz, {double Function(double hz)? level, int tones = 300}) {
  final rng = Random(1);
  final length = (rate * 0.75).floor();
  final pieces = <Float32List>[];
  final parts = [
    for (var i = 0; i < tones; i++)
      () {
        final hz = 200 + (topHz - 200) * i / tones;
        return (step: 2 * pi * hz / rate, phase: rng.nextDouble() * 2 * pi, gain: (level?.call(hz) ?? 1) * 0.3 / sqrt(tones));
      }(),
  ];
  for (var p = 0; p < 3; p++) {
    final piece = Float32List(length);
    for (final part in parts) {
      for (var n = 0; n < length; n++) {
        piece[n] += part.gain * sin(part.step * n + part.phase);
      }
    }
    pieces.add(piece);
  }
  return pieces;
}

void main() {
  test('sound up to the top of the range is genuine', () {
    expect(LosslessCheck.judge(sound(44100, 22000), 44100).verdict, LosslessVerdict.genuine);
  });

  test('sound that stops sharply where an MP3 would is likely lossy', () {
    final result = LosslessCheck.judge(sound(44100, 16000), 44100);
    expect(result.verdict, LosslessVerdict.likelyLossy);
    expect(result.cutoffHz, closeTo(16000, 500));
  });

  test('sound that stops just above 20 kHz is only possibly lossy', () {
    final result = LosslessCheck.judge(sound(44100, 20300), 44100);
    expect(result.verdict, LosslessVerdict.possiblyLossy);
  });

  test('treble that fades away gradually is genuine', () {
    double falling(double hz) => pow(10, -hz / 20000 * 3).toDouble();
    expect(LosslessCheck.judge(sound(44100, 22000, level: falling), 44100).verdict, LosslessVerdict.genuine);
  });

  test('hi-res sound with nothing above what a CD holds is upscaled', () {
    final result = LosslessCheck.judge(sound(96000, 22000, tones: 150), 96000);
    expect(result.verdict, LosslessVerdict.upscaled);
    expect(result.cutoffHz, closeTo(22000, 500));
  });

  test('silence can’t be judged', () {
    final silence = [for (var i = 0; i < 9; i++) Float32List(33000)];
    expect(LosslessCheck.judge(silence, 44100).verdict, LosslessVerdict.unknown);
  });

  test('no sound at all can’t be judged', () {
    expect(LosslessCheck.judge(const [], 44100).verdict, LosslessVerdict.unknown);
  });

  test('answers are remembered, but a song that couldn’t be judged is tried again', () {
    final results = LosslessResults.inMemory();
    final song = Song(id: 1, title: 't', uri: 'x', path: '/m/a.flac');
    results.put(song, const LosslessResult(LosslessVerdict.unknown));
    expect(results.of(song), isNull);
    results.put(song, const LosslessResult(LosslessVerdict.likelyLossy, 16000));
    expect(results.of(song)?.verdict, LosslessVerdict.likelyLossy);
    expect(results.of(song)?.cutoffHz, 16000);
  });

  group('telling ALAC from AAC in an M4A', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('blimp_alac'));
    tearDown(() => dir.deleteSync(recursive: true));

    List<int> box(String name, List<int> body) => [
      ...(ByteData(4)..setUint32(0, body.length + 8)).buffer.asUint8List(),
      ...ascii.encode(name),
      ...body,
    ];

    List<int> track(String format) => box(
      'trak',
      box('mdia', box('minf', box('stbl', box('stsd', [...List.filled(8, 0), ...box(format, List.filled(8, 0))])))),
    );

    bool isAlac(List<int> bytes) {
      final file = File('${dir.path}/song.m4a')..writeAsBytesSync(bytes);
      return DesktopLibrary.isAlac(file);
    }

    test('goes by what the track says it holds', () {
      expect(isAlac([...box('ftyp', ascii.encode('M4A ')), ...box('moov', track('alac'))]), isTrue);
      expect(isAlac([...box('ftyp', ascii.encode('M4A ')), ...box('moov', track('mp4a'))]), isFalse);
    });

    test('finds it after the audio, and past another track', () {
      expect(isAlac([...box('mdat', [1, 2, 3]), ...box('moov', [...track('jpeg'), ...track('alac')])]), isTrue);
    });

    test('a damaged or missing file isn’t ALAC', () {
      expect(isAlac([0, 0, 0, 99, ...ascii.encode('moov')]), isFalse);
      expect(DesktopLibrary.isAlac(File('${dir.path}/none.m4a')), isFalse);
    });
  });
}
