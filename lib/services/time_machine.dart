import 'listening_log.dart';
import 'media_library.dart';

/// The songs played around this time of year in the past: a week, centred
/// on the same date some time ago.
class TimeTrip {
  const TimeTrip({required this.label, required this.start, required this.songs});

  /// "A year ago this week", "3 months ago".
  final String label;
  final DateTime start;

  /// Most played first.
  final List<Song> songs;
}

/// How far back the time machine looks, furthest first after the years.
const _monthsBack = [(6, '6 months ago this week'), (3, '3 months ago this week'), (1, 'A month ago this week')];

/// Fewer songs than this make a poor trip.
const _minSongs = 3;
const _maxSongs = 20;

/// Every week in the past worth going back to, the furthest first: the same
/// week each year back to the first listen, then 6, 3 and 1 months ago.
List<TimeTrip> findTimeTrips({
  required Iterable<ListenEvent> events,
  required Map<int, Song> songsById,
  required DateTime now,
}) {
  final first = events.firstOrNull?.endedAt;
  if (first == null) return const [];
  final windows = <(DateTime, String)>[
    for (var years = now.year - first.year; years >= 1; years--)
      (DateTime(now.year - years, now.month, now.day), years == 1 ? 'A year ago this week' : '$years years ago this week'),
    for (final (months, label) in _monthsBack) (DateTime(now.year, now.month - months, now.day), label),
  ];

  final trips = <TimeTrip>[];
  for (final (centre, label) in windows) {
    final start = DateTime(centre.year, centre.month, centre.day - 3);
    final end = DateTime(centre.year, centre.month, centre.day + 4);
    final plays = <int, int>{};
    for (final e in events) {
      if (!e.countsAsPlay || e.endedAt.isBefore(start)) continue;
      if (!e.endedAt.isBefore(end)) break;
      plays[e.songId] = (plays[e.songId] ?? 0) + 1;
    }
    final songs = [for (final id in plays.keys) ?songsById[id]]
      ..sort((a, b) => plays[b.id]!.compareTo(plays[a.id]!));
    if (songs.length >= _minSongs) trips.add(TimeTrip(label: label, start: start, songs: songs.take(_maxSongs).toList()));
  }
  return trips;
}
