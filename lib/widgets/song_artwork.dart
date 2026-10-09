import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/media_library.dart';
import '../theme.dart';

/// A song's embedded cover art, or a placeholder note when it has none.
///
/// [size] null makes it fill its parent as a square. Images are decoded at
/// the size they're shown, which keeps memory and GPU work low on slow phones.
class SongArtwork extends StatefulWidget {
  const SongArtwork({
    super.key,
    required this.songId,
    this.size = 48,
    this.radius = AppRadius.art,
    this.large = false,
  });

  final int songId;
  final double? size;
  final double radius;

  /// Loads a high-resolution image, for the full-screen player.
  final bool large;

  @override
  State<SongArtwork> createState() => _SongArtworkState();
}

class _SongArtworkState extends State<SongArtwork> {
  Uint8List? _bytes;
  ArtworkRequest? _request;

  int get _pixels => widget.large ? MediaLibrary.largeSize : MediaLibrary.thumbnailSize;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SongArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songId != widget.songId || oldWidget.large != widget.large) _load();
  }

  @override
  void dispose() {
    // A row that scrolled away no longer needs its artwork.
    _request?.cancel();
    super.dispose();
  }

  void _load() {
    _request?.cancel();
    _request = null;
    final id = widget.songId, pixels = _pixels;
    if (MediaLibrary.hasCachedArtwork(id, pixels)) {
      _bytes = MediaLibrary.cachedArtwork(id, pixels);
      return;
    }
    // Show the small thumbnail while the large one loads.
    _bytes = widget.large ? MediaLibrary.cachedArtwork(id, MediaLibrary.thumbnailSize) : null;
    final request = _request = MediaLibrary.requestArtwork(id, size: pixels);
    request.future.then((bytes) {
      if (mounted && identical(_request, request)) setState(() => _bytes = bytes);
    });
  }

  /// Decode width in physical pixels, rounded up to a multiple of 64 so
  /// similar sizes share one decoded image in Flutter's image cache.
  int _decodeWidth(double logicalWidth) {
    final pixels = logicalWidth * MediaQuery.devicePixelRatioOf(context);
    return ((pixels / 64).ceil() * 64).clamp(64, _pixels);
  }

  Widget _image(double logicalWidth) {
    final bytes = _bytes;
    if (bytes == null) {
      return const ColoredBox(
        color: AppColors.surfaceHigh,
        child: FractionallySizedBox(
          widthFactor: 0.45,
          heightFactor: 0.45,
          child: FittedBox(child: Icon(Icons.music_note, color: AppColors.textTertiary)),
        ),
      );
    }
    return Image.memory(
      bytes,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      cacheWidth: _decodeWidth(logicalWidth),
      filterQuality: FilterQuality.low,
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final child = size != null
        ? SizedBox.square(dimension: size, child: _image(size))
        : AspectRatio(
            aspectRatio: 1,
            child: LayoutBuilder(builder: (context, constraints) => _image(constraints.maxWidth)),
          );
    if (widget.radius == 0) return child;
    return ClipRRect(borderRadius: BorderRadius.circular(widget.radius), child: child);
  }
}

/// A circular artist picture, using artwork from one of their songs.
class ArtistAvatar extends StatelessWidget {
  const ArtistAvatar({super.key, required this.songId, this.size = 48});

  final int songId;
  final double? size;

  @override
  Widget build(BuildContext context) {
    return ClipOval(child: SongArtwork(songId: songId, size: size, radius: 0));
  }
}

/// Square art for auto playlists, such as the gradient Favourites tile.
class PlaylistArt extends StatelessWidget {
  const PlaylistArt({
    super.key,
    required this.icon,
    required this.colors,
    this.size,
    this.radius = AppRadius.art,
  });

  const PlaylistArt.favourites({super.key, this.size, this.radius = AppRadius.art})
      : icon = Icons.favorite,
        colors = const [Color(0xFFFF6B8B), Color(0xFFB04CD9)];

  const PlaylistArt.recentlyAdded({super.key, this.size, this.radius = AppRadius.art})
      : icon = Icons.new_releases,
        colors = const [Color(0xFFF7B733), Color(0xFFFC4A1A)];

  const PlaylistArt.mostPlayed({super.key, this.size, this.radius = AppRadius.art})
      : icon = Icons.trending_up,
        colors = const [Color(0xFF2DD4BF), Color(0xFF2563EB)];

  const PlaylistArt.history({super.key, this.size, this.radius = AppRadius.art})
      : icon = Icons.history,
        colors = const [Color(0xFF6366F1), Color(0xFF2DD4BF)];

  final IconData icon;
  final List<Color> colors;
  final double? size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final tile = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      child: FractionallySizedBox(
        widthFactor: 0.4,
        heightFactor: 0.4,
        child: FittedBox(child: Icon(icon, color: Colors.white)),
      ),
    );
    return size == null
        ? AspectRatio(aspectRatio: 1, child: tile)
        : SizedBox.square(dimension: size, child: tile);
  }
}
