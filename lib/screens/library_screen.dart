import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/device_files.dart';
import '../services/folders.dart';
import '../services/m3u.dart';
import '../services/media_library.dart';
import '../services/music_controller.dart';
import '../services/smart_playlists.dart';
import '../theme.dart';
import '../widgets/shelf.dart';
import '../widgets/song_artwork.dart';
import '../widgets/song_table.dart';
import '../widgets/song_tile.dart';
import 'app_shell.dart';
import 'artist_screen.dart';
import 'collection_screen.dart';
import 'folder_screen.dart';
import 'playlist_screen.dart';
import '../widgets/add_to_playlist.dart';
import '../widgets/app_menu.dart';
import 'search_screen.dart';
import 'smart_playlist_screen.dart';

enum _Filter { playlists, songs, albums, artists }

enum _Sort {
  recentActivity('Recent activity'),
  recentlyAdded('Recently added'),
  year('Release year'),
  alphabetical('A to Z');

  const _Sort(this.label);
  final String label;
}

/// One row (or grid card) in the library.
class _Item {
  _Item({
    required this.title,
    required this.subtitle,
    required this.art,
    required this.onTap,
    required this.songs,
    this.circle = false,
    this.pinned = false,
    this.last = false,
    this.hiRes = false,
  });

  final String title;
  final String subtitle;
  final Widget art;
  final VoidCallback onTap;
  final List<Song> songs;
  final bool circle;

  /// Kept at the top regardless of sort.
  final bool pinned;

  /// Kept at the bottom regardless of sort, as Unknown artist is.
  final bool last;

  /// An album whose songs are all hi-res.
  final bool hiRes;

