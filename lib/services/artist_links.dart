import 'dart:collection';

import 'catalog.dart';
import 'media_library.dart';
import 'music_controller.dart';

/// One step from an artist to [artist], and the song that links them.
class ArtistLink {
  const ArtistLink(this.artist, this.via, {required this.together});

  final String artist;
  final Song via;

  /// True when both are credited on [via] ("A feat. B"); false when they're
  /// only on the same compilation.
  final bool together;
}

final _variousArtists = RegExp(r'^(various( artists)?|va)$', caseSensitive: false);

/// Who in the library has worked with whom, for Six degrees: artists
/// credited on the same song are linked, and, more loosely, artists on the
/// same compilation.
class ArtistGraph {
  ArtistGraph(List<Song> songs, List<Album> albums, {ArtistCredits? credits}) {
    credits ??= ArtistCredits(songs);
    bool real(String name) => name != Song.unknownArtist && !_variousArtists.hasMatch(name);
    for (final song in songs) {
      final names = {
        ...credits.split(song.artistName),
        if (song.albumArtist case final a?) ...credits.split(a),
      }.where(real).toList();
      for (final a in names) {
        for (final b in names) {
          if (a != b) _together.putIfAbsent(a, () => {}).putIfAbsent(b, () => song);
        }
      }
    }
    for (final album in albums) {
      if (!album.isCompilation) continue;
      // The first song of each artist on it.
      final firstSong = <String, Song>{};
      for (final song in album.songs) {
        for (final name in credits.split(song.artistName).where(real)) {
          firstSong.putIfAbsent(name, () => song);
        }
      }
      for (final a in firstSong.keys) {
        for (final MapEntry(key: b, value: song) in firstSong.entries) {
          if (a != b) _compiled.putIfAbsent(a, () => {}).putIfAbsent(b, () => song);
        }
      }
    }
  }

  /// Links by a shared song, and by a shared compilation, each artist to
  /// the others with the song that links them.
  final _together = <String, Map<String, Song>>{};
  final _compiled = <String, Map<String, Song>>{};

  /// The artists [artist] is linked to directly: those they share a song
  /// with first, then those on the same compilations, by name in each.
  List<ArtistLink> neighbours(String artist) {
    final together = _together[artist] ?? const {};
    int byName(ArtistLink a, ArtistLink b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
    return [
      ...[for (final MapEntry(:key, :value) in together.entries) ArtistLink(key, value, together: true)]..sort(byName),
      ...[
        for (final MapEntry(:key, :value) in (_compiled[artist] ?? const <String, Song>{}).entries)
          if (!together.containsKey(key)) ArtistLink(key, value, together: false),
      ]..sort(byName),
    ];
  }

  bool hasLinks(String artist) => _together.containsKey(artist) || _compiled.containsKey(artist);

  /// The shortest chain of links from [from] to [to], as the steps after
  /// [from]; empty if they're the same artist, null if nothing links them.
  /// Shared songs are tried alone first, so compilations only fill gaps.
  List<ArtistLink>? path(String from, String to) {
    if (from == to) return const [];
    return _search(from, to, compilations: false) ?? _search(from, to, compilations: true);
  }

  /// How many steps away each artist linked to [from] is (compilations
  /// included), [from] itself at 0.
  Map<String, int> distancesFrom(String from) {
    final distance = {from: 0};
    final queue = Queue.of([from]);
    while (queue.isNotEmpty) {
      final artist = queue.removeFirst();
      for (final next in _linksOf(artist, compilations: true).keys) {
        if (distance.containsKey(next)) continue;
        distance[next] = distance[artist]! + 1;
        queue.add(next);
      }
    }
    return distance;
  }

  Map<String, ArtistLink> _linksOf(String artist, {required bool compilations}) => {
        if (compilations)
          for (final MapEntry(:key, :value) in (_compiled[artist] ?? const <String, Song>{}).entries)
            key: ArtistLink(key, value, together: false),
        for (final MapEntry(:key, :value) in (_together[artist] ?? const <String, Song>{}).entries)
          key: ArtistLink(key, value, together: true),
      };

  /// Breadth first, so the first time [to] is reached is by a shortest path.
  List<ArtistLink>? _search(String from, String to, {required bool compilations}) {
    final cameBy = <String, (String, ArtistLink)>{};
    final seen = {from};
    final queue = Queue.of([from]);
    while (queue.isNotEmpty) {
      final artist = queue.removeFirst();
      for (final MapEntry(key: next, value: link) in _linksOf(artist, compilations: compilations).entries) {
        if (!seen.add(next)) continue;
        cameBy[next] = (artist, link);
        if (next == to) {
          final steps = <ArtistLink>[];
          for (var at = to; at != from; at = cameBy[at]!.$1) {
            steps.add(cameBy[at]!.$2);
          }
          return steps.reversed.toList();
        }
        queue.add(next);
      }
    }
    return null;
  }
}
