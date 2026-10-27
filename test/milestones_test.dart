import 'package:blimp/services/listening_log.dart';
import 'package:blimp/services/media_library.dart';
import 'package:blimp/services/milestones.dart';
import 'package:flutter_test/flutter_test.dart';

Song _song(int id, {String artist = 'A', String? genre, int? year}) =>
    Song(id: id, title: 'Song $id', uri: 'content://$id', artist: artist, genre: genre, year: year);

/// A log with a full play of each song at each time.
List<ListenEvent> _plays(List<(int, DateTime)> plays, {int seconds = 60}) {
  final log = ListeningLog.inMemory();
  for (final (id, at) in plays) {
    log.append(ListenEvent(songId: id, endedAt: at, listenedMs: seconds * 1000));
  }
  return log.events;
}

void main() {
  group('streaks', () {
    final now = DateTime(2026, 10, 28, 9);

    test('counts days in a row up to today', () {
      final events = _plays([
        (1, DateTime(2026, 10, 20, 12)),
        (1, DateTime(2026, 10, 26, 12)),
        (1, DateTime(2026, 10, 27, 23)),
        (1, DateTime(2026, 10, 28, 8)),
      ]);
      final streak = listeningStreak(events, now);
      expect(streak.current, 3);
      expect(streak.longest, 3);
      expect(streak.playedToday, isTrue);
    });

    test("isn't lost until today ends", () {
      final events = _plays([(1, DateTime(2026, 10, 26, 12)), (1, DateTime(2026, 10, 27, 12))]);
      expect(listeningStreak(events, now).current, 2);
      expect(listeningStreak(events, DateTime(2026, 10, 29, 9)).current, 0);
    });

    test('skips (under 30 seconds) keep no streak going', () {
      final events = _plays([(1, DateTime(2026, 10, 27, 12)), (1, DateTime(2026, 10, 28, 8))], seconds: 10);
      expect(listeningStreak(events, now).current, 0);
    });

    test('runs carry across month ends', () {
      final events = _plays([(1, DateTime(2026, 9, 30, 12)), (1, DateTime(2026, 10, 1, 12))]);
      expect(listeningStreak(events, now).longest, 2);
    });
  });

  group('badges', () {
    ListeningBadge badge(List<ListeningBadge> badges, String title) => badges.firstWhere((b) => b.title == title);

    test('progress comes from the history and earned badges come first', () {
      final songs = {for (var i = 1; i <= 12; i++) i: _song(i, genre: 'G${i % 3}', year: 1960 + i * 5)};
      final events = _plays([for (var i = 1; i <= 12; i++) (i, DateTime(2026, 10, 1, 12, i))]);
      final badges = computeBadges(events: events, songsById: songs, albums: const [], librarySize: 12);
      expect(badge(badges, 'Getting started').earned, isTrue);
      expect(badge(badges, 'Regular').progressText, '12 / 500');
      expect(badge(badges, 'Genre hopper').progress, 3);
      expect(badge(badges, 'Time traveller').earned, isTrue);
      expect(badges.first.earned, isTrue);
      expect(badges.last.earned, isFalse);
    });

    test('one song ten times in a day is On repeat', () {
      final events = _plays([for (var i = 0; i < 10; i++) (1, DateTime(2026, 10, 1, 8 + i))]);
      final badges = computeBadges(events: events, songsById: {1: _song(1)}, albums: const [], librarySize: 1);
      expect(badge(badges, 'On repeat').earned, isTrue);
      expect(badge(badges, 'Deep diver').earned, isTrue);
    });

    test('large numbers are grouped', () {
      final badges = computeBadges(events: const [], songsById: const {}, albums: const [], librarySize: 0);
      expect(badge(badges, 'Devoted').progressText, '0 / 5,000');
    });
  });
}
