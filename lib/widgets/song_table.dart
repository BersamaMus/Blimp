import 'package:flutter/material.dart';

import '../screens/now_playing_screen.dart';
import '../services/media_library.dart';
import '../services/music_controller.dart';
import '../theme.dart';
import 'shelf.dart';
import 'song_artwork.dart';
import 'song_options.dart';
import 'song_tile.dart';

/// What a [SongTableHeader] can sort songs by.
enum SongColumn {
  title('Title'),
  artist('Artist'),
  album('Album'),
  length('Length');

  const SongColumn(this.label);
  final String label;

  /// Compares two songs by this column, ascending.
  int compare(Song a, Song b) => switch (this) {
    title => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    artist => a.artistName.toLowerCase().compareTo(b.artistName.toLowerCase()),
    album => (a.album ?? '').toLowerCase().compareTo((b.album ?? '').toLowerCase()),
    length => (a.duration ?? Duration.zero).compareTo(b.duration ?? Duration.zero),
  };
}

/// The widths shared by the header and its rows, so the columns line up.
const _artWidth = 40.0, _artGap = 16.0, _lengthWidth = 56.0, _menuWidth = 48.0;
const _titleFlex = 5, _artistFlex = 4, _albumFlex = 4;
const _rowPadding = EdgeInsets.fromLTRB(20, 0, 8, 0);

/// The column names over a [SongTableRow] list, each sorting by it when
/// clicked, and the other way when clicked again.
class SongTableHeader extends StatelessWidget {
  const SongTableHeader({super.key, required this.sortedBy, required this.descending, required this.onSort});

  final SongColumn? sortedBy;
  final bool descending;
  final ValueChanged<SongColumn> onSort;

  static const height = 40.0;

  @override
  Widget build(BuildContext context) {
    Widget cell(SongColumn column, {bool end = false}) {
      final sorted = column == sortedBy;
      final color = sorted ? AppColors.accent : AppColors.textSecondary;
      return Align(
        alignment: end ? Alignment.centerRight : Alignment.centerLeft,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => onSort(column),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(column.label, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: color)),
                if (sorted) ...[
                  const SizedBox(width: 2),
                  Icon(descending ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded, size: 14, color: color),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      height: height,
      padding: _rowPadding,
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          // Lined up with the text, not the artwork.
          const SizedBox(width: _artWidth + _artGap - 4),
          Expanded(flex: _titleFlex, child: cell(SongColumn.title)),
          Expanded(flex: _artistFlex, child: cell(SongColumn.artist)),
          Expanded(flex: _albumFlex, child: cell(SongColumn.album)),
          SizedBox(width: _lengthWidth, child: cell(SongColumn.length, end: true)),
          const SizedBox(width: _menuWidth),
        ],
      ),
    );
  }
}

/// A song as one line of a table, for a wide window: title, artist, album and
/// length in columns. Plays on a click; a right-click or the menu button
/// shows its options.
class SongTableRow extends StatelessWidget {
  const SongTableRow({super.key, required this.song, required this.onTap});

  final Song song;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.playback, MusicAspect.library});
    final isCurrent = music.currentSong == song;
    final textTheme = Theme.of(context).textTheme;

    Widget cell(String text, int flex) => Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.only(right: 16),
        child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodyMedium),
      ),
    );

    return Material(
      color: isCurrent ? AppColors.accentFaint : Colors.transparent,
      child: InkWell(
        onTap: () => playAndOpen(context, onTap),
        onLongPress: () => showSongOptions(context, song),
        onSecondaryTap: () => showSongOptions(context, song),
        child: Padding(
          padding: _rowPadding.copyWith(top: 6, bottom: 6),
          child: Row(
            children: [
              SongArtwork(songId: song.id, size: _artWidth, radius: 8),
              const SizedBox(width: _artGap),
              Expanded(
                flex: _titleFlex,
                child: Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodyLarge?.copyWith(color: isCurrent ? AppColors.accent : null),
                        ),
                      ),
                      if (music.isHiRes(song)) ...[const SizedBox(width: 8), const HiResBadge()],
                      if (isCurrent) ...[const SizedBox(width: 8), const PlayingIndicator(size: 14)],
                    ],
                  ),
                ),
              ),
              cell(song.artistName, _artistFlex),
              cell(song.album ?? '', _albumFlex),
              SizedBox(
                width: _lengthWidth,
                child: Text(
                  song.duration == null ? '' : formatDuration(song.duration!),
                  textAlign: TextAlign.end,
                  style: textTheme.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
              SizedBox(
                width: _menuWidth,
                child: IconButton(
                  tooltip: 'More',
                  icon: const Icon(Icons.more_vert),
                  color: AppColors.textSecondary,
                  onPressed: () => showSongOptions(context, song),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Keeps a [SongTableHeader] at the top of the list as it scrolls.
class SongTableHeaderDelegate extends SliverPersistentHeaderDelegate {
  SongTableHeaderDelegate(this.header);

  final SongTableHeader header;

  @override
  double get minExtent => SongTableHeader.height;

  @override
  double get maxExtent => SongTableHeader.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => header;

  @override
  bool shouldRebuild(SongTableHeaderDelegate old) =>
      old.header.sortedBy != header.sortedBy || old.header.descending != header.descending;
}
