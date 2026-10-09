import 'package:flutter/material.dart';

import '../screens/app_shell.dart';
import '../screens/artist_screen.dart';
import '../screens/collection_screen.dart';
import '../screens/folder_screen.dart';
import '../services/desktop_library.dart';
import '../services/media_library.dart';
import '../services/music_controller.dart';
import '../theme.dart';
import 'add_to_playlist.dart';
import 'shelf.dart';
import 'song_artwork.dart';
import 'song_details.dart';

/// The bottom sheet opened from a song's ⋮ button or by long-pressing it.
///
/// The player's own menu ([inPlayer]) leaves out what's about queueing the
/// song, since it's already playing.
Future<void> showSongOptions(BuildContext context, Song song, {bool inPlayer = false}) {
  final music = MusicScope.read(context);
  final messenger = ScaffoldMessenger.of(context);
  final album = music.albumOf(song);
  final artists = music.artistsOf(song);

  void done(BuildContext sheetContext, [String? message]) {
    Navigator.pop(sheetContext);
    if (message != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  return showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (sheetContext) => ListenableBuilder(
      listenable: music,
      builder: (sheetContext, _) {
        final favourite = music.isFavourite(song);
        return SafeArea(
          // Scrolls on short screens, and in landscape.
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 12),
                  child: Row(
                    children: [
                      SongArtwork(songId: song.id, size: 48),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(sheetContext).textTheme.titleMedium,
                            ),
                            HiResLine(
                              hiRes: music.isHiRes(song),
                              line: Text(
                                song.artistName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(sheetContext).textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: favourite ? 'Remove from Favourites' : 'Add to Favourites',
                        icon: Icon(favourite ? Icons.favorite : Icons.favorite_border),
                        color: favourite ? AppColors.favourite : null,
                        onPressed: () => music.toggleFavourite(song),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                if (!inPlayer) ...[
                  _Option(
                    icon: Icons.sensors,
                    label: 'Start radio',
                    onTap: () {
                      done(sheetContext);
                      music.startRadio(song);
                    },
                  ),
                  _Option(
                    icon: Icons.playlist_play,
                    label: 'Play next',
                    onTap: () {
                      done(sheetContext, 'Song will play next');
                      music.playNext(song);
                    },
                  ),
                  _Option(
                    icon: Icons.queue_music,
                    label: 'Add to queue',
                    onTap: () {
                      done(sheetContext, 'Song added to queue');
                      music.addToQueue(song);
                    },
                  ),
                  _Option(
                    icon: favourite ? Icons.heart_broken_outlined : Icons.favorite_border,
                    label: favourite ? 'Remove from Favourites' : 'Add to Favourites',
                    onTap: () {
                      done(sheetContext, favourite ? 'Removed from Favourites' : 'Added to Favourites');
                      music.toggleFavourite(song);
                    },
                  ),
                ],
                _Option(
                  icon: Icons.playlist_add_rounded,
                  label: 'Add to playlist',
                  onTap: () {
                    done(sheetContext);
                    showAddToPlaylist(context, [song]);
                  },
                ),
                if (album != null && !album.isSingle)
                  _Option(
                    icon: Icons.album_outlined,
                    label: 'Go to album',
                    onTap: () {
                      done(sheetContext);
                      openPage(CollectionScreen.album(album));
                    },
                  ),
                if (artists.isNotEmpty)
                  _Option(
                    icon: Icons.person_outline,
                    label: artists.length == 1 ? 'Go to artist' : 'Go to artists',
                    onTap: () {
                      done(sheetContext);
                      openArtists(context, artists);
                    },
                  ),
                if (music.folderAt(song.folder) != null)
                  _Option(
                    icon: Icons.folder_outlined,
                    label: 'Go to folder',
                    onTap: () {
                      done(sheetContext);
                      openRoute(folderRoute(song.folder!, highlight: song));
                    },
                  ),
                if (inPlayer)
                  _Option(
                    icon: Icons.speed_rounded,
                    label: 'Playback speed • ${formatSpeed(music.speed)}',
                    onTap: () {
                      done(sheetContext);
                      showSpeedPicker(context);
                    },
                  ),
                // Desktop has no share sheet.
                if (!isDesktop)
                  _Option(
                    icon: Icons.share_outlined,
                    label: 'Share',
                    onTap: () {
                      done(sheetContext);
                      MediaLibrary.shareSong(song);
                    },
                  ),
                _Option(
                  icon: Icons.info_outline,
                  label: 'Details',
                  onTap: () {
                    done(sheetContext);
                    showSongDetails(context, song);
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _Option extends StatelessWidget {
  const _Option({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppColors.textSecondary),
      title: Text(label, style: Theme.of(context).textTheme.bodyLarge),
      onTap: onTap,
    );
  }
}

/// "1×", "1.25×".
String formatSpeed(double speed) =>
    '${speed == speed.roundToDouble() ? speed.round() : speed.toString().replaceAll(RegExp(r'0+$'), '')}×';

/// Picks how fast songs play.
Future<void> showSpeedPicker(BuildContext context) {
  final music = MusicScope.read(context);
  return showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: RadioGroup<double>(
          groupValue: music.speed,
          onChanged: (speed) {
            if (speed != null) music.setSpeed(speed);
            Navigator.pop(sheetContext);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text('Playback speed', style: Theme.of(sheetContext).textTheme.titleMedium),
              ),
              for (final speed in MusicController.speedOptions)
                RadioListTile<double>(value: speed, title: Text(speed == 1 ? 'Normal' : formatSpeed(speed))),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    ),
  );
}
