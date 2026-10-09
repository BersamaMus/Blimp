import 'package:flutter/material.dart';

import '../services/media_library.dart';
import '../services/music_controller.dart';
import '../services/search_text.dart';
import '../theme.dart';
import '../widgets/shelf.dart';
import '../widgets/song_artwork.dart';
import '../widgets/song_tile.dart';
import 'app_shell.dart';
import 'artist_screen.dart';
import 'collection_screen.dart';
import 'now_playing_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

enum _Filter { songs, albums, artists }

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  _Filter? _filter;

  String get _query => searchKey(_controller.text);

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Remembers the query once the user acts on a result.
  void _commit() => MusicScope.read(context).addRecentSearch(_controller.text);

  /// 0 for a match at the start of a word (ranked first), 1 for a match
  /// elsewhere, null for none. Both [query] and [fields] are search keys
  /// (see [searchKey]); ignoring spaces, "acdc" still finds "ac dc".
  static int? _score(String query, String wordStart, String compactQuery, Iterable<String> fields) {
    int? best;
    for (final value in fields) {
      if (value.startsWith(query) || value.contains(wordStart)) return 0;
      if (best == null && (value.contains(query) || compactKey(value).contains(compactQuery))) best = 1;
    }
    return best;
  }

  List<T> _ranked<T>(Iterable<T> items, Iterable<String> Function(T) searchFields) {
    final query = _query, wordStart = ' $query', compactQuery = compactKey(query);
    final scored = [
      for (final item in items)
        if (_score(query, wordStart, compactQuery, searchFields(item)) case final int score) (item, score),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final (item, _) in scored) item];
  }

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.library, MusicAspect.searches});
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _commit(),
          style: const TextStyle(fontSize: 18),
          decoration: const InputDecoration(
            hintText: 'Search songs, albums, artists',
            hintStyle: TextStyle(color: AppColors.textTertiary),
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(tooltip: 'Clear', icon: const Icon(Icons.close), onPressed: _controller.clear),
        ],
      ),
      body: _query.isEmpty ? _recentSearches(music) : _results(music),
    );
  }

  Widget _recentSearches(MusicController music) {
    final searches = music.recentSearches;
    if (searches.isEmpty) {
      return const MessageView(icon: Icons.search, text: 'Search your library for songs, albums and artists.');
    }
    return ListView(
      children: [
        for (final query in searches)
          ListTile(
            leading: const Icon(Icons.history, color: AppColors.textSecondary),
            title: Text(query),
            onTap: () => _controller.text = query,
            trailing: IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.close, color: AppColors.textSecondary),
              onPressed: () => music.removeRecentSearch(query),
            ),
          ),
      ],
    );
  }

  Widget _results(MusicController music) {
    final songs = _ranked(music.songs, (s) => s.searchFields);
    final albums = _ranked(music.albums, (a) => a.searchFields);
    final artists = _ranked(music.artists, (a) => a.searchFields);

    if (songs.isEmpty && albums.isEmpty && artists.isEmpty) {
      return MessageView(icon: Icons.search_off, text: 'No results for "${_controller.text.trim()}"');
    }

    void playSong(List<Song> list, int i) {
      _commit();
      music.playSongs(list, index: i);
    }

    void open(Widget page) {
      _commit();
      openPage(page);
    }

    Widget albumRow(Album album) => _ResultRow(
      art: SongArtwork(songId: album.cover.id, size: 56),
      title: album.title,
      subtitle: [album.kind, album.artist, ?album.year?.toString()].join(' • '),
      onTap: () => open(CollectionScreen.album(album)),
      hiRes: music.isAlbumHiRes(album),
    );

    Widget artistRow(Artist artist) => _ResultRow(
      art: ArtistAvatar(songId: artist.cover.id, size: 56),
      title: artist.name,
      subtitle: 'Artist • ${describeLength(artist.songs.length, Duration.zero)}',
      onTap: () => open(ArtistScreen(artistName: artist.name)),
    );

    final children = <Widget>[
      ChipBar(
        labels: const ['Songs', 'Albums', 'Artists'],
        selected: _filter?.index,
        onSelected: (i) => setState(() => _filter = _filter?.index == i ? null : _Filter.values[i]),
      ),
      ...switch (_filter) {
        _Filter.songs => [for (final (i, song) in songs.indexed) SongTile(song: song, onTap: () => playSong(songs, i))],
        _Filter.albums => albums.map(albumRow),
        _Filter.artists => artists.map(artistRow),
        null => [
          const ShelfHeader(title: 'Top result'),
          _topResult(music, songs, albums, artists, playSong, open),
          if (songs.isNotEmpty) ...[
            ShelfHeader(
              title: 'Songs',
              actionLabel: songs.length > 4 ? 'Show all' : null,
              onAction: () => setState(() => _filter = _Filter.songs),
            ),
            for (final (i, song) in songs.take(4).indexed) SongTile(song: song, onTap: () => playSong(songs, i)),
          ],
          if (albums.isNotEmpty) ...[
            ShelfHeader(
              title: 'Albums',
              actionLabel: albums.length > 3 ? 'Show all' : null,
              onAction: () => setState(() => _filter = _Filter.albums),
            ),
            ...albums.take(3).map(albumRow),
          ],
          if (artists.isNotEmpty) ...[
            ShelfHeader(
              title: 'Artists',
              actionLabel: artists.length > 3 ? 'Show all' : null,
              onAction: () => setState(() => _filter = _Filter.artists),
            ),
            ...artists.take(3).map(artistRow),
          ],
        ],
      },
      const SizedBox(height: 24),
    ];

    return ListView(keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag, children: children);
  }

  /// The big first card: an artist when the name matches well, else an album, else a song.
  Widget _topResult(
    MusicController music,
    List<Song> songs,
    List<Album> albums,
    List<Artist> artists,
    void Function(List<Song>, int) playSong,
    void Function(Widget) open,
  ) {
    final query = _query;
    final Widget art;
    final String title, subtitle;
    final VoidCallback onTap, onPlay;
    final List<Song> shuffleSongs;
    final bool circle;
    var hiRes = false;

    if (artists.isNotEmpty && (artists.first.searchFields.first.startsWith(query) || songs.isEmpty)) {
      final artist = artists.first;
      art = ArtistAvatar(songId: artist.cover.id, size: 96);
      title = artist.name;
      subtitle = 'Artist';
      onTap = () => open(ArtistScreen(artistName: artist.name));
      onPlay = () => playSong(artist.songs, 0);
      shuffleSongs = artist.songs;
      circle = true;
    } else if (albums.isNotEmpty && (albums.first.searchFields.first.startsWith(query) || songs.isEmpty)) {
      final album = albums.first;
      art = SongArtwork(songId: album.cover.id, size: 96);
      title = album.title;
      subtitle = '${album.kind} • ${album.artist}';
      onTap = () => open(CollectionScreen.album(album));
      onPlay = () => playSong(album.songs, 0);
      shuffleSongs = album.songs;
      circle = false;
      hiRes = music.isAlbumHiRes(album);
    } else {
      final song = songs.first;
      art = SongArtwork(songId: song.id, size: 96);
      title = song.title;
      subtitle = 'Song • ${song.artistName}';
      Future<void> play() {
        _commit();
        return music.startRadio(song);
      }

      onPlay = play;
      onTap = () => playAndOpen(context, play);
      shuffleSongs = songs;
      circle = false;
      hiRes = music.isHiRes(song);
    }

    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: const Color(0x14FFFFFF),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    art,
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: textTheme.titleLarge),
                          const SizedBox(height: 4),
                          HiResLine(
                            hiRes: hiRes,
                            line: Text(subtitle, style: textTheme.bodyMedium),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: PillButton(label: 'Play', icon: Icons.play_arrow, filled: true, onPressed: onPlay),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: PillButton(
                        label: circle ? 'Shuffle' : 'Radio',
                        icon: circle ? Icons.shuffle : Icons.sensors,
                        onPressed: () {
                          _commit();
                          circle ? music.playSongs(shuffleSongs, shuffle: true) : music.startRadio(shuffleSongs.first);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.art,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.hiRes = false,
  });

  final Widget art;
  final bool hiRes;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            art,
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodyLarge),
                  HiResLine(
                    hiRes: hiRes,
                    line: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodyMedium),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
