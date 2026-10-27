import 'package:flutter/material.dart';

import 'listening_log.dart';
import 'media_library.dart';
import 'music_controller.dart';

/// Days in a row with at least one play.
class Streak {
  const Streak({required this.current, required this.longest, required this.playedToday});

  /// The run going now. A run that reached yesterday still counts until the
  /// end of today, so it isn't lost before the first song of the morning.
  final int current;
  final int longest;
  final bool playedToday;
}

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

/// The days on which something was played (listened to long enough to
/// count), oldest first.
List<DateTime> playDays(Iterable<ListenEvent> events) =>
    {for (final e in events) if (e.countsAsPlay) _day(e.endedAt)}.toList()..sort();

/// The longest run of days in a row in [days] (sorted, no repeats).
int longestRun(List<DateTime> days) {
  var longest = 0, run = 0;
  DateTime? last;
  for (final day in days) {
    // Rounded, since a day can be 23 or 25 hours when clocks change.
    run = last != null && (day.difference(last).inHours / 24).round() == 1 ? run + 1 : 1;
    if (run > longest) longest = run;
    last = day;
  }
  return longest;
}

Streak listeningStreak(Iterable<ListenEvent> events, DateTime now) {
  final days = playDays(events);
  final today = _day(now);
  final playedToday = days.isNotEmpty && days.last == today;
  var current = 0;
  // Counted back from today, or from yesterday if nothing's played yet today.
  var expected = playedToday ? today : DateTime(now.year, now.month, now.day - 1);
  for (final day in days.reversed) {
    if (day != expected) break;
    current++;
    expected = DateTime(day.year, day.month, day.day - 1);
  }
  return Streak(current: current, longest: longestRun(days), playedToday: playedToday);
}

/// Something to aim for in the listening history, and how close it is.
class ListeningBadge {
  const ListeningBadge({
    required this.title,
    required this.description,
    required this.icon,
    required this.progress,
    required this.goal,
    this.unit = '',
  });

  final String title;

  /// How to earn it, in a few words.
  final String description;
  final IconData icon;
  final int progress;
  final int goal;

  /// Shown after the numbers, as in "4 / 10 h".
  final String unit;

  bool get earned => progress >= goal;
  double get fraction => goal == 0 ? 1 : (progress / goal).clamp(0.0, 1.0);

  String get progressText => earned ? 'Earned' : '${_count(progress)} / ${_count(goal)}$unit';

  static String _count(int n) =>
      n < 1000 ? '$n' : n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');
}

