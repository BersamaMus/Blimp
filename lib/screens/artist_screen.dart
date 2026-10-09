import 'package:flutter/material.dart';

import '../services/music_controller.dart';
import '../theme.dart';
import '../widgets/shelf.dart';
import '../widgets/song_artwork.dart';
import '../widgets/song_tile.dart';
import 'app_shell.dart';
import '../widgets/cards.dart';
import 'search_screen.dart';

/// Opens the page of one of [artists], those credited on a song or album:
/// straight away if there's one, otherwise after asking which.
void openArtists(BuildContext context, List<Artist> artists) {
  if (artists.isEmpty) return;
  if (artists.length == 1) return openPage(ArtistScreen(artistName: artists.single.name));
  showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    // Scrolls when a song credits more artists than fit.
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text('Go to artist', style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
            for (final artist in artists)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: ArtistAvatar(songId: artist.cover.id, size: 40),
                title: Text(artist.name),
                onTap: () {
                  Navigator.pop(sheetContext);
                  openPage(ArtistScreen(artistName: artist.name));
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

class ArtistScreen extends StatefulWidget {
  const ArtistScreen({super.key, required this.artistName});

  /// Looked up on each build so the page follows library rescans.
  final String artistName;

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  final _scroll = ScrollController();
  final _barOpacity = ValueNotifier(0.0);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() => _barOpacity.value = ((_scroll.offset - 200) / 80).clamp(0.0, 1.0));
  }

  @override
  void dispose() {
    _scroll.dispose();
    _barOpacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.library, MusicAspect.history});
    final artist = music.artistNamed(widget.artistName);
    if (artist == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const MessageView(icon: Icons.person_off_outlined, text: 'This artist is no longer in your library.'),
      );
    }

    final textTheme = Theme.of(context).textTheme;
    final width = MediaQuery.sizeOf(context).width;

    final songs = artist.songs;
    // Radio starts from the artist's most played song.
    final mostPlayed = songs.reduce((a, b) => music.playCount(b) > music.playCount(a) ? b : a);
    final albums = artist.albums.where((a) => a.kind == 'Album').toList();
    final singles = artist.albums.where((a) => a.kind != 'Album').toList();

    Widget albumShelf(String title, List<Album> list) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ShelfHeader(title: title),
        Shelf(
          height: 160 + 72,
          itemCount: list.length,
          itemBuilder: (context, i) =>
              AlbumCard(album: list[i], subtitle: [list[i].kind, ?list[i].year?.toString()].join(' • ')),
        ),
      ],
    );

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: ValueListenableBuilder(
          valueListenable: _barOpacity,
          builder: (context, opacity, _) => AppBar(
            backgroundColor: AppColors.background.withValues(alpha: opacity),
            // Fading the color avoids the offscreen layer an Opacity widget needs.
            title: Text(
              artist.name,
              style: TextStyle(color: Colors.white.withValues(alpha: opacity)),
            ),
            actions: [
              IconButton(
                tooltip: 'Search',
                icon: const Icon(Icons.search),
                onPressed: () => openPage(const SearchScreen()),
              ),
            ],
          ),
        ),
      ),
      body: ListView(
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          SizedBox(
            height: width * 0.95,
            child: Stack(
              fit: StackFit.expand,
              children: [
                SongArtwork(songId: artist.cover.id, size: null, radius: 0, large: true),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x66000000), Colors.transparent, AppColors.background],
                      stops: [0, 0.35, 1],
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        artist.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1),
                      ),
                      Text(
                        [
                          describeLength(artist.songs.length, Duration.zero),
                          if (artist.albums.isNotEmpty)
                            artist.albums.length == 1 ? '1 release' : '${artist.albums.length} releases',
                        ].join(' • '),
                        style: textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                PillButton(
                  label: 'Shuffle',
                  icon: Icons.shuffle,
                  filled: true,
                  onPressed: () => music.playSongs(artist.songs, shuffle: true),
                ),
                const SizedBox(width: 8),
                PillButton(label: 'Radio', icon: Icons.sensors, onPressed: () => music.startRadio(mostPlayed)),
              ],
            ),
          ),
          const ShelfHeader(title: 'Songs'),
          for (final (i, song) in songs.indexed)
            SongTile(
              song: song,
              subtitle: song.album,
              onTap: () => music.playSongs(songs, index: i),
            ),
          if (albums.isNotEmpty) albumShelf('Albums', albums),
          if (singles.isNotEmpty) albumShelf('Singles & EPs', singles),
        ],
      ),
    );
  }
}
