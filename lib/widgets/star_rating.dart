import 'package:flutter/material.dart';

import '../services/media_library.dart';
import '../services/music_controller.dart';
import '../theme.dart';

/// A song's rating as five stars to tap. Tapping the rating it already has
/// takes it away.
class StarRating extends StatelessWidget {
  const StarRating({super.key, required this.song, this.size = 28});

  final Song song;
  final double size;

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.favourites});
    final stars = music.rating(song);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: i == stars ? 'Clear rating' : '$i ${i == 1 ? 'star' : 'stars'}',
            iconSize: size,
            color: i <= stars ? AppColors.accent : AppColors.textTertiary,
            icon: Icon(i <= stars ? Icons.star_rounded : Icons.star_outline_rounded),
            onPressed: () => music.setRating(song, i == stars ? 0 : i),
          ),
      ],
    );
  }
}
