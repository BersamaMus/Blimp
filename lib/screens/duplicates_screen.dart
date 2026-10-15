import 'package:flutter/material.dart';

import '../services/desktop_library.dart';
import '../services/duplicates.dart';
import '../services/media_library.dart';
import '../services/music_controller.dart';
import '../theme.dart';
import '../widgets/shelf.dart';
import '../widgets/song_artwork.dart';

/// Songs that are on the device more than once, such as the same song as an
/// MP3 and a FLAC, with a way to throw the extra copies away.
class DuplicatesScreen extends StatefulWidget {
  const DuplicatesScreen({super.key});

  @override
  State<DuplicatesScreen> createState() => _DuplicatesScreenState();
}

class _DuplicatesScreenState extends State<DuplicatesScreen> {
  /// Songs being thrown away, whose rows show as busy.
  final _removing = <int>{};

  static final _bin = isDesktop ? 'Recycle Bin' : 'trash';

  /// The groups, and the library they were found in: grouping is the whole
  /// library's work, so it's only done again when the library changes.
  List<Song>? _groupedFrom;
  List<List<Song>> _groups = const [];

  /// Each copy's format, looked up once.
  final _formats = <int, Future<AudioFormat?>>{};

  Future<void> _remove(Song song, List<Song> group) async {
    final messenger = ScaffoldMessenger.of(context);
    final music = MusicScope.read(context);
    final kept = group.firstWhere((s) => s != song);
    final sure = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        title: const Text('Remove this copy?'),
        content: Text(
          '${song.fileName ?? song.title} goes to the $_bin. '
          'Its plays, rating and places in your playlists move to the copy you keep.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _removing.add(song.id));
    final done = await MediaLibrary.trashSongs([song]);
    if (done) {
      music.mergeSongInto(song, kept);
      await music.load();
    }
    if (!mounted) return;
    setState(() => _removing.remove(song.id));
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(done ? 'Moved to the $_bin' : "Couldn't remove ${song.fileName ?? song.title}")),
      );
  }

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.library});
    if (!identical(music.songs, _groupedFrom)) {
      _groupedFrom = music.songs;
      _groups = findDuplicates(music.songs);
    }
    final groups = _groups;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Duplicate songs')),
      body: groups.isEmpty
          ? const MessageView(icon: Icons.done_all_rounded, text: 'No duplicates found.')
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: groups.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Text(
                      '${groups.length} ${groups.length == 1 ? 'song is' : 'songs are'} here more than once: '
                      'same title, artist and length. The copy with the most detail is listed first.',
                      style: textTheme.bodyMedium,
                    ),
                  );
                }
                final group = groups[i - 1];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ShelfHeader(title: group.first.title),
                    for (final (j, song) in group.indexed)
                      _CopyTile(
                        song: song,
                        format: _formats.putIfAbsent(song.id, () => MediaLibrary.getAudioFormat(song)),
                        best: j == 0,
                        busy: _removing.contains(song.id),
                        onRemove: () => _remove(song, group),
                      ),
                  ],
                );
              },
            ),
    );
  }
}

/// One copy of a song: its format, file and size, and a button to remove it.
class _CopyTile extends StatelessWidget {
  const _CopyTile({
    required this.song,
    required this.format,
    required this.best,
    required this.busy,
    required this.onRemove,
  });

  final Song song;
  final Future<AudioFormat?> format;
  final bool best;
  final bool busy;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.read(context);
    final textTheme = Theme.of(context).textTheme;
    return ListTile(
      leading: SongArtwork(songId: song.id, size: 48, radius: 10),
      onTap: () => music.playSongs([song]),
      title: FutureBuilder<AudioFormat?>(
        future: format,
        builder: (context, snapshot) => Row(
          children: [
            Flexible(
              child: Text(
                [song.artistName, ?snapshot.data?.label].join(' • '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (best) ...[
              const SizedBox(width: 8),
              Text('BEST', style: textTheme.labelSmall?.copyWith(color: AppColors.accent, letterSpacing: 1.2)),
            ],
          ],
        ),
      ),
      subtitle: Text(
        [?(song.path ?? song.fileName), formatBytes(song.size)].join(' • '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: busy
          ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : IconButton(
              tooltip: 'Remove this copy',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: onRemove,
            ),
    );
  }
}
