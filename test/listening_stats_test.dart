import 'package:blimp/services/listening_log.dart';
import 'package:blimp/services/listening_stats.dart';
import 'package:blimp/services/media_library.dart';
import 'package:flutter_test/flutter_test.dart';

Song _song(int id, {String artist = 'A', String? genre}) =>
    Song(id: id, title: 'Song $id', uri: 'content://$id', artist: artist, genre: genre);

ListenEvent _listen(int songId, DateTime at, {int seconds = 60, bool continued = false}) =>
    ListenEvent(songId: songId, endedAt: at, listenedMs: seconds * 1000, continued: continued);

void main() {
  // A Wednesday.
  final now = DateTime(2026, 10, 7, 15, 30);

  group('periods', () {
    test('weeks run Monday to Sunday', () {
      final week = StatsPeriod(StatsRange.week, now: now);
      expect(week.start, DateTime(2026, 10, 5));
      expect(week.end, DateTime(2026, 10, 12));
      expect(StatsPeriod(StatsRange.week, now: now, offset: -1).start, DateTime(2026, 9, 28));
    });

    test('months and days step back across year ends', () {
      expect(StatsPeriod(StatsRange.month, now: now, offset: -10).start, DateTime(2025, 12));
      expect(StatsPeriod(StatsRange.day, now: DateTime(2026, 1, 1), offset: -1).start, DateTime(2025, 12, 31));
    });

    test('labels name recent periods in words', () {
      expect(StatsPeriod(StatsRange.day, now: now).label, 'Today');
      expect(StatsPeriod(StatsRange.week, now: now, offset: -1).label, 'Last week');
      expect(StatsPeriod(StatsRange.day, now: now, offset: -2).label, 'Mon, 5 Oct');
      expect(StatsPeriod(StatsRange.month, now: now, offset: -2).label, 'Aug 2026');
    });
  });

  group('plays', () {
    test('a song counts as played once it reaches 30 seconds, even across pieces', () {
      final log = ListeningLog.inMemory()
        ..append(_listen(1, now, seconds: 20))
        ..append(_listen(1, now, seconds: 20, continued: true)) // 40 s: a play
        ..append(_listen(1, now, seconds: 60, continued: true)) // still the same play
        ..append(_listen(2, now, seconds: 10)); // too short
      expect(log.events.map((e) => e.countsAsPlay), [false, true, false, false]);
    });
  });

  group('computeStats', () {
    final songs = {
      1: _song(1, artist: 'Kendrick Lamar', genre: 'Hip-Hop'),
      2: _song(2, artist: 'Prince', genre: 'Pop'),
      3: _song(3, artist: 'Prince', genre: 'Pop'),
    };

    test('adds up the period and ranks songs, artists and genres', () {
      final log = ListeningLog.inMemory()
        ..append(_listen(1, DateTime(2026, 10, 6, 9), seconds: 240))
        ..append(_listen(1, DateTime(2026, 10, 7, 10), seconds: 240))
        ..append(_listen(2, DateTime(2026, 10, 7, 11), seconds: 180))
        ..append(_listen(3, DateTime(2026, 10, 7, 12), seconds: 400))
        ..append(_listen(2, DateTime(2026, 9, 1), seconds: 999)); // outside this week

      final stats = computeStats(
        events: log.events,
        songsById: songs,
        period: StatsPeriod(StatsRange.week, now: now),
        now: now,
      );
      expect(stats.total, const Duration(seconds: 1060));
      expect(stats.plays, 4);
      expect(stats.songCount, 3);
      expect(stats.artistCount, 2);
      expect(stats.topSongs.first.song.id, 1, reason: 'most plays wins');
      expect(stats.topArtists.first.name, 'Prince', reason: 'most listening time wins');
      expect(stats.topGenres.map((g) => g.name), ['Pop', 'Hip-Hop']);
      expect(stats.genreTotalMs, 1060 * 1000);

      // 6 Oct is Tuesday and 7 Oct (today) is Wednesday.
      expect(stats.buckets.map((b) => b.listenedMs ~/ 1000), [0, 240, 820, 0, 0, 0, 0]);
      // Three days of the week have started (Mon-Wed).
      expect(stats.averagePerDay, Duration(milliseconds: (1060 * 1000 / 3).round()));
    });

    test('a day is split into 24 hourly columns', () {
      final log = ListeningLog.inMemory()..append(_listen(1, DateTime(2026, 10, 7, 14, 59)));
      final stats = computeStats(
        events: log.events,
        songsById: songs,
        period: StatsPeriod(StatsRange.day, now: now),
        now: now,
      );
      expect(stats.buckets, hasLength(24));
      expect(stats.buckets[14].listenedMs, 60000);
      expect(stats.buckets[14].title, '2 PM');
      expect(stats.averagePerDay, isNull);
    });

    test('skipped songs add listening time but not to the songs and artists played', () {
      final log = ListeningLog.inMemory()
        ..append(_listen(1, now, seconds: 240))
        ..append(_listen(2, now, seconds: 5)) // skipped
        ..append(_listen(3, now, seconds: 5)); // skipped
      final stats = computeStats(
        events: log.events,
        songsById: songs,
        period: StatsPeriod(StatsRange.day, now: now),
        now: now,
      );
      expect(stats.plays, 1);
      expect(stats.songCount, 1);
      expect(stats.artistCount, 1);
      expect(stats.total, const Duration(seconds: 250));
    });

    test('songs removed from the library count toward totals only', () {
      final log = ListeningLog.inMemory()..append(_listen(99, now));
      final stats = computeStats(
        events: log.events,
        songsById: songs,
        period: StatsPeriod(StatsRange.allTime, now: now),
        now: now,
      );
      expect(stats.total, const Duration(minutes: 1));
      expect(stats.topSongs, isEmpty);
    });
  });

  test('credits every artist on a song, without breaking names like AC/DC', () {
    expect(splitArtists('Kendrick Lamar/Zacari'), ['Kendrick Lamar', 'Zacari']);
    expect(splitArtists('Drake; Future'), ['Drake', 'Future']);
    expect(splitArtists('AC/DC'), ['AC/DC']);
    expect(splitArtists('Prince'), ['Prince']);

    final songs = {1: _song(1, artist: 'Kendrick Lamar'), 2: _song(2, artist: 'Kendrick Lamar/Zacari')};
    final log = ListeningLog.inMemory()
      ..append(_listen(1, now, seconds: 60))
      ..append(_listen(2, now, seconds: 60));
    final stats = computeStats(
      events: log.events,
      songsById: songs,
      period: StatsPeriod(StatsRange.day, now: now),
      now: now,
    );
    expect(stats.topArtists.first.name, 'Kendrick Lamar');
    expect(stats.topArtists.first.listenedMs, 120000);
    expect(stats.artistCount, 2);
  });

  test('formats listening time compactly', () {
    expect(formatListeningTime(const Duration(minutes: 135)), '2 h 15 min');
    expect(formatListeningTime(const Duration(minutes: 45)), '45 min');
    expect(formatListeningTime(const Duration(hours: 3)), '3 h');
    expect(formatListeningTime(const Duration(seconds: 20)), '20 s');
  });

  test('compacting merges each listen into one entry, keeping plays and time', () {
    final pieces = [
      _listen(1, DateTime(2026, 10, 7, 9), seconds: 20),
      _listen(1, DateTime(2026, 10, 7, 9, 0, 30), seconds: 30, continued: true),
      _listen(2, DateTime(2026, 10, 7, 9, 1), seconds: 10),
      _listen(2, DateTime(2026, 10, 7, 9, 2), seconds: 50),
    ];
    final compacted = ListeningLog.compact(pieces);
    expect([for (final e in compacted) (e.songId, e.listenedMs, e.endedAt)], [
      (1, 50000, DateTime(2026, 10, 7, 9, 0, 30)),
      (2, 10000, DateTime(2026, 10, 7, 9, 1)),
      (2, 50000, DateTime(2026, 10, 7, 9, 2)),
    ]);

    int plays(List<ListenEvent> events) {
      final log = ListeningLog.inMemory();
      for (final e in events) {
        log.append(ListenEvent(songId: e.songId, endedAt: e.endedAt, listenedMs: e.listenedMs, continued: e.continued));
      }
      return log.events.where((e) => e.countsAsPlay).length;
    }

    expect(plays(compacted), plays(pieces));
  });
}
