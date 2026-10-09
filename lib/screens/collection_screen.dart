import 'package:flutter/material.dart';

import '../services/media_library.dart';
import '../services/music_controller.dart';
import '../theme.dart';
import '../widgets/add_to_playlist.dart';
import '../widgets/shelf.dart';
import '../widgets/song_artwork.dart';
import '../widgets/song_tile.dart';
import 'app_shell.dart';
import 'artist_screen.dart';
import 'search_screen.dart';

/// An album or playlist page.
class CollectionScreen extends StatefulWidget {
  CollectionScreen.album(Album album, {super.key})
    : title = album.title,
      kindLine = [album.kind, ?album.year?.toString()].join(' • '),
      artistName = album.artist,
      art = SongArtwork(songId: album.cover.id, size: null, radius: AppRadius.card),
      songsOf = ((_) => album.songs),
      album = album,
      isAlbum = true,
      ranked = false,
      emptyText = '';

  const CollectionScreen.playlist({
    super.key,
    required this.title,
    required this.art,
    required this.songsOf,
    this.kindLine = 'Auto playlist',
    this.ranked = false,
    this.emptyText = 'No songs yet.',
  }) : artistName = null,
       album = null,
       isAlbum = false;

  CollectionScreen.favourites({Key? key})
    : this.playlist(
        key: key,
        title: 'Favourites',
        art: const PlaylistArt.favourites(radius: AppRadius.card),
        songsOf: (music) => music.favouriteSongs,
        emptyText: 'Your favourite songs will show up here.\nTap ♡ on any song to add it.',
      );

  CollectionScreen.history({Key? key})
    : this.playlist(
        key: key,
        title: 'Recently played',
        art: const PlaylistArt.history(radius: AppRadius.card),
        songsOf: (music) => music.recentlyPlayed,
        emptyText: "Songs you play will show up here.",
      );

  CollectionScreen.recentlyAdded({Key? key})
    : this.playlist(
        key: key,
        title: 'Recently added',
        kindLine: 'Recently added to your device',
        art: const PlaylistArt.recentlyAdded(radius: AppRadius.card),
        songsOf: (music) => music.recentlyAdded,
      );

  CollectionScreen.charts({Key? key})
    : this.playlist(
        key: key,
        title: 'Your top songs',
        kindLine: 'Chart • Ranked by plays',
        art: const PlaylistArt.mostPlayed(radius: AppRadius.card),
        songsOf: (music) => music.mostPlayed,
        ranked: true,
        emptyText: 'Play some songs to build your chart.',
      );

  final String title;
  final String kindLine;
  final String? artistName;
  final Widget art;
  final List<Song> Function(MusicController music) songsOf;
  final bool isAlbum;

  /// The album shown, for its "About" info; null for playlists.
  final Album? album;
  final bool ranked;
  final String emptyText;

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  final _scroll = ScrollController();

