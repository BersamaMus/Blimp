import 'media_library.dart';
import 'search_text.dart';

/// How far apart two copies' lengths can be and still be the same recording:
/// encoders pad the ends a little differently.
const _lengthTolerance = Duration(seconds: 3);

/// Songs that look like copies of each other: the same title and artist
/// (ignoring case, accents and punctuation) and about the same length. Each
/// group has at least two songs, best copy first; groups are by title.
List<List<Song>> findDuplicates(List<Song> songs) {
  final byName = <String, List<Song>>{};
  for (final song in songs) {
    byName.putIfAbsent('${_simplify(song.title)}|${_simplify(song.artistName)}', () => []).add(song);
  }
  final groups = <List<Song>>[];
  for (final same in byName.values) {
    if (same.length < 2) continue;
    // Runs of close lengths; a live take and the studio one stay apart.
    // A length Android doesn't know goes with whatever's beside it.
    same.sort((a, b) => _length(a).compareTo(_length(b)));
    var run = <Song>[same.first];
    for (final song in same.skip(1)) {
      final known = _length(song) > Duration.zero && _length(run.last) > Duration.zero;
      if (known && _length(song) - _length(run.last) > _lengthTolerance) {
        if (run.length > 1) groups.add(run);
        run = [song];
      } else {
        run.add(song);
      }
    }
    if (run.length > 1) groups.add(run);
  }
  for (final group in groups) {
    group.sort((a, b) => quality(b).compareTo(quality(a)));
  }
  return groups..sort((a, b) => a.first.searchFields.first.compareTo(b.first.searchFields.first));
}

/// Bytes per second of audio: a fair stand-in for quality between copies of
/// one song, as lossless and higher bitrates take more room.
double quality(Song song) {
  final seconds = _length(song).inMilliseconds / 1000;
  return seconds <= 0 ? song.size.toDouble() : song.size / seconds;
}

Duration _length(Song song) => song.duration ?? Duration.zero;

/// Letters and digits only, as search compares them.
String _simplify(String text) => searchKey(text).replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');
