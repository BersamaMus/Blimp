import 'dart:math';
import 'dart:typed_data';

import 'package:blimp/services/song_edges.dart';
import 'package:flutter_test/flutter_test.dart';

const rate = 5512;

/// [seconds] of sound, with its loudness at each moment (0..1 of [seconds])
/// from [level].
Float32List sound(double seconds, [double Function(double at)? level]) {
  final samples = Float32List((rate * seconds).floor());
  for (var i = 0; i < samples.length; i++) {
    samples[i] = 0.5 * (level?.call(i / samples.length) ?? 1) * sin(i * 0.3);
  }
  return samples;
}

Float32List joined(List<Float32List> parts) => Float32List.fromList([for (final part in parts) ...part]);

void main() {
  test('music right up to both ends has no silence and no fade of its own', () {
    final edges = SongEdges.measure(head: sound(12), tail: sound(12), rate: rate);
    expect(edges.quietStart, Duration.zero);
    expect(edges.quietEnd, Duration.zero);
    expect(edges.fadesOut, isFalse);
  });

  test('silence at each end is found, keeping a little of it', () {
    final edges = SongEdges.measure(
      head: joined([Float32List(rate * 3), sound(9)]),
      tail: joined([sound(8), Float32List(rate * 4)]),
      rate: rate,
    );
    expect(edges.quietStart.inMilliseconds, closeTo(2900, 60));
    expect(edges.quietEnd.inMilliseconds, closeTo(3900, 60));
  });

  test('a very short gap is part of the song', () {
    final edges = SongEdges.measure(
      head: joined([Float32List(rate ~/ 4), sound(11)]),
      tail: joined([sound(11), Float32List(rate ~/ 4)]),
      rate: rate,
    );
    expect(edges.quietStart, Duration.zero);
    expect(edges.quietEnd, Duration.zero);
  });

  test('a song that fades away by itself is noticed', () {
    final tail = joined([sound(6), sound(6, (at) => 1 - at)]);
    expect(SongEdges.measure(head: sound(12), tail: tail, rate: rate).fadesOut, isTrue);
  });

  test('a hidden track at the very end keeps its place', () {
    final tail = joined([Float32List(rate * 9), sound(3)]);
    final edges = SongEdges.measure(head: sound(12), tail: tail, rate: rate);
    expect(edges.quietEnd, Duration.zero);
  });

  test('a song of only silence is left alone at the start', () {
    final edges = SongEdges.measure(head: Float32List(rate * 12), tail: Float32List(rate * 12), rate: rate);
    expect(edges.quietStart, Duration.zero);
    expect(edges.fadesOut, isFalse);
  });
}
