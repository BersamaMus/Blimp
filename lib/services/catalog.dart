import 'dart:math';

import 'listening_stats.dart';
import 'media_library.dart';
import 'music_controller.dart';

/// Splits artist credits the way the library uses them. Slashes, semicolons
/// and "feat." always separate artists (see [splitArtists]). Commas and "&"
/// do only when one of the names is an artist on its own somewhere in the
/// library, as in "Kendrick Lamar, Kodak Black"; "Tyler, The Creator" and
/// "Earth, Wind & Fire" stay whole.
class ArtistCredits {
  ArtistCredits(Iterable<Song> songs)
    : _known = {
        for (final s in songs) ...[
          ...splitArtists(s.artistName),
          if (s.albumArtist case final a?) ...splitArtists(a),
        ],
      };

  /// Every name credited on its own (or with "/", ";" or "feat.") anywhere.
  final Set<String> _known;

  static final _list = RegExp(r'\s*,\s*|\s+&\s+');

  List<String> split(String credit) => {
    for (final part in splitArtists(credit)) ..._splitList(part),
  }.toList();

  List<String> _splitList(String part) {
    final names = part.split(_list).map((n) => n.trim()).where((n) => n.isNotEmpty).toList();
    if (names.length < 2 || !names.any(_known.contains)) return [part];
    return names;
  }
}

/// The albums [songs] make up, by title. Songs with no album are left out.
/// [releaseTypes] are those read from files so far, by song id.
List<Album> buildAlbums(List<Song> songs, {Map<int, String> releaseTypes = const {}, ArtistCredits? credits}) {
  credits ??= ArtistCredits(songs);
  final byAlbum = <Object, List<Song>>{};
  for (final s in songs) {
    if (s.album == null) continue;
    byAlbum.putIfAbsent(s.albumId ?? s.album!, () => []).add(s);
  }
  return [for (final group in byAlbum.values) _album(group, releaseTypes, credits)]
    ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
}

final _variousArtists = RegExp(r'^(various( artists)?|va)$', caseSensitive: false);

/// An album from its songs, in disc and track order. It's credited to its
/// tagged album artist; failing that, to the artist most of its songs are by
/// (the first credited, so guests on a few songs don't count).
Album _album(List<Song> songs, Map<int, String> releaseTypes, ArtistCredits credits) {
  final albumArtists = [
    for (final s in songs)
      if (s.albumArtist?.trim() case final a? when a.isNotEmpty) a,
  ];
  final albumArtist = albumArtists.isEmpty ? null : _mostCommon(albumArtists);
  final variousArtists = albumArtist != null && _variousArtists.hasMatch(albumArtist);
  final compilation = variousArtists || songs.any((s) => s.compilation);
  return Album(
    title: songs.first.album!,
    artist: compilation && (albumArtist == null || variousArtists)
        ? 'Various artists'
        : albumArtist ?? _mostCommon(songs.map((s) => credits.split(s.artistName).first)),
    isCompilation: compilation,
    year: songs.map((s) => s.year).whereType<int>().fold<int?>(null, (a, b) => max(a ?? b, b)),
    releaseType: songs.map((s) => releaseTypes[s.id]).nonNulls.firstOrNull,
    songs: songs
      ..sort((a, b) {
        final byDisc = (a.disc ?? 1).compareTo(b.disc ?? 1);
        if (byDisc != 0) return byDisc;
        final byTrack = (a.track ?? 0).compareTo(b.track ?? 0);
        return byTrack != 0 ? byTrack : a.title.compareTo(b.title);
      }),
  );
}

/// The artists of [songs], by name, with Unknown artist last.
///
/// Everyone credited on a song gets it ("A/B", "A feat. B"), and the artists
/// an album is credited to get all of its songs and the album itself, unless
/// it's a compilation. A song with no artist is under "Unknown artist", so it
/// can still be found.
List<Artist> buildArtists(List<Song> songs, List<Album> albums, {ArtistCredits? credits}) {
  credits ??= ArtistCredits(songs);
  final byArtist = <String, Set<Song>>{};
  for (final s in songs) {
    for (final name in credits.split(s.artistName)) {
      byArtist.putIfAbsent(name, () => {}).add(s);
    }
  }
  final albumsByArtist = <String, List<Album>>{};
  for (final album in albums) {
    if (album.isCompilation) continue;
    for (final name in credits.split(album.artist)) {
      albumsByArtist.putIfAbsent(name, () => []).add(album);
      byArtist.putIfAbsent(name, () => {}).addAll(album.songs);
    }
  }
  return [
    for (final MapEntry(key: name, value: artistSongs) in byArtist.entries)
      Artist(
        name: name,
        songs: artistSongs.toList()..sort((a, b) => a.searchFields.first.compareTo(b.searchFields.first)),
        albums: (albumsByArtist[name] ?? [])..sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0)),
      ),
  ]..sort((a, b) {
    if ((a.name == Song.unknownArtist) != (b.name == Song.unknownArtist)) {
      return a.name == Song.unknownArtist ? 1 : -1;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
}

String _mostCommon(Iterable<String> values) {
  final counts = <String, int>{};
  for (final v in values) {
    counts[v] = (counts[v] ?? 0) + 1;
  }
  return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
}
