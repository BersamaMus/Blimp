import 'package:flutter/material.dart';

import '../screens/app_shell.dart';
import '../screens/collection_screen.dart';
import '../services/music_controller.dart';
import '../theme.dart';
import 'shelf.dart';
import 'song_artwork.dart';

class AlbumCard extends StatelessWidget {
  const AlbumCard({super.key, required this.album, this.width = 160, this.subtitle});

  final Album album;
  final double width;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return MediaCard(
      width: width,
      art: SongArtwork(songId: album.cover.id, size: null, radius: AppRadius.card),
      title: album.title,
      subtitle: subtitle ?? '${album.kind} • ${album.artist}',
      hiRes: MusicScope.of(context, const {MusicAspect.library}).isAlbumHiRes(album),
      onTap: () => openPage(CollectionScreen.album(album)),
    );
  }
}