  /// How solid the app bar is: clear over the header, opaque once scrolled past it.
  final _barOpacity = ValueNotifier(0.0);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() => _barOpacity.value = ((_scroll.offset - 120) / 80).clamp(0.0, 1.0));
  }

  @override
  void dispose() {
    _scroll.dispose();
    _barOpacity.dispose();
    super.dispose();
  }

  /// The songs split where the disc changes, as (start, end, disc), for an
  /// album on more than one disc; otherwise all of them, with no disc.
  List<(int, int, int?)> _discRuns(List<Song> songs) {
    if (!widget.isAlbum || songs.map((s) => s.disc ?? 1).toSet().length < 2) return [(0, songs.length, null)];
    final runs = <(int, int, int?)>[];
    var start = 0;
    for (var i = 1; i <= songs.length; i++) {
      if (i == songs.length || (songs[i].disc ?? 1) != (songs[start].disc ?? 1)) {
        runs.add((start, i, songs[start].disc ?? 1));
        start = i;
      }
    }
    return runs;
  }

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.library, MusicAspect.history, MusicAspect.favourites});
    final songs = widget.songsOf(music);
    final textTheme = Theme.of(context).textTheme;
    // Several for an album by "A/B"; none for a compilation's "Various artists".
    final artists = music.artistsCredited(widget.artistName);
    final topPadding = MediaQuery.paddingOf(context).top + kToolbarHeight;
    final artSize = (MediaQuery.sizeOf(context).width * 0.36).clamp(120.0, 180.0);

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
              widget.title,
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
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(
            child: _TintedHeader(
              // Tinted with the cover's color when there is a cover.
              songId: songs.isNotEmpty && widget.art is SongArtwork ? songs.first.id : null,
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, topPadding + 8, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        SizedBox.square(dimension: artSize, child: widget.art),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              HiResLine(
                                hiRes: widget.album != null && music.isAlbumHiRes(widget.album!),
                                line: Text(
                                  widget.kindLine.toUpperCase(),
                                  style: textTheme.labelSmall?.copyWith(color: AppColors.accent, letterSpacing: 1.2),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                widget.title,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.headlineSmall,
                              ),
                              if (widget.artistName case final artistName?) ...[
                                const SizedBox(height: 8),
                                InkWell(
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: artists.isEmpty ? null : () => openArtists(context, artists),
                                  child: Row(
                                    children: [
                                      if (artists.isNotEmpty) ...[
                                        ArtistAvatar(songId: artists.first.cover.id, size: 22),
                                        const SizedBox(width: 8),
                                      ],
                                      Expanded(
                                        child: Text(
                                          artistName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: textTheme.titleSmall,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              const SizedBox(height: 6),
                              Text(
                                describeLength(
                                  songs.length,
                                  songs.fold(Duration.zero, (sum, s) => sum + (s.duration ?? Duration.zero)),
                                ),
                                style: textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _ActionRow(songs: songs),
                  ],
                ),
              ),
            ),
          ),
          if (songs.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(widget.emptyText, textAlign: TextAlign.center, style: textTheme.bodyLarge),
              ),
            )
          else ...[
            for (final (start, end, disc) in _discRuns(songs)) ...[
              if (disc != null) SliverToBoxAdapter(child: ShelfHeader(title: 'Disc $disc')),
              SliverList.builder(
                itemCount: end - start,
                itemBuilder: (context, j) {
                  final i = start + j;
                  return SongTile(
                    song: songs[i],
                    // Some files tag tracks as 0 rather than leaving it out.
                    trackNumber: widget.isAlbum ? ((songs[i].track ?? 0) > 0 ? songs[i].track : i + 1) : null,
                    rank: widget.ranked ? i + 1 : null,
                    subtitle: widget.isAlbum
                        ? songs[i].artistName
                        : widget.ranked
                        ? '${songs[i].artistName} • ${music.playCount(songs[i])} plays'
                        : null,
                    onTap: () => music.playSongs(songs, index: i),
                  );
                },
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ],
      ),
    );
  }
}

enum _MoreAction { playNext, addToQueue, addToPlaylist, startRadio }

/// Play and Shuffle pills, with the less common actions under ⋮.
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.songs});

  final List<Song> songs;

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final enabled = songs.isNotEmpty;

    void more(_MoreAction action) {
      switch (action) {
        case _MoreAction.playNext:
          music.playAllNext(songs);
          messenger.showSnackBar(const SnackBar(content: Text('Will play next')));
        case _MoreAction.addToQueue:
          music.addAllToQueue(songs);
          messenger.showSnackBar(const SnackBar(content: Text('Added to queue')));
        case _MoreAction.addToPlaylist:
          showAddToPlaylist(context, songs);
        case _MoreAction.startRadio:
          music.startRadio(songs.first);
      }
    }

    return Row(
      children: [
        Expanded(
          child: PillButton(
            label: 'Play',
            icon: Icons.play_arrow_rounded,
            filled: true,
            onPressed: enabled ? () => music.playSongs(songs) : null,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: PillButton(
            label: 'Shuffle',
            icon: Icons.shuffle_rounded,
            onPressed: enabled ? () => music.playSongs(songs, shuffle: true) : null,
          ),
        ),
        PopupMenuButton<_MoreAction>(
          tooltip: 'More',
          enabled: enabled,
          icon: const Icon(Icons.more_vert),
          onSelected: more,
          itemBuilder: (_) => const [
            PopupMenuItem(value: _MoreAction.playNext, child: Text('Play next')),
            PopupMenuItem(value: _MoreAction.addToQueue, child: Text('Add to queue')),
            PopupMenuItem(value: _MoreAction.addToPlaylist, child: Text('Add to playlist')),
            PopupMenuItem(value: _MoreAction.startRadio, child: Text('Start radio')),
          ],
        ),
      ],
    );
  }
}

/// A soft wash of the cover's main color behind a page header, fading into
/// the background. Plain background when there's no cover.
class _TintedHeader extends StatelessWidget {
  const _TintedHeader({required this.songId, required this.child});

  final int? songId;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final id = songId;
    if (id == null) return child;
    return FutureBuilder<Color?>(
      future: MediaLibrary.getDominantColor(id),
      builder: (context, snapshot) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [backdropColor(snapshot.data).withValues(alpha: 0.7), AppColors.background],
          ),
        ),
        child: child,
      ),
    );
  }
}
