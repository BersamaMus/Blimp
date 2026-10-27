import 'listening_log.dart';
import 'media_library.dart';

enum StatsRange {
  day('Day'),
  week('Week'),
  month('Month'),
  allTime('All time');

  const StatsRange(this.label);
  final String label;
}

const _monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// A span of time to show stats for: a day, a week (Monday to Sunday), a
/// month or all time. [offset] steps back through earlier periods (-1 = the
/// one before the current one).
class StatsPeriod {
  StatsPeriod._(this.range, this.offset, this.start, this.end);

  factory StatsPeriod(StatsRange range, {required DateTime now, int offset = 0}) {
    final (y, m, d) = (now.year, now.month, now.day);
    // DateTime normalises overflowing days and months, which keeps this
    // correct across month ends and daylight-saving changes.
    return switch (range) {
      StatsRange.day => StatsPeriod._(range, offset, DateTime(y, m, d + offset), DateTime(y, m, d + offset + 1)),
      StatsRange.week => () {
          final monday = d - (now.weekday - DateTime.monday) + 7 * offset;
          return StatsPeriod._(range, offset, DateTime(y, m, monday), DateTime(y, m, monday + 7));
        }(),
      StatsRange.month => StatsPeriod._(range, offset, DateTime(y, m + offset), DateTime(y, m + offset + 1)),
      StatsRange.allTime => StatsPeriod._(range, 0, DateTime(1970), DateTime(9999)),
    };
  }

  final StatsRange range;
  final int offset;
  final DateTime start;

  /// Exclusive.
  final DateTime end;

  bool contains(DateTime time) => !time.isBefore(start) && time.isBefore(end);

  /// Earlier periods can always be browsed; later ones only up to now.
  bool get canGoForward => range != StatsRange.allTime && offset < 0;
  bool get canGoBack => range != StatsRange.allTime;

  StatsPeriod shifted(int by, DateTime now) => StatsPeriod(range, now: now, offset: offset + by);

  /// "Today", "Last week", "Mon, 6 Oct", "October 2026"...
  String get label {
    String day(DateTime t) => '${_weekdayNames[t.weekday - 1]}, ${t.day} ${_monthNames[t.month - 1]}';
    String short(DateTime t) => '${t.day} ${_monthNames[t.month - 1]}';
    return switch (range) {
      StatsRange.day => switch (offset) { 0 => 'Today', -1 => 'Yesterday', _ => day(start) },
      StatsRange.week => switch (offset) {
          0 => 'This week',
          -1 => 'Last week',
          _ => '${short(start)} – ${short(end.subtract(const Duration(days: 1)))}',
        },
      StatsRange.month => switch (offset) {
          0 => 'This month',
          -1 => 'Last month',
          _ => '${_monthNames[start.month - 1]} ${start.year}',
        },
      StatsRange.allTime => 'All time',
    };
  }
}

/// One column of the listening-time chart.
class StatsBucket {
  StatsBucket({required this.axisLabel, required this.title});

  /// Short label under the column; empty to keep the axis uncluttered.
  final String axisLabel;

  /// Full name shown when the column is tapped, e.g. "Tue, 7 Oct".
  final String title;
  int listenedMs = 0;
}

class SongStat {
  SongStat(this.song);
  final Song song;
  int plays = 0;
  int listenedMs = 0;
}

class NameStat {
  NameStat(this.name);
  final String name;
  int plays = 0;
  int listenedMs = 0;
}

class ListeningStats {
  ListeningStats({
    required this.period,
    required this.total,
    required this.plays,
    required this.songCount,
    required this.artistCount,
    required this.averagePerDay,
    required this.topSongs,
    required this.topArtists,
    required this.topGenres,
    required this.genreTotalMs,
    required this.buckets,
  });

  final StatsPeriod period;
  final Duration total;
  final int plays;
  /// Songs and artists played (listened to long enough to count), not just
  /// started; skips still add to [total] and the top lists.
  final int songCount;
  final int artistCount;

  /// Null for a single day, where it would just repeat [total].
  final Duration? averagePerDay;
  final List<SongStat> topSongs;
  final List<NameStat> topArtists;
  final List<NameStat> topGenres;

  /// Listening time on songs with a genre, the base for genre shares.
  final int genreTotalMs;
  final List<StatsBucket> buckets;

  bool get isEmpty => total == Duration.zero;
}

