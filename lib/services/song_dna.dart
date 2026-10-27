import 'listening_log.dart';
import 'media_library.dart';

/// Everything the listening history says about one song.
class SongDna {
  const SongDna({
    required this.listens,
    required this.plays,
    required this.listened,
    required this.firstPlayed,
    required this.lastPlayed,
    required this.rank,
    required this.peakHour,
    required this.playsByMonth,
  });

  /// Times it was started and listened to for a second or more.
  final int listens;

  /// Listens that lasted long enough to count as played.
  final int plays;
  final Duration listened;
  final DateTime? firstPlayed;
  final DateTime? lastPlayed;

  /// Its place among every song by plays, 1 being the most played; null if
  /// it hasn't been played.
  final int? rank;

  /// The hour of the day it's played most; null if never played.
  final int? peakHour;

  /// Plays in each of the last 12 months, oldest first, this month last.
  final List<int> playsByMonth;

  /// Listens cut short before counting as played, as a share of all of
  /// them; null with nothing to go on.
  double? get skipRate => listens == 0 ? null : (listens - plays) / listens;
}

/// [song]'s history from every listen in [events].
SongDna songDna(Song song, Iterable<ListenEvent> events, DateTime now) {
  var listens = 0, plays = 0, listenedMs = 0;
  DateTime? first, last;
  final hours = List.filled(24, 0);
  final months = List.filled(12, 0);
  final playsBySong = <int, int>{};

  for (final e in events) {
    if (e.countsAsPlay) playsBySong[e.songId] = (playsBySong[e.songId] ?? 0) + 1;
    if (e.songId != song.id) continue;
    listenedMs += e.listenedMs;
    // A long listen saved in pieces is still one listen.
    if (!e.continued) listens++;
    if (!e.countsAsPlay) continue;
    plays++;
    first ??= e.endedAt;
    last = e.endedAt;
    hours[e.endedAt.hour]++;
    final monthsAgo = (now.year - e.endedAt.year) * 12 + now.month - e.endedAt.month;
    if (monthsAgo >= 0 && monthsAgo < 12) months[11 - monthsAgo]++;
  }

  var peak = -1;
  for (var h = 0; h < 24; h++) {
    if (hours[h] > 0 && (peak < 0 || hours[h] > hours[peak])) peak = h;
  }
  return SongDna(
    // A listen saved in pieces whose first piece was cleared away still
    // counts once.
    listens: listens < plays ? plays : listens,
    plays: plays,
    listened: Duration(milliseconds: listenedMs),
    firstPlayed: first,
    lastPlayed: last,
    rank: plays == 0 ? null : 1 + playsBySong.values.where((p) => p > plays).length,
    peakHour: peak < 0 ? null : peak,
    playsByMonth: months,
  );
}

/// "Late at night", "In the morning"..., for a song's [SongDna.peakHour].
String partOfDay(int hour) => switch (hour) {
      >= 5 && < 12 => 'In the morning',
      >= 12 && < 18 => 'In the afternoon',
      >= 18 && < 23 => 'In the evening',
      _ => 'Late at night',
    };
