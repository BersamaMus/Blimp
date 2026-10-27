import 'media_library.dart';

/// The library's songs from one decade, by their year tags, for Decade radio.
class Decade {
  Decade(this.start, this.songs);

  /// The decade's first year, e.g. 1980.
  final int start;
  final List<Song> songs;

  /// "1980s".
  String get label => '${start}s';

  /// "80s", or "2000s" and "1900s", where two digits would be unclear.
  String get shortLabel => start % 100 == 0 ? label : "'${(start % 100).toString().padLeft(2, '0')}s";

  /// The genres most of its songs are in, most first.
  late final List<String> topGenres = () {
    final counts = <String, int>{};
    for (final song in songs) {
      if (song.genre case final genre?) counts[genre] = (counts[genre] ?? 0) + 1;
    }
    return (counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!))).take(3).toList();
  }();
}

/// Fewer songs than this don't make much of a radio.
const _minSongs = 5;

/// The decades [songs] come from, oldest first, each with enough songs to
/// play for a while. Podcasts and audiobooks are left out, and so are years
/// that can't be right (before recorded music, or in the future).
List<Decade> decadesOf(Iterable<Song> songs, {required DateTime now}) {
  final byDecade = <int, List<Song>>{};
  for (final song in songs) {
    final year = song.year;
    if (year == null || year < 1900 || year > now.year + 1 || song.spoken) continue;
    byDecade.putIfAbsent(year ~/ 10 * 10, () => []).add(song);
  }
  return [
    for (final start in byDecade.keys.toList()..sort())
      if (byDecade[start]!.length >= _minSongs) Decade(start, byDecade[start]!),
  ];
}
