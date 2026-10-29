import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

import 'lyrics.dart';
import 'media_library.dart';
import 'search_text.dart';

/// Every song's lyrics, read once and kept in a file in the app's support
/// folder, so search can look through them all: "highway to" finds the
/// song, and the line it's on. Not in backups: it's read afresh from the
/// files on another device.
class LyricsIndex {
  LyricsIndex(this._file);

  final File? _file;

  /// By song id, with the stamp of the files they were read from (see
  /// [MediaLibrary.lyricsStamps]), so a changed song or .lrc file is read
  /// again. No lines: a song without lyrics.
  Map<int, ({String stamp, SongLyrics lyrics})> _songs = {};

  static const _version = 2;

  static Future<LyricsIndex> open() async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/lyrics_index.json');
    final index = LyricsIndex(file);
    try {
      final text = await file.readAsString();
      // Away from the screen's thread: the file can be a few megabytes.
      index._songs = await Isolate.run(() => _decode(text));
    } on Object {
      // Nothing read yet, or an unreadable file: start afresh.
    }
    return index;
  }

  /// Whether [song]'s lyrics have been read, from its files as [stamp] says
  /// they are now.
  bool has(Song song, String stamp) => _songs[song.id]?.stamp == stamp;

  /// [song]'s lyrics as last read; null if they haven't been, or it has none.
  SongLyrics? of(Song song) => switch (_songs[song.id]) {
    (:final lyrics, stamp: _) when lyrics.lines.isNotEmpty => lyrics,
    _ => null,
  };

  void put(Song song, String stamp, SongLyrics lyrics) => _songs[song.id] = (stamp: stamp, lyrics: lyrics);

  /// Forgets songs not among [ids] (deleted, say), returning whether there
  /// were any, so the file doesn't keep growing.
  bool keepOnly(Set<int> ids) {
    final before = _songs.length;
    _songs.removeWhere((id, _) => !ids.contains(id));
    return _songs.length != before;
  }

  /// Each of [texts]' lyrics, by song id, ready to search. Worked out away
  /// from the screen's thread, as there can be thousands of lines.
  static Future<Map<int, SongLyrics>> parse(Map<int, String?> texts) => Isolate.run(() => {
    for (final MapEntry(:key, :value) in texts.entries) key: SongLyrics.of(value == null ? null : parseLyrics(value)),
  });

  String encode() => _encode(_songs);

  void decode(String text) => _songs = _decode(text);

  static String _encode(Map<int, ({String stamp, SongLyrics lyrics})> songs) => jsonEncode({
    'version': _version,
    'songs': {
      for (final MapEntry(:key, :value) in songs.entries)
        '$key': [
          value.stamp,
          for (final line in value.lyrics.lines) [line.time?.inMilliseconds ?? -1, line.text],
        ],
    },
  });

  static Map<int, ({String stamp, SongLyrics lyrics})> _decode(String text) {
    final json = jsonDecode(text) as Map<String, Object?>;
    if (json['version'] != _version) return {};
    return {
      for (final MapEntry(:key, :value) in (json['songs'] as Map<String, Object?>).entries)
        if ((int.tryParse(key), value) case (final int id, [final String stamp, ...final lines]))
          id: (
            stamp: stamp,
            lyrics: SongLyrics([
              for (final line in lines)
                if (line case [final int ms, final String text])
                  LyricLine(text, ms < 0 ? null : Duration(milliseconds: ms)),
            ]),
          ),
    };
  }

  Future<void> save() async {
    final file = _file;
    if (file == null) return;
    final songs = _songs;
    // Written beside, then swapped in, so a crash midway loses nothing. Away
    // from the screen's thread, as the file runs to a few megabytes.
    await Isolate.run(() {
      final temp = File('${file.path}.tmp')..writeAsStringSync(_encode(songs), flush: true);
      temp.renameSync(file.path);
    });
  }
}

/// One song's lyrics as search looks through them: each line once (a
/// chorus is kept where it's first sung), and all of them run together, so
/// words that carry over from one line to the next are found too.
class SongLyrics {
  SongLyrics(this.lines) : _joined = _join(lines);

  /// [lyrics]' lines, without blank ones or repeats.
  factory SongLyrics.of(Lyrics? lyrics) {
    final seen = <String>{};
    return SongLyrics([
      for (final line in lyrics?.lines ?? const <LyricLine>[])
        if (line.text.trim().isNotEmpty && seen.add(line.text.trim())) LyricLine(line.text.trim(), line.time),
    ]);
  }

  final List<LyricLine> lines;

  /// The lines' search keys run together with spaces, and where each line
  /// starts in it. Worked out up front, where the lyrics are read or loaded
  /// away from the screen's thread, so the first search doesn't stall.
  final (String, List<int>) _joined;

  static (String, List<int>) _join(List<LyricLine> lines) {
    final starts = <int>[];
    final text = StringBuffer();
    for (final line in lines) {
      if (text.isNotEmpty) text.write(' ');
      starts.add(text.length);
      text.write(searchKey(line.text));
    }
    return (text.toString(), starts);
  }

  /// Where [query] (a search key) is first found: the line it starts on,
  /// whether at the start of a word, and whether it runs on into the next
  /// line. Null if it isn't.
  ({int line, bool wordStart, bool runsOn})? find(String query) {
    final (text, starts) = _joined;
    if (query.isEmpty) return null;
    var at = text.indexOf(query);
    if (at < 0) return null;
    // A match at a word's start beats one inside a word.
    final wordAt = at == 0 ? 0 : text.indexOf(' $query');
    final wordStart = wordAt >= 0;
    if (wordAt > 0) at = wordAt + 1;
    var line = 0;
    while (line + 1 < starts.length && starts[line + 1] <= at) {
      line++;
    }
    final runsOn = line + 1 < starts.length && at + query.length > starts[line + 1];
    return (line: line, wordStart: wordStart, runsOn: runsOn);
  }
}

/// A song whose lyrics have the words searched for, and where.
class LyricMatch {
  const LyricMatch({required this.song, required this.text, required this.time});

  final Song song;

  /// The line they're on (and the next, when they run on into it).
  final String text;

  /// When that line is sung; null for lyrics that aren't timed.
  final Duration? time;
}

/// The songs among [songs] whose lyrics have [query] (a search key, see
/// [searchKey]) in them, matches at the start of a word first, at most
/// [limit] of them. Queries shorter than three letters find nothing: they'd
/// be in nearly every song.
List<LyricMatch> searchLyrics(String query, Iterable<(Song, SongLyrics)> songs, {int limit = 50}) {
  if (query.length < 3) return const [];
  final starts = <LyricMatch>[], inside = <LyricMatch>[];
  for (final (song, lyrics) in songs) {
    final found = lyrics.find(query);
    if (found == null) continue;
    final line = lyrics.lines[found.line];
    final text = found.runsOn ? '${line.text} / ${lyrics.lines[found.line + 1].text}' : line.text;
    (found.wordStart ? starts : inside).add(LyricMatch(song: song, text: text, time: line.time));
    if (starts.length >= limit) break;
  }
  return [...starts, ...inside].take(limit).toList();
}
