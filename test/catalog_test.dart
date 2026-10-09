import 'package:blimp/services/catalog.dart';
import 'package:blimp/services/listening_stats.dart';
import 'package:blimp/services/media_library.dart';
import 'package:flutter_test/flutter_test.dart';

Song _song(
  int id, {
  String? artist = 'A',
  String? album = 'Album',
  int? albumId,
  String? albumArtist,
  bool compilation = false,
  int? track,
  int? disc,
  int? year,
}) => Song(
  id: id,
  title: 'Song $id',
  uri: 'content://$id',
  artist: artist,
  album: album,
  albumId: albumId,
  albumArtist: albumArtist,
  compilation: compilation,
  track: track,
  disc: disc,
  year: year,
);

void main() {
  test('albums play in disc, then track, order', () {
    final album = buildAlbums([
      _song(1, track: 1, disc: 2),
      _song(2, track: 2, disc: 1),
      _song(3, track: 1, disc: 1),
      _song(4, track: 2, disc: 2),
    ]).single;
    expect([for (final s in album.songs) s.id], [3, 2, 1, 4]);
  });

  test('an album is credited to its album artist, else its main artist', () {
    final tagged = buildAlbums([
      _song(1, artist: 'SZA', albumArtist: 'Kendrick Lamar'),
      _song(2, artist: 'SZA', albumArtist: 'Kendrick Lamar'),
    ]).single;
    expect(tagged.artist, 'Kendrick Lamar');

    // Guests on some songs don't take the credit.
    final untagged = buildAlbums([
      _song(1, artist: 'Kendrick Lamar/SZA'),
      _song(2, artist: 'Kendrick Lamar feat. Drake'),
      _song(3, artist: 'Kendrick Lamar'),
    ]).single;
    expect(untagged.artist, 'Kendrick Lamar');
  });

  test('compilations, by flag or by "Various Artists", belong to no artist', () {
    final albums = buildAlbums([
      _song(1, artist: 'ABBA', album: 'Hits', albumId: 1, compilation: true),
      _song(2, artist: 'Queen', album: 'Hits', albumId: 1, compilation: true),
      _song(3, artist: 'Prince', album: 'Now', albumId: 2, albumArtist: 'VA'),
    ]);
    expect(albums.every((a) => a.isCompilation), isTrue);
    expect(albums.map((a) => a.artist).toSet(), {'Various artists'});

    final artists = buildArtists([for (final a in albums) ...a.songs], albums);
    expect(artists.map((a) => a.name), ['ABBA', 'Prince', 'Queen']);
    expect(artists.every((a) => a.albums.isEmpty), isTrue);
  });

  test('collaborations count for each artist, and untagged songs for Unknown artist', () {
    final songs = [
      _song(1, artist: 'Jay Rock/Kendrick Lamar', album: null),
      _song(2, artist: 'Kendrick Lamar', album: null),
      _song(3, artist: null, album: null),
    ];
    final artists = buildArtists(songs, const []);
    expect(artists.map((a) => a.name), ['Jay Rock', 'Kendrick Lamar', 'Unknown artist']);
    expect(artists[1].songs.map((s) => s.id), [1, 2]);
  });

  test('an album credited to two artists is on both their pages', () {
    final songs = [
      for (var i = 0; i < 3; i++) _song(i, artist: 'Future/Metro Boomin', albumArtist: 'Future/Metro Boomin'),
    ];
    final albums = buildAlbums(songs);
    final artists = buildArtists(songs, albums);
    expect({for (final a in artists) a.name: a.albums.length}, {'Future': 1, 'Metro Boomin': 1});
  });

  test('splits featured artists but keeps names with commas, ampersands and slashes', () {
    expect(splitArtists('Drake feat. Rihanna'), ['Drake', 'Rihanna']);
    expect(splitArtists('Calvin Harris ft. Dua Lipa'), ['Calvin Harris', 'Dua Lipa']);
    expect(splitArtists('Tyler, The Creator'), ['Tyler, The Creator']);
    expect(splitArtists('Earth, Wind & Fire'), ['Earth, Wind & Fire']);
    expect(splitArtists('AC/DC'), ['AC/DC']);
    expect(splitArtists('Future/Future'), ['Future']);
  });

  test('commas and "&" split only when one of the names is an artist on its own', () {
    final credits = ArtistCredits([
      _song(1, artist: 'Kendrick Lamar'),
      _song(2, artist: 'Kendrick Lamar, Kodak Black'),
      _song(3, artist: 'Tyler, The Creator'),
      _song(4, artist: 'Earth, Wind & Fire'),
      _song(5, artist: 'Kendrick Lamar, Blxst & Amanda Reifer'),
    ]);
    expect(credits.split('Kendrick Lamar, Kodak Black'), ['Kendrick Lamar', 'Kodak Black']);
    expect(credits.split('Kendrick Lamar, Blxst & Amanda Reifer'), ['Kendrick Lamar', 'Blxst', 'Amanda Reifer']);
    expect(credits.split('Tyler, The Creator'), ['Tyler, The Creator']);
    expect(credits.split('Earth, Wind & Fire'), ['Earth, Wind & Fire']);
  });
}