/// Adds up [events] that fall in [period]. Songs no longer in the library
/// still count toward totals but are left out of the top lists.
ListeningStats computeStats({
  required Iterable<ListenEvent> events,
  required Map<int, Song> songsById,
  required StatsPeriod period,
  required DateTime now,
  int topCount = 5,
  // How a song's artist credit splits into artists; the library's own rule
  // when it has one.
  List<String> Function(String credit) creditsOf = splitArtists,
}) {
  final inPeriod = events.where((e) => period.contains(e.endedAt)).toList();
  final buckets = _buckets(period, inPeriod, now);
  final bucketOf = _bucketIndex(period, inPeriod, now);

  var totalMs = 0, plays = 0, genreTotalMs = 0;
  final songs = <int, SongStat>{};
  final artists = <String, NameStat>{};
  final genres = <String, NameStat>{};

  for (final e in inPeriod) {
    totalMs += e.listenedMs;
    if (e.countsAsPlay) plays++;
    final index = bucketOf(e.endedAt);
    if (index >= 0 && index < buckets.length) buckets[index].listenedMs += e.listenedMs;

    final song = songsById[e.songId];
    if (song == null) continue;
    final play = e.countsAsPlay ? 1 : 0;
    songs.putIfAbsent(song.id, () => SongStat(song))
      ..plays += play
      ..listenedMs += e.listenedMs;
    // Each credited artist gets the full listen, so features add up.
    for (final name in creditsOf(song.artistName)) {
      artists.putIfAbsent(name, () => NameStat(name))
        ..plays += play
        ..listenedMs += e.listenedMs;
    }
    if (song.genre case final genre?) {
      genreTotalMs += e.listenedMs;
      genres.putIfAbsent(genre, () => NameStat(genre))
        ..plays += play
        ..listenedMs += e.listenedMs;
    }
  }

  int byPlaysThenTime(({int plays, int ms}) a, ({int plays, int ms}) b) {
    final c = b.plays.compareTo(a.plays);
    return c != 0 ? c : b.ms.compareTo(a.ms);
  }

  final topSongs = songs.values.toList()
    ..sort((a, b) => byPlaysThenTime((plays: a.plays, ms: a.listenedMs), (plays: b.plays, ms: b.listenedMs)));
  final topArtists = artists.values.toList()..sort((a, b) => b.listenedMs.compareTo(a.listenedMs));
  final topGenres = genres.values.toList()..sort((a, b) => b.listenedMs.compareTo(a.listenedMs));

  return ListeningStats(
    period: period,
    total: Duration(milliseconds: totalMs),
    plays: plays,
    songCount: songs.values.where((s) => s.plays > 0).length,
    artistCount: artists.values.where((a) => a.plays > 0).length,
    averagePerDay: _averagePerDay(period, inPeriod, totalMs, now),
    topSongs: topSongs.take(topCount).toList(),
    topArtists: topArtists.take(topCount).toList(),
    topGenres: topGenres.take(topCount).toList(),
    genreTotalMs: genreTotalMs,
    buckets: buckets,
  );
}

Duration? _averagePerDay(StatsPeriod period, List<ListenEvent> events, int totalMs, DateTime now) {
  if (period.range == StatsRange.day) return null;
  // Only days that have started count, so a week isn't diluted by its future.
  final from = period.range == StatsRange.allTime
      ? (events.isEmpty ? now : _day(events.first.endedAt))
      : period.start;
  final until = period.end.isAfter(now) ? _day(now).add(const Duration(days: 1)) : period.end;
  final days = until.difference(from).inHours / 24;
  if (days < 1) return Duration(milliseconds: totalMs);
  return Duration(milliseconds: (totalMs / days.round()).round());
}

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