/// Every badge, earned ones first, from all the listening in [events].
/// [albums] are the library's, for finishing a whole album.
List<ListeningBadge> computeBadges({
  required Iterable<ListenEvent> events,
  required Map<int, Song> songsById,
  required List<Album> albums,
  required int librarySize,
  List<String> Function(String credit) creditsOf = _whole,
}) {
  var plays = 0, totalMs = 0, nightPlays = 0, morningPlays = 0;
  final playedSongs = <int>{};
  final genres = <String>{};
  final decades = <int>{};
  final msByArtist = <String, int>{};
  final msByDay = <DateTime, int>{};
  final playsBySongDay = <(int, DateTime), int>{};

  for (final e in events) {
    totalMs += e.listenedMs;
    final day = _day(e.endedAt);
    msByDay[day] = (msByDay[day] ?? 0) + e.listenedMs;
    final song = songsById[e.songId];
    if (song != null) {
      for (final name in creditsOf(song.artistName)) {
        if (name != Song.unknownArtist) msByArtist[name] = (msByArtist[name] ?? 0) + e.listenedMs;
      }
    }
    if (!e.countsAsPlay) continue;
    plays++;
    final hour = e.endedAt.hour;
    if (hour < 4) nightPlays++;
    if (hour >= 5 && hour < 8) morningPlays++;
    playsBySongDay[(e.songId, day)] = (playsBySongDay[(e.songId, day)] ?? 0) + 1;
    if (song == null) continue;
    playedSongs.add(song.id);
    if (song.genre case final genre?) genres.add(genre);
    if (song.year case final year? when year >= 1900) decades.add(year ~/ 10);
  }

  const hourMs = 3600 * 1000;
  int most(Iterable<int> values) => values.fold(0, (a, b) => a > b ? a : b);
  final finishedAlbums = albums
      .where((a) => a.songs.length >= 5 && a.songs.every((s) => playedSongs.contains(s.id)))
      .length;
  final longestStreak = longestRun(playDays(events));

  final badges = [
    ListeningBadge(title: 'Getting started', description: 'Play 10 songs', icon: Icons.play_circle_outline_rounded,
        progress: plays, goal: 10),
    ListeningBadge(title: 'Regular', description: 'Play 500 songs', icon: Icons.repeat_rounded, progress: plays, goal: 500),
    ListeningBadge(title: 'Devoted', description: 'Play 5,000 songs', icon: Icons.workspace_premium_rounded,
        progress: plays, goal: 5000),
    ListeningBadge(title: 'Ten hours', description: 'Listen for 10 hours in all', icon: Icons.schedule_rounded,
        progress: totalMs ~/ hourMs, goal: 10, unit: ' h'),
    ListeningBadge(title: 'Hundred hours', description: 'Listen for 100 hours in all', icon: Icons.hourglass_bottom_rounded,
        progress: totalMs ~/ hourMs, goal: 100, unit: ' h'),
    ListeningBadge(title: 'Marathon', description: 'Listen for 5 hours in one day', icon: Icons.directions_run_rounded,
        progress: most(msByDay.values) ~/ hourMs, goal: 5, unit: ' h'),
    ListeningBadge(title: 'Week streak', description: 'Play something 7 days in a row', icon: Icons.local_fire_department_rounded,
        progress: longestStreak, goal: 7, unit: ' days'),
    ListeningBadge(title: 'Month streak', description: 'Play something 30 days in a row', icon: Icons.whatshot_rounded,
        progress: longestStreak, goal: 30, unit: ' days'),
    ListeningBadge(title: 'Explorer', description: 'Play 100 different songs', icon: Icons.explore_rounded,
        progress: playedSongs.length, goal: 100),
    ListeningBadge(title: 'Deep diver', description: 'Play half of your library', icon: Icons.scuba_diving_rounded,
        progress: playedSongs.length, goal: librarySize == 0 ? 1 : (librarySize + 1) ~/ 2),
    ListeningBadge(title: 'Front to back', description: 'Play every song on an album', icon: Icons.album_rounded,
        progress: finishedAlbums, goal: 1),
    ListeningBadge(title: 'On repeat', description: 'Play one song 10 times in a day', icon: Icons.repeat_one_rounded,
        progress: most(playsBySongDay.values), goal: 10),
    ListeningBadge(title: 'Superfan', description: 'Listen to one artist for 10 hours', icon: Icons.favorite_rounded,
        progress: most(msByArtist.values) ~/ hourMs, goal: 10, unit: ' h'),
    ListeningBadge(title: 'Genre hopper', description: 'Play songs from 10 genres', icon: Icons.category_rounded,
        progress: genres.length, goal: 10),
    ListeningBadge(title: 'Time traveller', description: 'Play songs from 5 decades', icon: Icons.history_toggle_off_rounded,
        progress: decades.length, goal: 5),
    ListeningBadge(title: 'Night owl', description: 'Play 25 songs between midnight and 4 am', icon: Icons.bedtime_rounded,
        progress: nightPlays, goal: 25),
    ListeningBadge(title: 'Early bird', description: 'Play 25 songs between 5 and 8 am', icon: Icons.wb_twilight_rounded,
        progress: morningPlays, goal: 25),
  ];
  // Earned first, then the closest to being earned; otherwise as listed.
  final order = {for (final (i, b) in badges.indexed) b: i};
  return badges
    ..sort((a, b) {
      if (a.earned != b.earned) return a.earned ? -1 : 1;
      if (!a.earned) {
        final closer = b.fraction.compareTo(a.fraction);
        if (closer != 0) return closer;
      }
      return order[a]!.compareTo(order[b]!);
    });
}

List<String> _whole(String credit) => [credit];
