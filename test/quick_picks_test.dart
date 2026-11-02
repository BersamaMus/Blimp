import 'dart:math';

import 'package:blimp/services/listening_log.dart';
import 'package:blimp/services/media_library.dart';
import 'package:blimp/services/quick_picks.dart';
import 'package:flutter_test/flutter_test.dart';

Song song(int id) => Song(id: id, title: 'Song $id', uri: 'u$id');

/// [plays] plays of the song with [id], at [hour] on different days.
List<ListenEvent> played(int id, int hour, int plays) => [
  for (var day = 1; day <= plays; day++)
    ListenEvent(songId: id, endedAt: DateTime(2026, 1, day, hour), listenedMs: 60000)..countsAsPlay = true,
];

void main() {
  final library = [for (var id = 0; id < 100; id++) song(id)];
  final evening = DateTime(2026, 6, 1, 20);

  test('with no history, picks are just random songs, each once', () {
    final picks = quickPicksFor(songs: library, listens: const [], now: evening, count: 20, random: Random(1));
    expect(picks, hasLength(20));
    expect(picks.toSet(), hasLength(20));
  });

  test('songs usually played at this time are picked', () {
    final listens = [for (var id = 0; id < 5; id++) ...played(id, 20, 6)];
    final picks = quickPicksFor(songs: library, listens: listens, now: evening, count: 20, random: Random(1));
    expect(picks.map((s) => s.id), containsAll([0, 1, 2, 3, 4]));
  });

  test('songs played at the other end of the day are not favoured', () {
    final listens = [for (var id = 0; id < 12; id++) ...played(id, 7, 6)];
    final picks = quickPicksFor(songs: library, listens: listens, now: evening, count: 20, random: Random(1));
    expect(picks.where((s) => s.id < 12).length, lessThan(6));
  });

  test('a few picks always stay random', () {
    final listens = [for (var id = 0; id < 50; id++) ...played(id, 20, 3)];
    final picks = quickPicksFor(songs: library, listens: listens, now: evening, count: 20, random: Random(1));
    expect(picks, hasLength(20));
    expect(picks.where((s) => s.id >= 50), isNotEmpty);
  });

  test('a song played at this hour and no other beats one played at all hours', () {
    final listens = [
      ...played(0, 20, 4),
      for (var hour = 0; hour < 24; hour++) ...played(1, hour, 2),
    ];
    var first = 0, second = 0;
    for (var seed = 0; seed < 200; seed++) {
      final picks = quickPicksFor(songs: library, listens: listens, now: evening, count: 2, random: Random(seed));
      if (picks.any((s) => s.id == 0)) first++;
      if (picks.any((s) => s.id == 1)) second++;
    }
    expect(first, greaterThan(second));
  });

  test('a habit just after midnight counts for just before it', () {
    final listens = played(0, 0, 6);
    var picked = 0;
    for (var seed = 0; seed < 50; seed++) {
      final picks = quickPicksFor(songs: library, listens: listens, now: DateTime(2026, 6, 1, 23), count: 20, random: Random(seed));
      if (picks.any((s) => s.id == 0)) picked++;
    }
    expect(picked, 50);
  });

  test('plays that never reached a real listen don’t count', () {
    final listens = [
      for (final listen in played(0, 20, 6))
        ListenEvent(songId: 0, endedAt: listen.endedAt, listenedMs: 5000),
    ];
    final hits = [
      for (var seed = 0; seed < 100; seed++)
        quickPicksFor(songs: library, listens: listens, now: evening, count: 20, random: Random(seed)).any((s) => s.id == 0),
    ].where((hit) => hit).length;
    expect(hits, lessThan(50));
  });

  test('dayMoment splits the day', () {
    expect(dayMoment(DateTime(2026, 1, 1, 6)), 'this morning');
    expect(dayMoment(DateTime(2026, 1, 1, 13)), 'this afternoon');
    expect(dayMoment(DateTime(2026, 1, 1, 19)), 'this evening');
    expect(dayMoment(DateTime(2026, 1, 1, 23)), 'tonight');
    expect(dayMoment(DateTime(2026, 1, 1, 2)), 'tonight');
  });
}
