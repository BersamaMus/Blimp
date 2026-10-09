import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../services/media_library.dart';
import 'song_tile.dart';

/// Songs laid out in columns of [rows] songs, one column across the screen
/// with the next peeking in at the edge, swiped sideways to see the others.
/// A wide window shows several columns side by side, each kept to
/// [_maxColumnWidth]. As Quick picks on Home.
class SongPager extends StatefulWidget {
  const SongPager({
    super.key,
    required this.songs,
    required this.onTap,
    this.subtitleOf,
    this.showFavourite = false,
  });

  final List<Song> songs;

  /// Called with the tapped song's place in [songs].
  final FutureOr<void> Function(int index) onTap;

  /// Each song's subtitle; SongTile's default without it.
  final String? Function(Song song)? subtitleOf;
  final bool showFavourite;

  static const rows = 5;
  static const columns = 3;

  /// How many songs a pager shows at most.
  static const shown = rows * columns;

  /// A song row's height: its 52 px artwork and 8 px above and below.
  static const _rowHeight = 68.0;

  /// So a wide window doesn't stretch a column's titles far from its buttons.
  static const _maxColumnWidth = 520.0;

  @override
  State<SongPager> createState() => _SongPagerState();
}

class _SongPagerState extends State<SongPager> {
  // A little under the full width, so the next column shows it's there.
  // Narrower in a wide window, and remade when the width changes.
  PageController _controller = PageController(viewportFraction: 0.9);

  PageController _controllerFor(double width) {
    final fraction = min(0.9, SongPager._maxColumnWidth / width);
    if (fraction != _controller.viewportFraction) {
      // No page yet before its first layout.
      final page = _controller.hasClients ? _controller.page?.round() ?? _controller.initialPage : 0;
      final old = _controller;
      // Once the PageView has let go of it.
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      _controller = PageController(viewportFraction: fraction, initialPage: page);
    }
    return _controller;
  }

  @override
  void didUpdateWidget(SongPager old) {
    super.didUpdateWidget(old);
    // A fresh set of songs starts from its first column.
    if (old.songs.firstOrNull != widget.songs.firstOrNull && _controller.hasClients) {
      _controller.jumpToPage(0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final songs = widget.songs;
    // Fewer songs than a column's worth take only the rows they need.
    final rows = min(SongPager.rows, songs.length);
    final columns = (songs.length / SongPager.rows).ceil();
    final rowHeight = MediaQuery.textScalerOf(context).scale(SongPager._rowHeight);

    return SizedBox(
      height: rowHeight * rows,
      child: LayoutBuilder(
        builder: (context, constraints) => PageView.builder(
          controller: _controllerFor(constraints.maxWidth),
          padEnds: false,
          itemCount: columns,
          itemBuilder: (context, column) => Column(
            children: [
              for (var i = column * SongPager.rows; i < min(songs.length, (column + 1) * SongPager.rows); i++)
                SizedBox(
                  height: rowHeight,
                  child: SongTile(
                    song: songs[i],
                    subtitle: widget.subtitleOf?.call(songs[i]),
                    showFavourite: widget.showFavourite,
                    onTap: () => widget.onTap(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
