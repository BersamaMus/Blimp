import 'package:audio_service/audio_service.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'media_library.dart';
import 'music_controller.dart';
import 'search_text.dart';

/// The library as Android Auto (and other media browsers) shows it: a few
/// tabs, Recent, Favourites, Playlists, Albums and Artists, each opening onto
/// songs to play. Picking a song plays the list it's in from there.
///
/// Ids say where an item is: `album:123` is the album song 123 is on, and
/// `song:45|album:123` song 45 played as part of that album.
class CarBrowser implements MediaBrowserDelegate {
  CarBrowser(this.music);

  final MusicController music;

  /// Car screens show long lists poorly, and may refuse very long ones.
  static const _limit = 300;

  static const _recent = 'recent';
  static const _favourites = 'favourites';
  static const _playlists = 'playlists';
  static const _albums = 'albums';
  static const _artists = 'artists';

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId) async {
    // Asked before the library has loaded, e.g. when the car starts the app.
    await music.ready;
    return switch (parentMediaId) {
      AudioService.browsableRootId => [
          _folder(_recent, 'Recent'),
          _folder(_favourites, 'Favourites'),
          _folder(_playlists, 'Playlists'),
          _folder(_albums, 'Albums'),
          _folder(_artists, 'Artists'),
        ],
      // Android's "resume" suggestions: what was played last.
      AudioService.recentRootId => [
          for (final song in music.recentlyPlayed.take(1)) _song(song, _recent),
        ],
      _playlists => [
          for (final playlist in music.playlists)
            if (music.playlistSongs(playlist) case final songs when songs.isNotEmpty)
              _folder('playlist:${playlist.id}', playlist.name, subtitle: _count(songs.length), artFrom: songs.first),
        ],
      _albums => [
          for (final album in music.albums.take(_limit))
            _folder('album:${album.cover.id}', album.title, subtitle: album.artist, artFrom: album.cover),
        ],
      _artists => [
          for (final artist in music.artists.take(_limit))
            _folder('artist:${artist.name}', artist.name, subtitle: _count(artist.songs.length), artFrom: artist.cover),
        ],
      _ => [for (final song in _songsIn(parentMediaId).take(_limit)) _song(song, parentMediaId)],
    };
  }

  /// The songs a list id stands for, in the order they play.
  List<Song> _songsIn(String listId) {
    final (kind, key) = switch (listId.indexOf(':')) {
      -1 => (listId, ''),
      final colon => (listId.substring(0, colon), listId.substring(colon + 1)),
    };
    return switch (kind) {
      _recent => music.recentlyPlayed,
      _favourites => music.favouriteSongs,
      'playlist' => switch (music.playlistWithId(key)) {
          final playlist? => music.playlistSongs(playlist),
          null => const [],
        },
      'album' => switch (music.songWithId(int.tryParse(key))) {
          final song? => music.albumOf(song)?.songs ?? [song],
          null => const [],
        },
      'artist' => music.artistNamed(key)?.songs ?? const [],
      'search' => _search(key),
      _ => const [],
    };
  }

  @override
  Future<void> playFromMediaId(String mediaId) async {
    if (!mediaId.startsWith('song:')) return;
    final bar = mediaId.indexOf('|');
    final id = int.tryParse(mediaId.substring(5, bar < 0 ? null : bar));
    final song = music.songWithId(id);
    if (song == null) return;
    final list = bar < 0 ? [song] : _songsIn(mediaId.substring(bar + 1));
    final index = list.indexOf(song);
    // Not in its list any more (say, unfavourited meanwhile): just that song.
    await (index < 0 ? music.playSongs([song]) : music.playSongs(list, index: index));
  }

  @override
  Future<List<MediaItem>> search(String query) async =>
      [for (final song in _search(query).take(50)) _song(song, 'search:$query')];

  /// "Play something", or "play" a song or artist by name, by voice.
  @override
  Future<void> playFromSearch(String query) async {
    if (query.trim().isEmpty) return music.playQuickPicks();
    final q = searchKey(query);
    // An artist's name: their songs, shuffled.
    for (final artist in music.artists) {
      if (artist.searchFields.first == q) return music.playSongs(artist.songs, shuffle: true);
    }
    final found = _search(query);
    if (found.isNotEmpty) await music.startRadio(found.first);
  }

  /// Songs whose title, artist or album has [query] in it, the ones
  /// starting with it first; compared as search does (see [searchKey]).
  List<Song> _search(String query) {
    final q = searchKey(query);
    if (q.isEmpty) return const [];
    final starts = <Song>[], contains = <Song>[];
    for (final song in music.songs) {
      if (song.searchFields.any((f) => f.startsWith(q))) {
        starts.add(song);
      } else if (song.searchFields.any((f) => f.contains(q))) {
        contains.add(song);
      }
    }
    return [...starts, ...contains];
  }

  static String _count(int n) => n == 1 ? '1 song' : '$n songs';

  MediaItem _folder(String id, String title, {String? subtitle, Song? artFrom}) => MediaItem(
        id: id,
        title: title,
        artist: subtitle,
        playable: false,
        artUri: artFrom == null ? null : Uri.parse(artFrom.uri),
        extras: {if (artFrom != null) 'loadThumbnailUri': artFrom.uri},
      );

  MediaItem _song(Song song, String listId) => MediaItem(
        id: 'song:${song.id}|$listId',
        title: song.title,
        artist: song.artistName,
        album: song.album,
        duration: song.duration == Duration.zero ? null : song.duration,
        playable: true,
        artUri: Uri.parse(song.uri),
        extras: {'loadThumbnailUri': song.uri},
      );
}
