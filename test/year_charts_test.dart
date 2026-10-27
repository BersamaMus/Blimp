import 'package:blimp/services/listening_log.dart';
import 'package:blimp/services/listening_stats.dart';
import 'package:blimp/services/media_library.dart';
import 'package:blimp/services/time_machine.dart';
import 'package:flutter_test/flutter_test.dart';

Song _song(int id) => Song(id: id, title: 'Song $id', uri: 'content://$id', artist: 'A');

List<ListenEvent> _plays(List<(int, DateTime)> plays, {int seconds = 200}) {
  final log = ListeningLog.inMemory();
  for (final (id, at) in plays) {
    log.append(ListenEvent(songId: id, endedAt: at, listenedMs: seconds * 1000));
  }
  return log.events;
}

void main() {
  final songs = {for (var i = 1; i <= 3; i++) i: _song(i)};

  group('Top songs of the year', () {
    final events = _plays([
      (1, DateTime(2025, 6, 1)),
      (1, DateTime(2025, 6, 2)),
      (3, DateTime(2026, 3, 1)),
      (2, DateTime(2026, 3, 2)),
      (2, DateTime(2026, 3, 3)),
      (4, DateTime(2026, 3, 4)), // no longer in the library
    ]);

    test('ranks only that year, by plays', () {
      final charts = topSongsByYear(events, songs);
      expect(charts[2026]!.map((s) => (s.song.id, s.plays)), [(2, 2), (3, 1)]);
      expect(charts[2025]!.map((s) => s.song.id), [1]);
    });

    test('lists the years played in, newest first', () {
      expect(topSongsByYear(events, songs).keys, [2026, 2025]);
    });

    test("skips don't put a song in the chart", () {
      final skips = _plays([(1, DateTime(2026, 1, 1))], seconds: 10);
      expect(topSongsByYear(skips, songs), isEmpty);
    });

    test('a year with only removed songs has no chart', () {
      expect(topSongsByYear(_plays([(4, DateTime(2024, 1, 1))]), songs), isEmpty);
    });
  });

  group('Time machine', () {
    final now = DateTime(2026, 10, 28);

    test('goes back to the same week, the furthest first', () {
      final events = _plays([
        for (final id in [1, 2, 3]) (id, DateTime(2025, 10, 27, 12, id)),
        for (final id in [1, 2, 3, 3]) (id, DateTime(2026, 9, 29, 12, id)),
      ]);
      final trips = findTimeTrips(events: events, songsById: songs, now: now);
      expect(trips.map((t) => t.label), ['A year ago this week', 'A month ago this week']);
      // Most played first.
      expect(trips.last.songs.first.id, 3);
    });

    test('a week with too few songs is no trip', () {
      final events = _plays([(1, DateTime(2025, 10, 28, 12))]);
      expect(findTimeTrips(events: events, songsById: songs, now: now), isEmpty);
    });
  });
}
