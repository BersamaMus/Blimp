import 'media_library.dart';

/// Where long listens were left off, so they carry on from there: podcasts,
/// audiobooks, and anything else long enough that starting over hurts.
class ResumePoints {
  ResumePoints([Map<int, Duration>? positions]) : _positions = positions ?? {};

  /// Songs this long resume too, whatever Android says they are: DJ mixes,
  /// lectures, live sets.
  static const longSong = Duration(minutes: 30);

  /// Positions nearer the start than this aren't worth resuming from.
  static const _minimum = Duration(seconds: 15);

  /// Positions nearer the end than this count as finished.
  static const _tail = Duration(seconds: 30);

  final Map<int, Duration> _positions;

  static bool isResumable(Song song) => song.spoken || (song.duration ?? Duration.zero) >= longSong;

  /// Where [song] was left off, if it's partway through.
  Duration? of(Song song) => _positions[song.id];

  /// How far through [song] is, 0..1, if it's partway through.
  double? progressOf(Song song) {
    final at = _positions[song.id], length = song.duration;
    if (at == null || length == null || length <= Duration.zero) return null;
    return (at.inMilliseconds / length.inMilliseconds).clamp(0.0, 1.0);
  }

  /// Remembers [position] in [song]; forgets it if it's barely started or
  /// as good as finished. Returns whether anything changed.
  bool save(Song song, Duration position) {
    if (!isResumable(song)) return false;
    final length = song.duration ?? Duration.zero;
    final finished = length > Duration.zero && position >= length - _tail;
    if (position < _minimum || finished) return _positions.remove(song.id) != null;
    final before = _positions[song.id];
    _positions[song.id] = position;
    return before == null || (before - position).abs() >= const Duration(seconds: 1);
  }

  /// For saving: "id:milliseconds" entries.
  List<String> encode() => [
    for (final MapEntry(:key, :value) in _positions.entries) '$key:${value.inMilliseconds}',
  ];

  static ResumePoints decode(List<String>? entries) => ResumePoints({
    for (final entry in entries ?? const <String>[])
      if (entry.split(':') case [final id, final ms])
        if ((int.tryParse(id), int.tryParse(ms)) case (final int id, final int ms)) id: Duration(milliseconds: ms),
  });
}