List<StatsBucket> _buckets(StatsPeriod period, List<ListenEvent> events, DateTime now) {
  switch (period.range) {
    case StatsRange.day:
      String hour(int h) => '${h % 12 == 0 ? 12 : h % 12} ${h < 12 ? 'AM' : 'PM'}';
      return [
        for (var h = 0; h < 24; h++)
          StatsBucket(axisLabel: h % 6 == 0 ? hour(h).replaceAll(' ', '').toLowerCase() : '', title: hour(h)),
      ];
    case StatsRange.week:
      return [
        for (var i = 0; i < 7; i++)
          () {
            final day = DateTime(period.start.year, period.start.month, period.start.day + i);
            return StatsBucket(
              axisLabel: _weekdayNames[i].substring(0, 1),
              title: '${_weekdayNames[i]}, ${day.day} ${_monthNames[day.month - 1]}',
            );
          }(),
      ];
    case StatsRange.month:
      final days = DateTime(period.start.year, period.start.month + 1, 0).day;
      return [
        for (var d = 1; d <= days; d++)
          StatsBucket(
            axisLabel: d == 1 || d % 7 == 1 ? '$d' : '',
            title: '${_weekdayNames[DateTime(period.start.year, period.start.month, d).weekday - 1]}, $d '
                '${_monthNames[period.start.month - 1]}',
          ),
      ];
    case StatsRange.allTime:
      final months = _allTimeMonths(events, now);
      return [
        for (final (i, month) in months.indexed)
          StatsBucket(
            // A few months: label each. Many: the first and each January, with the year.
            axisLabel: months.length <= 6
                ? _monthNames[month.month - 1]
                : i == 0 || month.month == 1
                    ? "${_monthNames[month.month - 1]} '${month.year % 100}"
                    : '',
            title: '${_monthNames[month.month - 1]} ${month.year}',
          ),
      ];
  }
}

/// Months from the first listen (at most the last 12) up to now.
List<DateTime> _allTimeMonths(List<ListenEvent> events, DateTime now) {
  final last = DateTime(now.year, now.month);
  var first = events.isEmpty ? last : DateTime(events.first.endedAt.year, events.first.endedAt.month);
  final earliest = DateTime(now.year, now.month - 11);
  if (first.isBefore(earliest)) first = earliest;
  return [
    for (var m = first; !m.isAfter(last); m = DateTime(m.year, m.month + 1)) m,
  ];
}

int Function(DateTime) _bucketIndex(StatsPeriod period, List<ListenEvent> events, DateTime now) {
  switch (period.range) {
    case StatsRange.day:
      return (t) => t.hour;
    case StatsRange.week:
      // Rounded, since a day can be 23 or 25 hours when clocks change.
      return (t) => (_day(t).difference(period.start).inHours / 24).round();
    case StatsRange.month:
      return (t) => t.day - 1;
    case StatsRange.allTime:
      final first = _allTimeMonths(events, now).first;
      return (t) => (t.year - first.year) * 12 + t.month - first.month;
  }
}

/// "2 h 15 min", "45 min", "30 s".
String formatListeningTime(Duration d) {
  if (d.inMinutes == 0) return d.inSeconds == 0 ? '0 min' : '${d.inSeconds} s';
  final hours = d.inHours, minutes = d.inMinutes.remainder(60);
  if (hours == 0) return '$minutes min';
  return minutes == 0 ? '$hours h' : '$hours h $minutes min';
}

/// The artists credited in a tag like "Kendrick Lamar/SZA" or "Drake feat.
/// Rihanna". Names that only look split, such as "AC/DC", stay whole; so do
/// commas and "&", which belong to names like "Tyler, The Creator" and
/// "Earth, Wind & Fire" as often as they join two artists.
List<String> splitArtists(String artist) {
  final parts = artist
      .split(_artistSeparator)
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.length < 2 || parts.any((p) => p.length <= 2)) return [artist.trim()];
  // The same artist credited twice counts once.
  return parts.toSet().toList();
}

final _artistSeparator = RegExp(r'\s*[/;]\s*|\s+(?:feat\.?|ft\.|featuring)\s+', caseSensitive: false);

/// How many songs a year's chart holds.
const yearChartLength = 50;

/// Each year's most played songs with their plays that year, most first (ties
/// by time listened), for its Top songs playlist. The years come newest first,
/// and only ones with a song still in the library played in them. Done in one
/// go through the history, as it can be years long.
Map<int, List<SongStat>> topSongsByYear(Iterable<ListenEvent> events, Map<int, Song> songsById) {
  final years = <int, Map<int, SongStat>>{};
  for (final e in events) {
    final song = songsById[e.songId];
    if (song == null) continue;
    years.putIfAbsent(e.endedAt.year, () => {}).putIfAbsent(song.id, () => SongStat(song))
      ..plays += e.countsAsPlay ? 1 : 0
      ..listenedMs += e.listenedMs;
  }
  final charts = <int, List<SongStat>>{};
  for (final year in years.keys.toList()..sort((a, b) => b.compareTo(a))) {
    final ranked = years[year]!.values.where((s) => s.plays > 0).toList()
      ..sort((a, b) {
        final c = b.plays.compareTo(a.plays);
        return c != 0 ? c : b.listenedMs.compareTo(a.listenedMs);
      });
    if (ranked.isNotEmpty) charts[year] = ranked.take(yearChartLength).toList();
  }
  return charts;
}