  /// This item with [year] added to its subtitle, as when sorting by it.
  _Item withYear(int year) => _Item(
    title: title,
    subtitle: '$subtitle • $year',
    art: art,
    onTap: onTap,
    songs: songs,
    circle: circle,
    pinned: pinned,
    last: last,
    hiRes: hiRes,
  );
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key}) : playlists = false;

  /// Just the playlists, for the Playlists tab.
  const LibraryScreen.playlists({super.key}) : playlists = true;

  final bool playlists;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late _Filter? _filter = widget.playlists ? _Filter.playlists : null;

  /// What the chips under the Library tab pick, after All. Playlists have
  /// their own tab.
  static const _chipFilters = [_Filter.songs, _Filter.albums, _Filter.artists];
  _Sort _sort = _Sort.recentActivity;
  bool _grid = false;

  /// The genre chip picked, narrowing songs, albums and artists to it.
  String? _genre;

  /// In Albums, the kind of release picked (Album, EP or Single), if any.
  String? _kind;

  /// The kinds of release the chips pick; a compilation can also be an album.
  static const _kinds = ['Album', 'EP', 'Single', 'Compilation'];

  bool _ofKind(Album album) => _kind == 'Compilation' ? album.isCompilation : album.kind == _kind;

  /// Whether Library shows the device's folders instead of the tag-based
  /// views; kept as a setting. Read from the controller on each build.
  bool _foldersMode = false;

  /// Whether [_genre] applies to what's shown: not playlists or folders.
  bool get _byGenre => !_foldersMode && _filter != _Filter.playlists;

  bool _inGenre(Song song) => song.genre == _genre;

  /// The library's songs, or just the picked genre's.
  List<Song> _songs(MusicController music, List<Song> all) => _genre == null || !_byGenre
      ? all
      : [
          for (final s in all)
            if (_inGenre(s)) s,
        ];

  List<_Item> _playlists(MusicController music) => [
    _Item(
      title: 'Favourites',
      subtitle: 'Auto playlist • ${describeLength(music.favouriteSongs.length, Duration.zero)}',
      art: const PlaylistArt.favourites(),
      songs: music.favouriteSongs,
      pinned: true,
      onTap: () => openPage(CollectionScreen.favourites()),
    ),
    _Item(
      title: 'Recently played',
      subtitle: 'Auto playlist',
      art: const PlaylistArt.history(),
      songs: music.recentlyPlayed,
      pinned: true,
      onTap: () => openPage(CollectionScreen.history()),
    ),
    _Item(
      title: 'Your top songs',
      subtitle: 'Auto playlist • Chart',
      art: const PlaylistArt.mostPlayed(),
      songs: music.mostPlayed,
      onTap: () => openPage(CollectionScreen.charts()),
    ),
    for (final year in music.chartYears)
      _Item(
        title: 'Top songs of $year',
        subtitle: 'Auto playlist • Chart',
        art: const PlaylistArt.yearChart(),
        songs: music.topSongsOf(year),
        onTap: () => openPage(CollectionScreen.yearChart(year)),
      ),
    _Item(
      title: 'Recently added',
      subtitle: 'Auto playlist • Newest on your device',
      art: const PlaylistArt.recentlyAdded(),
      songs: music.recentlyAdded,
      onTap: () => openPage(CollectionScreen.recentlyAdded()),
    ),
    ..._userPlaylists(music),
    for (final playlist in music.smartPlaylists)
      if (music.smartPlaylistSongs(playlist) case final songs)
        _Item(
          title: playlist.name,
          subtitle: 'Smart playlist • ${describeLength(songs.length, Duration.zero)}',
          art: const PlaylistArt.smart(),
          songs: songs,
          onTap: () => openSmartPlaylist(playlist),
        ),
  ];

  List<_Item> _userPlaylists(MusicController music) => [
    for (final playlist in music.playlists)
      _Item(
        title: playlist.name,
        subtitle: 'Playlist • ${describeLength(music.playlistSongs(playlist).length, Duration.zero)}',
        art: PlaylistCover(playlist: playlist),
        songs: music.playlistSongs(playlist),
        onTap: () => openPage(PlaylistScreen(playlistId: playlist.id)),
      ),
  ];

  /// Makes a playlist from an M3U file, named after it, from the songs of
  /// it that are on this phone.
  Future<void> _importPlaylist() async {
    final messenger = ScaffoldMessenger.of(context);
    final music = MusicScope.read(context);
    final ({String? name, Uint8List bytes})? file;
    try {
      file = await DeviceFiles.open(const [
        'audio/x-mpegurl',
        'audio/mpegurl',
        'application/vnd.apple.mpegurl',
        'application/x-mpegurl',
        'application/octet-stream',
        'text/plain',
      ]);
    } on PlatformException {
      messenger.showSnackBar(const SnackBar(content: Text("Couldn't open that file.")));
      return;
    }
    if (file == null || !mounted) return;
    // Most playlists are UTF-8; old ones from Windows may not be.
    final text = utf8.decode(file.bytes, allowMalformed: true);
    final (:songs, :missing) = M3u.decode(text, music.songs);
    if (songs.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text("None of that playlist's songs are on this phone.")));
      return;
    }
    final name = (file.name ?? 'Imported playlist').replaceFirst(RegExp(r'\.m3u8?$', caseSensitive: false), '');
    final playlist = music.createPlaylist(name, songs);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          missing == 0
              ? 'Imported $name'
              : 'Imported $name. $missing ${missing == 1 ? 'song isn\x27t' : 'songs aren\x27t'} on this phone.',
        ),
      ),
    );
    openPage(PlaylistScreen(playlistId: playlist.id));
  }

  Future<void> _newSmartPlaylist() async {
    final playlist = await Navigator.of(context).push<SmartPlaylist>(
      MaterialPageRoute(builder: (_) => const SmartPlaylistEditor()),
    );
    if (playlist != null) openSmartPlaylist(playlist);
  }

  Future<void> _newPlaylist() async {
    final name = await askPlaylistName(context);
    if (name == null || !mounted) return;
    final playlist = MusicScope.read(context).createPlaylist(name);
    openPage(PlaylistScreen(playlistId: playlist.id));
  }

  List<_Item> _albums(MusicController music) => [
    for (final album in music.albums)
      if ((_genre == null || album.songs.any(_inGenre)) &&
          (_kind == null || _filter != _Filter.albums || _ofKind(album)))
        _Item(
          title: album.title,
          subtitle: '${album.kind} • ${album.artist}',
          hiRes: music.isAlbumHiRes(album),
          art: SongArtwork(songId: album.cover.id, size: null),
          songs: album.songs,
          onTap: () => openPage(CollectionScreen.album(album)),
        ),
  ];

  List<_Item> _artists(MusicController music) => [
    for (final artist in music.artists)
      // With a genre picked, an artist counts (and sorts by) only their
      // songs in it: "Artist • 12 Hip-Hop songs".
      if (_genre == null ? artist.songs : artist.songs.where(_inGenre).toList() case final songs when songs.isNotEmpty)
        _Item(
          title: artist.name,
          subtitle: _genre == null
              ? 'Artist • ${describeLength(songs.length, Duration.zero)}'
              : 'Artist • ${songs.length} $_genre ${songs.length == 1 ? 'song' : 'songs'}',
          art: ArtistAvatar(songId: artist.cover.id, size: null),
          songs: songs,
          circle: true,
          last: artist.name == Song.unknownArtist,
          onTap: () => openPage(ArtistScreen(artistName: artist.name)),
        ),
  ];

  /// The top folder's subfolders; its own songs are listed below them.
  List<_Item> _folders(MusicController music) => [
    for (final folder in music.rootFolder?.folders ?? const <Folder>[])
      _Item(
        title: folder.name,
        subtitle: describeFolder(folder),
        art: const FolderArt(),
        songs: folder.allSongs,
        onTap: () => Navigator.of(context).push(folderRoute(folder.path, inLibrary: true)),
      ),
  ];

  List<_Item> _sorted(MusicController music, List<_Item> items) {
    // Each item's sort key is computed once, not on every comparison.
    final keyed =
        [
          for (final item in items.where((i) => !i.pinned && !i.last))
            (
              item: item,
              title: item.title.toLowerCase(),
              key: switch (_sort) {
                _Sort.recentActivity => music.lastPlayedRank(item.songs),
                _Sort.recentlyAdded => -_newest(item.songs),
                _Sort.year => -_latestYear(item.songs),
                _Sort.alphabetical => 0,
              },
            ),
        ]..sort((a, b) {
          // Dart's sort isn't stable; break ties by title so rows don't jump.
          final c = a.key.compareTo(b.key);
          return c != 0 ? c : a.title.compareTo(b.title);
        });
    // Pinned items keep their given order at the top, and last ones at the end.
    return [
      ...items.where((i) => i.pinned),
      for (final k in keyed)
        // Sorted by year, each shows its latest (when known).
        if (_sort == _Sort.year && k.key != 0) k.item.withYear(-k.key) else k.item,
      ...items.where((i) => i.last),
    ];
  }

  /// The latest year any of [songs] came out, 0 if none say.
  static int _latestYear(Iterable<Song> songs) => songs.fold(0, (latest, s) => max(latest, s.year ?? 0));

  /// When the newest of [songs] was added, in milliseconds.
  static int _newest(List<Song> songs) {
    var newest = 0;
    for (final s in songs) {
      final added = s.dateAdded?.millisecondsSinceEpoch ?? 0;
      if (added > newest) newest = added;
    }
    return newest;
  }

  /// Songs in the order shown: by the table's column if one was clicked,
  /// otherwise by the sort menu.
  List<Song> _sortedSongs(MusicController music) => switch (_tableSort) {
    final column? => [..._songs(music, music.songs)]
      ..sort((a, b) {
        final c = column.compare(a, b);
        // Ties by title, so rows don't jump.
        return c != 0 ? (_descending ? -c : c) : SongColumn.title.compare(a, b);
      }),
    null => _menuSortedSongs(music),
  };

  /// The songs table's column clicked, and whether it was clicked again to
  /// reverse it. Choosing from the sort menu clears it.
  SongColumn? _column;
  bool _descending = false;

  /// [_column], where it applies: only to Songs.
  SongColumn? get _tableSort => !_foldersMode && _filter == _Filter.songs ? _column : null;

  void _sortByColumn(SongColumn column) => setState(() {
    _descending = _column == column && !_descending;
    _column = column;
  });

  List<Song> _menuSortedSongs(MusicController music) => switch (_sort) {
    _Sort.recentActivity => [
      for (final k
          in [
            for (final s in _songs(music, music.songs))
              (song: s, rank: music.lastPlayedRank([s]), title: s.searchFields.first),
          ]..sort((a, b) {
            final c = a.rank.compareTo(b.rank);
            return c != 0 ? c : a.title.compareTo(b.title);
          }))
        k.song,
    ],
    _Sort.recentlyAdded => _songs(music, music.recentlyAdded),
    // Newest first; songs with no year last, then by title.
    _Sort.year => [
      for (final k
          in [for (final s in _songs(music, music.songs)) (song: s, year: s.year ?? 0, title: s.searchFields.first)]
            ..sort((a, b) {
              final c = b.year.compareTo(a.year);
              return c != 0 ? c : a.title.compareTo(b.title);
            }))
        k.song,
    ],
    _Sort.alphabetical => [
      for (final k in [
        for (final s in _songs(music, music.songs)) (song: s, title: s.searchFields.first),
      ]..sort((a, b) => a.title.compareTo(b.title)))
        k.song,
    ],
  };

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {
      MusicAspect.library,
      MusicAspect.history,
      MusicAspect.favourites,
      MusicAspect.playlists,
      MusicAspect.settings,
    });
    _foldersMode = !widget.playlists && music.browseFolders;
    // A genre gone after a rescan (or hidden away) no longer narrows anything.
    if (!music.genres.contains(_genre)) _genre = null;
    final items = _foldersMode
        ? _folders(music)
        : switch (_filter) {
            null => [..._albums(music), ..._artists(music)],
            _Filter.playlists => _playlists(music),
            _Filter.albums => _albums(music),
            _Filter.artists => _artists(music),
            _Filter.songs => const <_Item>[],
          };
    final sorted = _sorted(music, items);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            titleSpacing: 16,
            title: Text(widget.playlists ? 'Playlists' : 'Library'),
            actions: [
              IconButton(
                tooltip: 'History',
                icon: const Icon(Icons.history),
                onPressed: () => openPage(CollectionScreen.history()),
              ),
              IconButton(
                tooltip: 'Search',
                icon: const Icon(Icons.search),
                onPressed: () => openPage(const SearchScreen()),
              ),
              const AppMenuButton(),
              const SizedBox(width: 8),
            ],
            // Two ways to browse: by tags (with the filter chips) or by folder.
            bottom: widget.playlists ? null : PreferredSize(
              preferredSize: Size.fromHeight(_foldersMode ? 58 : 58 + 52),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: SegmentedPills(
                      labels: const ['Library', 'Folders'],
                      icons: const [Icons.library_music_outlined, Icons.folder_outlined],
                      selected: _foldersMode ? 1 : 0,
                      onChanged: (i) => music.setBrowseFolders(i == 1),
                    ),
                  ),
                  if (!_foldersMode)
                    ChipBar(
                      labels: const ['All', 'Songs', 'Albums', 'Artists'],
                      selected: _filter == null ? 0 : _chipFilters.indexOf(_filter!) + 1,
                      onSelected: (i) => setState(() => _filter = i == 0 ? null : _chipFilters[i - 1]),
                    ),
                ],
              ),
            ),
          ),
          if (_byGenre && music.genres.isNotEmpty)
            SliverToBoxAdapter(
              child: ChipBar(
                tonal: true,
                labels: music.genres,
                selected: _genre == null ? null : music.genres.indexOf(_genre!),
                // Tapping the picked genre again shows everything.
                onSelected: (i) => setState(() => _genre = music.genres[i] == _genre ? null : music.genres[i]),
              ),
            ),
          SliverToBoxAdapter(child: _sortBar(context, music)),
          if (!_foldersMode && _filter == _Filter.albums)
            SliverToBoxAdapter(
              child: ChipBar(
                tonal: true,
                labels: const ['Albums', 'EPs', 'Singles', 'Compilations'],
                selected: _kind == null ? null : _kinds.indexOf(_kind!),
                // Tapping the picked kind again shows every release.
                onSelected: (i) => setState(() => _kind = _kinds[i] == _kind ? null : _kinds[i]),
              ),
            ),
          if (!_foldersMode && _filter == _Filter.songs)
            ..._songSlivers(music)
          else if (_foldersMode && music.rootFolder == null)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: MessageView(
                icon: Icons.folder_off_outlined,
                text: "Android didn't say where your music files are.",
              ),
            )
          else if (sorted.isEmpty && _kind != null && _filter == _Filter.albums)
            SliverFillRemaining(
              hasScrollBody: false,
              child: MessageView(
                icon: Icons.album_outlined,
                text: switch (_kind) {
                  'Compilation' => 'No compilations here.',
                  'EP' => 'No EPs here.',
                  final kind => 'No ${kind!.toLowerCase()}s here.',
                },
              ),
            )
          else if (_grid)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  // Two across on a phone; more as a desktop window widens.
                  final columns = max(2, (constraints.crossAxisExtent + 12) ~/ 192);
                  final cardWidth = (constraints.crossAxisExtent - 12 * (columns - 1)) / columns;
                  return SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 16,
                      mainAxisExtent: cardWidth + 72,
                    ),
                    itemCount: sorted.length,
                    itemBuilder: (context, i) {
                      final item = sorted[i];
                      return MediaCard(
                        width: cardWidth,
                        art: item.art,
                        circle: item.circle,
                        title: item.title,
                        subtitle: item.subtitle,
                        hiRes: item.hiRes,
                        onTap: item.onTap,
                        onPlay: item.songs.isEmpty ? null : () => music.playSongs(item.songs),
                      );
                    },
                  );
                },
              ),
            )
          else
            // Built lazily: only rows on screen exist, however big the library.
            SliverList.builder(
              itemCount: sorted.length,
              itemBuilder: (context, i) => _LibraryRow(item: sorted[i]),
            ),
          if (_foldersMode) ..._rootSongSlivers(music),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  /// Whether a genre is picked and narrows what's shown.
  bool get _genrePicked => _genre != null && _byGenre;

  Widget _sortBar(BuildContext context, MusicController music) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(
        children: [
          // A genre's songs can be played straight away; the sort still
          // applies, and its menu comes back once the genre is cleared.
          if (_genrePicked) ...[
            PillButton(
              label: 'Play all',
              icon: Icons.play_arrow_rounded,
              filled: true,
              onPressed: () => music.playSongs(_sortedSongs(music)),
            ),
            const SizedBox(width: 8),
            PillButton(
              label: 'Shuffle',
              icon: Icons.shuffle,
              onPressed: () => music.playSongs(_sortedSongs(music), shuffle: true),
            ),
          ] else
            PopupMenuButton<_Sort>(
              initialValue: _tableSort == null ? _sort : null,
              position: PopupMenuPosition.under,
              onSelected: (sort) => setState(() {
                _sort = sort;
                _column = null;
              }),
              itemBuilder: (_) => [for (final s in _Sort.values) PopupMenuItem(value: s, child: Text(s.label))],
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
                decoration: const ShapeDecoration(color: AppColors.surface, shape: StadiumBorder()),
                child: Row(
                  children: [
                    Icon(Icons.sort_rounded, size: 18, color: AppColors.accent),
                    const SizedBox(width: 6),
                    Text(_tableSort?.label ?? _sort.label, style: Theme.of(context).textTheme.labelLarge),
                    const Icon(Icons.expand_more_rounded, size: 20, color: AppColors.textSecondary),
                  ],
                ),
              ),
            ),
          const Spacer(),
          if (!_foldersMode && _filter == _Filter.playlists)
            IconButton(
              tooltip: 'New smart playlist',
              icon: const Icon(Icons.auto_awesome_outlined),
              onPressed: _newSmartPlaylist,
            ),
          if (!_foldersMode && _filter == _Filter.playlists)
            IconButton(
              tooltip: 'Import a playlist (M3U)',
              icon: const Icon(Icons.file_open_outlined),
              onPressed: _importPlaylist,
            ),
          if (!_foldersMode && _filter == _Filter.playlists)
            TextButton.icon(
              onPressed: _newPlaylist,
              icon: const Icon(Icons.add_rounded),
              label: const Text('New playlist'),
            ),
          if (_foldersMode || _filter != _Filter.songs)
            IconButton(
              tooltip: _grid ? 'List view' : 'Grid view',
              icon: Icon(_grid ? Icons.view_agenda_outlined : Icons.grid_view_rounded),
              onPressed: () => setState(() => _grid = !_grid),
            ),
        ],
      ),
    );
  }

  /// The songs sitting directly in the top folder, after its subfolders.
  List<Widget> _rootSongSlivers(MusicController music) {
    final songs = music.rootFolder?.songs ?? const <Song>[];
    if (songs.isEmpty) return const [];
    return [
      SliverList.builder(
        itemCount: songs.length,
        itemBuilder: (context, i) => SongTile(
          song: songs[i],
          subtitle: songs[i].fileName,
          onTap: () => music.playSongs(songs, index: i),
        ),
      ),
    ];
  }

  List<Widget> _songSlivers(MusicController music) {
    final songs = _sortedSongs(music);
    return [
      // With a genre picked, the bar above already plays and shuffles.
      if (!_genrePicked)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                PillButton(
                  label: 'Shuffle all',
                  icon: Icons.shuffle,
                  filled: true,
                  onPressed: () => music.playSongs(songs, shuffle: true),
                ),
              ],
            ),
          ),
        ),
      // A wide desktop window lists them as a table, sorted by its columns.
      if (DesktopFrame.showsTabs(context)) ...[
        SliverPersistentHeader(
          pinned: true,
          delegate: SongTableHeaderDelegate(
            SongTableHeader(sortedBy: _tableSort, descending: _descending, onSort: _sortByColumn),
          ),
        ),
        SliverList.builder(
          itemCount: songs.length,
          itemBuilder: (context, i) => SongTableRow(song: songs[i], onTap: () => music.playSongs(songs, index: i)),
        ),
      ] else
        SliverList.builder(
          itemCount: songs.length,
          itemBuilder: (context, i) => SongTile(
            song: songs[i],
            subtitle: _sort == _Sort.year && songs[i].year != null
                ? [songs[i].artistName, ?songs[i].album, songs[i].year].join(' • ')
                : null,
            onTap: () => music.playSongs(songs, index: i),
          ),
        ),
    ];
  }
}

class _LibraryRow extends StatelessWidget {
  const _LibraryRow({required this.item});

  final _Item item;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      onTap: item.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            SizedBox.square(dimension: 56, child: item.art),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodyLarge),
                  const SizedBox(height: 2),
                  HiResLine(
                    hiRes: item.hiRes,
                    line: Text(
                      item.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium,
                    ),
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
