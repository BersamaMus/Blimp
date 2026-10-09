import 'dart:math';

import 'package:just_audio/just_audio.dart';

/// just_audio's shuffle order, except that autoplay's songs stay after the
/// user's: songs added to the end of the queue stay at the end in shuffle
/// mode too (shuffled among themselves), and shuffling keeps autoplay's
/// songs last.
class QueueShuffleOrder extends DefaultShuffleOrder {
  QueueShuffleOrder({required this.isAutoplay});

  /// Whether the queue item at this index was added by autoplay.
  final bool Function(int index) isAutoplay;

  final _random = Random();

  /// Where in the order songs inserted at queue index `index` go, together
  /// and in order; see MusicController._placeInShuffle. Tied to the index,
  /// since just_audio inserts later, after any queue changes before it.
  ({int index, int position})? insertAt;

  @override
  void insert(int index, int count) {
    final at = insertAt?.index == index ? insertAt!.position : null;
    if (at != null) insertAt = null;
    final added = List.generate(count, (i) => index + i);
    if (at == null && index >= indices.length) return indices.addAll(added..shuffle(_random));
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= index) indices[i] += count;
    }
    // Without a place, at the end: never among the songs already played. (Not
    // shuffled, the order only matters once shuffle redoes it anyway.)
    indices.insertAll((at ?? indices.length).clamp(0, indices.length), added);
  }

  /// A move for the next [shuffle] to make instead of shuffling, in places in
  /// play order (see MusicController.moveInQueue).
  ({int from, int to})? pendingMove;

  /// The playing song first, then the user's songs, then autoplay's.
  @override
  void shuffle({int? initialIndex}) {
    if (pendingMove case (:final from, :final to)) {
      pendingMove = null;
      if (from < indices.length && to < indices.length) indices.insert(to, indices.removeAt(from));
      return;
    }
    final rest = [for (final i in indices) if (i != initialIndex) i];
    final own = [for (final i in rest) if (!isAutoplay(i)) i]..shuffle(_random);
    final autoplay = [for (final i in rest) if (isAutoplay(i)) i]..shuffle(_random);
    indices
      ..clear()
      ..addAll([?initialIndex, ...own, ...autoplay]);
  }
}
