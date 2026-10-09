import 'package:flutter/material.dart';

import '../services/media_library.dart';
import '../services/music_controller.dart';
import '../services/playlists.dart';
import '../theme.dart';
import 'shelf.dart';
import 'song_artwork.dart';

/// Asks for a playlist's name; null if cancelled.
Future<String?> askPlaylistName(
  BuildContext context, {
  String title = 'New playlist',
  String action = 'Create',
  String initial = '',
}) {
  return showDialog<String>(
    context: context,
    useRootNavigator: true,
    builder: (_) => _NameDialog(title: title, action: action, initial: initial),
  );
}

/// Owns its text field's controller, so it's only disposed once the dialog
/// has finished closing; the closing animation still draws the field.
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.action, required this.initial});

  final String title;
  final String action;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.sheet,
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'Playlist name'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ListenableBuilder(
          listenable: _controller,
          builder: (_, _) => TextButton(
            onPressed: _controller.text.trim().isEmpty ? null : _submit,
            child: Text(widget.action),
          ),
        ),
      ],
    );
  }
}

/// Picks a playlist (or makes a new one) to add [songs] to, and says how
/// it went.
Future<void> showAddToPlaylist(BuildContext context, List<Song> songs) async {
  final music = MusicScope.read(context);
  final messenger = ScaffoldMessenger.of(context);
  void say(String message) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  // null for a new playlist.
  final picked = await showModalBottomSheet<({Playlist? playlist})>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (sheetContext) => _PlaylistPicker(songs: songs),
  );
  if (picked == null || !context.mounted) return;

  if (picked.playlist case final playlist?) {
    final added = music.addToPlaylist(playlist, songs);
    say(switch (added) {
      0 => songs.length == 1 ? 'Already in ${playlist.name}' : 'All already in ${playlist.name}',
      _ when added == songs.length => 'Added to ${playlist.name}',
      _ => 'Added $added new to ${playlist.name}',
    });
  } else {
    final name = await askPlaylistName(context);
    if (name == null) return;
    music.createPlaylist(name, songs);
    say('Added to $name');
  }
}

class _PlaylistPicker extends StatelessWidget {
  const _PlaylistPicker({required this.songs});

  final List<Song> songs;

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.playlists, MusicAspect.library});
    final textTheme = Theme.of(context).textTheme;
    final ids = {for (final s in songs) s.id};
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Add to playlist', style: textTheme.titleMedium),
            ),
            ListTile(
              leading: const SizedBox.square(
                dimension: 48,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: AppColors.surfaceHigh, shape: BoxShape.circle),
                  child: Icon(Icons.add_rounded),
                ),
              ),
              title: Text('New playlist', style: textTheme.bodyLarge),
              onTap: () => Navigator.pop(context, (playlist: null)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final playlist in music.playlists)
                    ListTile(
                      leading: SizedBox.square(dimension: 48, child: PlaylistCover(playlist: playlist)),
                      title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodyLarge),
                      subtitle: Text(describeLength(music.playlistSongs(playlist).length, Duration.zero)),
                      // Already holding everything being added.
                      trailing: ids.every(playlist.songIds.contains)
                          ? const Icon(Icons.check_rounded, color: AppColors.textSecondary)
                          : null,
                      onTap: () => Navigator.pop(context, (playlist: playlist)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// A playlist's art: its first song's cover, or a plain tile while empty.
class PlaylistCover extends StatelessWidget {
  const PlaylistCover({super.key, required this.playlist, this.radius = AppRadius.art});

  final Playlist playlist;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final songs = MusicScope.read(context).playlistSongs(playlist);
    if (songs.isNotEmpty) return SongArtwork(songId: songs.first.id, size: null, radius: radius);
    return AspectRatio(
      aspectRatio: 1,
      child: DecoratedBox(
        decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(radius)),
        child: const FractionallySizedBox(
          widthFactor: 0.45,
          heightFactor: 0.45,
          child: FittedBox(child: Icon(Icons.queue_music_rounded, color: AppColors.textSecondary)),
        ),
      ),
    );
  }
}
