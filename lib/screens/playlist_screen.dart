import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/device_files.dart';
import '../services/m3u.dart';
import '../services/music_controller.dart';
import '../services/playlists.dart';
import '../theme.dart';
import '../widgets/add_to_playlist.dart';
import '../widgets/shelf.dart';
import '../widgets/song_tile.dart';

enum _Action { rename, export, delete }

/// A playlist the user made. Songs can be dragged into a new order by their
/// handles, or swiped away.
class PlaylistScreen extends StatelessWidget {
  const PlaylistScreen({super.key, required this.playlistId});

  /// Looked up on each build, so the page follows renames.
  final String playlistId;

  Future<void> _onAction(BuildContext context, Playlist playlist, _Action action) async {
    final music = MusicScope.read(context);
    switch (action) {
      case _Action.rename:
        final name = await askPlaylistName(
          context,
          title: 'Rename playlist',
          action: 'Rename',
          initial: playlist.name,
        );
        if (name != null) music.renamePlaylist(playlist, name);
      case _Action.export:
        final messenger = ScaffoldMessenger.of(context);
        final songs = music.playlistSongs(playlist);
        // A file name every system takes.
        final name = playlist.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        try {
          final saved = await DeviceFiles.save('$name.m3u8', 'audio/x-mpegurl', utf8.encode(M3u.encode(songs)));
          if (saved) messenger.showSnackBar(SnackBar(content: Text('Exported ${playlist.name}')));
        } on PlatformException {
          messenger.showSnackBar(const SnackBar(content: Text("Couldn't save it there. Try another folder.")));
        }
      case _Action.delete:
        final messenger = ScaffoldMessenger.of(context);
        final index = music.playlists.indexOf(playlist);
        Navigator.pop(context);
        music.deletePlaylist(playlist);
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text('Deleted ${playlist.name}'),
            // Goes away on its own like other messages, despite the action.
            persist: false,
            action: SnackBarAction(label: 'Undo', onPressed: () => music.restorePlaylist(playlist, index)),
          ));
    }
  }

  void _remove(BuildContext context, Playlist playlist, int index) {
    final music = MusicScope.read(context);
    final song = music.removeFromPlaylist(playlist, index);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Removed ${song.title}'),
        // Goes away on its own like other messages, despite the action.
        persist: false,
        action: SnackBarAction(label: 'Undo', onPressed: () => music.insertIntoPlaylist(playlist, index, song)),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.playlists, MusicAspect.library});
    final playlist = music.playlistWithId(playlistId);
    if (playlist == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const MessageView(icon: Icons.playlist_remove_rounded, text: 'This playlist was deleted.'),
      );
    }
    final songs = music.playlistSongs(playlist);
    final textTheme = Theme.of(context).textTheme;
    final artSize = (MediaQuery.sizeOf(context).width * 0.36).clamp(120.0, 180.0);

    return Scaffold(
      appBar: AppBar(
        actions: [
          PopupMenuButton<_Action>(
            tooltip: 'More',
            onSelected: (action) => _onAction(context, playlist, action),
            itemBuilder: (_) => const [
              PopupMenuItem(value: _Action.rename, child: Text('Rename')),
              PopupMenuItem(value: _Action.export, child: Text('Export as M3U')),
              PopupMenuItem(value: _Action.delete, child: Text('Delete playlist')),
            ],
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      SizedBox.square(dimension: artSize, child: PlaylistCover(playlist: playlist, radius: AppRadius.card)),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('PLAYLIST',
                                style: textTheme.labelSmall?.copyWith(color: AppColors.accent, letterSpacing: 1.2)),
                            const SizedBox(height: 4),
                            Text(playlist.name, maxLines: 3, overflow: TextOverflow.ellipsis, style: textTheme.headlineSmall),
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
                  Row(
                    children: [
                      Expanded(
                        child: PillButton(
                          label: 'Play',
                          icon: Icons.play_arrow_rounded,
                          filled: true,
                          onPressed: songs.isEmpty ? null : () => music.playSongs(songs),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: PillButton(
                          label: 'Shuffle',
                          icon: Icons.shuffle_rounded,
                          onPressed: songs.isEmpty ? null : () => music.playSongs(songs, shuffle: true),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (songs.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  "No songs yet.\nAdd some from any song's ⋮ menu, or an album's.",
                  textAlign: TextAlign.center,
                  style: textTheme.bodyLarge,
                ),
              ),
            )
          else
            SliverReorderableList(
              itemCount: songs.length,
              onReorderItem: (from, to) => music.movePlaylistSong(playlist, from, to),
              proxyDecorator: (child, _, _) => Material(color: AppColors.surfaceHigh, elevation: 6, child: child),
              itemBuilder: (context, i) => Dismissible(
                key: ValueKey(songs[i].id),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: AppColors.danger,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 24),
                  child: const Icon(Icons.remove_circle_outline_rounded, color: Colors.white),
                ),
                onDismissed: (_) => _remove(context, playlist, i),
                child: Row(
                  children: [
                    Expanded(
                      child: SongTile(song: songs[i], onTap: () => music.playSongs(songs, index: i)),
                    ),
                    ReorderableDragStartListener(
                      index: i,
                      child: const Padding(
                        padding: EdgeInsets.fromLTRB(0, 16, 16, 16),
                        child: Icon(Icons.drag_handle_rounded, color: AppColors.textTertiary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}
