import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

import 'listening_stats.dart';
import 'lyrics.dart';
import 'search_text.dart';

/// [title] without what versions of a song add to it, which the same song's
/// entry elsewhere won't have: "(Official Video)", "[feat. Someone]",
/// "- Remastered 2011".
String plainTitle(String title) {
  final plain = title.replaceAll(_titleExtras, '').replaceAll(_remasterSuffix, '').trim();
  return plain.isEmpty ? title.trim() : plain;
}

final _titleExtras = RegExp(
  r'\s*[(\[][^)\]]*\b(official|video|audio|lyrics?|visuali[sz]er|remaster(ed)?|feat|ft|featuring|explicit|hd|hq)\b[^)\]]*[)\]]',
  caseSensitive: false,
);

final _remasterSuffix = RegExp(r'\s+[-–—]\s+.*\bremaster(ed)?\b.*$', caseSensitive: false);

/// The names to look for [credit] under: its first artist, and if that has
/// a comma or "&" in it, the name before them too. Either could be right:
/// "Tyler, The Creator" is one artist, "Adele, Drake" two.
List<String> artistNames(String credit) {
  final first = splitArtists(credit).first;
  final shorter = first.split(RegExp(r'\s*(?:,|&)\s*')).first.trim();
  return [first, if (shorter.isNotEmpty && shorter != first) shorter];
}

/// Whether a song's own title or genre says it has no singing, so there's no
/// need to ask LRCLIB: "Song (Instrumental)", "Song - Off Vocal", or an
/// Instrumental genre.
bool looksInstrumental(String title, String? genre) =>
    _instrumentalTitle.hasMatch(title) || (genre != null && _instrumentalGenre.hasMatch(genre));

final _instrumentalTitle = RegExp(
  r'(?:[(\[][^)\]]*|\s[-–—]\s*)\b(?:instrumental|off[ -]?vocal|karaoke)\b',
  caseSensitive: false,
);

final _instrumentalGenre = RegExp(r'\binstrumental\b', caseSensitive: false);

/// The closest a song found online can be in length to the file: any further
/// off and it's likely another version, with the lyrics at other times.
const lengthTolerance = Duration(seconds: 3);

/// The lyrics to use for a song from LRCLIB's [json] search results, as LRC
/// or plain text. Timed lyrics come first, word-timed ones best, then plain
/// ones unless [timedOnly]. Null if nothing is the same song: the title and
/// artist have to match, and the length too when [length] is known, as wrong
/// lyrics are worse than none.
String? chooseLyrics(
  String json, {
  required String title,
  required String artist,
  Duration? length,
  bool timedOnly = false,
}) {
  final matches = <({String? timed, String? plain, bool wordTimed, double off})>[];
  for (final (:result, :off) in _sameSong(json, title, artist, length)) {
    if (result['instrumental'] == true) continue;
    final timed = (result['syncedLyrics'] as String?)?.trim() ?? '';
    final plain = (result['plainLyrics'] as String?)?.trim() ?? '';
    matches.add((
      timed: timed.isEmpty ? null : timed,
      plain: plain.isEmpty ? null : plain,
      wordTimed: result['hasWordSync'] == true,
      off: off,
    ));
  }

  // The nearest in length first, among those of the same kind.
  final timed = matches.where((m) => m.timed != null).toList()
    ..sort((a, b) {
      if (a.wordTimed != b.wordTimed) return a.wordTimed ? -1 : 1;
      return a.off.compareTo(b.off);
    });
  if (timed.isNotEmpty) return timed.first.timed;
  if (timedOnly) return null;
  final plain = matches.where((m) => m.plain != null).toList()..sort((a, b) => a.off.compareTo(b.off));
  return plain.isEmpty ? null : plain.first.plain;
}

/// Whether LRCLIB's [json] results list the song as instrumental.
bool listedInstrumental(String json, {required String title, required String artist, Duration? length}) =>
    _sameSong(json, title, artist, length).any((match) => match.result['instrumental'] == true);

/// Those of LRCLIB's [json] results that are the song (see [chooseLyrics]),
/// and how many seconds each is off its [length].
Iterable<({Map<dynamic, dynamic> result, double off})> _sameSong(
  String json,
  String title,
  String artist,
  Duration? length,
) sync* {
  final results = jsonDecode(json);
  if (results is! List) return;
  final wantedTitle = searchKey(plainTitle(title));
  final wantedArtists = [for (final name in artistNames(artist)) compactKey(searchKey(name))];
  if (wantedTitle.isEmpty || wantedArtists.first.isEmpty) return;
  final known = length != null && length != Duration.zero;

  for (final result in results) {
    if (result is! Map) continue;
    final foundTitle = searchKey(plainTitle(result['trackName'] as String? ?? ''));
    final foundArtist = compactKey(searchKey(result['artistName'] as String? ?? ''));
    if (foundTitle != wantedTitle || foundArtist.isEmpty) continue;
    if (!wantedArtists.any((a) => a.isNotEmpty && (foundArtist.contains(a) || a.contains(foundArtist)))) continue;
    final seconds = (result['duration'] as num?)?.toDouble();
    // A length is needed to tell versions apart, when the file has one.
    if (known && seconds == null) continue;
    final off = known ? (seconds! - length.inMilliseconds / 1000).abs() : 0.0;
    if (off > lengthTolerance.inSeconds) continue;
    yield (result: result, off: off);
  }
}

/// Which of a song's own lyrics and those found online to show: its own when
/// they're timed, otherwise what was found, which is only kept when it beats
/// them (see [MusicController]'s lyrics finder).
String? bestLyrics(String? own, String? found) {
  if (own == null || found == null) return own ?? found;
  return (parseLyrics(own)?.synced ?? false) ? own : found;
}

/// What going online sends, said before Blimp first does.
const lyricsPrivacyNotice =
    "Blimp will send the song's title, artist, album and length to LRCLIB (lrclib.net), a free public "
    'lyrics service, and your internet address will be visible to it, as with any website. Nothing '
    "else about you or your music is sent. Your music files are left alone unless you've chosen to save "
    'lyrics into them.';

/// Said before the lyrics finder is allowed to change the user's files.
const saveLyricsNotice =
    "Found lyrics will be saved into your MP3, FLAC, Ogg, Opus and M4A files, so they go wherever the songs go. This "
    "can't be undone with Remove found lyrics, though you can edit a song's lyrics in its tags.\n\n"
    "Lyrics a song already has are never replaced. A song that has its own, is in another format, or "
    "is playing keeps its found lyrics in Blimp instead.";

/// Why the lyrics finder had to stop for now.
enum LyricsFinderProblem {
  /// LRCLIB keeps turning Blimp away, or has asked it to slow down.
  busy,

  /// Couldn't reach it: no connection, most likely.
  unreachable,
}

class LyricsFinderException implements Exception {
  const LyricsFinderException(this.problem);

  final LyricsFinderProblem problem;
}

/// Looks up lyrics on LRCLIB (lrclib.net), a free public lyrics database.
/// Only a song's title, artist, album and length are sent. This and
/// [MusicController]'s setting that turns it on are the only reasons Blimp
/// goes online.
class LyricsFinder {
  final _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = 'Blimp (https://github.com/BersamaMus/Blimp)';

  bool _closed = false;

  /// The lyrics found for a song, timed if any can be, or no text if there
  /// are none, and whether LRCLIB lists it as instrumental, which ends the
  /// asking. [timedOnly] for a song with plain lyrics of its own.
  ///
  /// LRCLIB files a song under one album, and only some of its entries are
  /// timed, so one question often isn't enough: it's asked with the album,
  /// then without, then searched, stopping once timed lyrics turn up. It
  /// turns away questions it doesn't have to hand when it's under load
  /// ("busy"), even when another way of asking gets an answer, so being
  /// turned away just moves on to the next. Throws [LyricsFinderException]
  /// if it can't be reached, it says to slow down, or nothing was answered.
  Future<({String? text, bool instrumental})> find({
    required String title,
    required String artist,
    String? album,
    Duration? length,
    bool timedOnly = false,
  }) async {
    final track = plainTitle(title);
    final names = artistNames(artist);
    final seconds = length == null || length == Duration.zero ? null : '${length.inSeconds}';
    Uri get(String name, [String? album]) => Uri.https('lrclib.net', '/api/get', {
      'track_name': track,
      'artist_name': name,
      'album_name': ?album,
      'duration': ?seconds,
    });
    final questions = [
      if (album != null) get(names.first, album),
      get(names.first),
      if (names.length > 1) get(names.last),
      Uri.https('lrclib.net', '/api/search', {'track_name': track, 'artist_name': names.first}),
    ];

    String? plain;
    var answered = false;
    for (final url in questions) {
      final (status, body) = await _get(url);
      if (status == 429) throw const LyricsFinderException(LyricsFinderProblem.busy);
      if (status >= 500) continue;
      answered = true;
      if (status != 200) continue;
      // A single song from /api/get, a list of them from /api/search.
      final results = url.path.endsWith('get') ? '[$body]' : body;
      final String? text;
      final bool instrumental;
      try {
        (text, instrumental) = await _choose(results, title, artist, length, timedOnly);
      } on Object {
        // Not LRCLIB's answer: a sign-in page on public Wi-Fi, say.
        throw const LyricsFinderException(LyricsFinderProblem.unreachable);
      }
      // Lyrics win over the flag here too, wherever they were found.
      if (instrumental && plain == null) return (text: null, instrumental: true);
      if (text == null) continue;
      if (parseLyrics(text)?.synced ?? false) return (text: text, instrumental: false);
      plain ??= text;
    }
    if (!answered) throw const LyricsFinderException(LyricsFinderProblem.busy);
    return (text: plain, instrumental: false);
  }

  // Static, so the isolate isn't handed this object's connection, which it
  // couldn't take. Away from the screen's thread: each result carries whole
  // lyrics.
  static Future<(String?, bool)> _choose(String body, String title, String artist, Duration? length, bool timedOnly) =>
      Isolate.run(() {
        final text = chooseLyrics(body, title: title, artist: artist, length: length, timedOnly: timedOnly);
        // Lyrics win over the flag, as any entry can be marked by mistake.
        return (text, text == null && listedInstrumental(body, title: title, artist: artist, length: length));
      });

  Future<(int, String)> _get(Uri url) async {
    // Closed while a song with several questions was being looked up.
    if (_closed) throw const LyricsFinderException(LyricsFinderProblem.unreachable);
    try {
      final request = await _client.getUrl(url);
      final response = await request.close().timeout(const Duration(seconds: 30));
      final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
      return (response.statusCode, body);
    } on Exception {
      // Covers no connection, timeouts, and answers that don't decode.
      throw const LyricsFinderException(LyricsFinderProblem.unreachable);
    }
  }

  void close() {
    _closed = true;
    _client.close(force: true);
  }
}

/// Lyrics found online, kept in a file in the app's support folder, apart
/// from the music: Android doesn't let a music app put .lrc files beside
/// songs, and rewriting every song's tags is a risk the user has to choose
/// (see [MusicController]'s setting for it, on desktop). Not in backups: they
/// can be found again on another device.
class FoundLyrics {
  FoundLyrics(this._file);

  final File? _file;

  /// By song id, as LRC or plain text.
  Map<int, String> _texts = {};

  /// When songs were last looked up with nothing to keep, in milliseconds
  /// since 1970, by song id.
  Map<int, int> _missed = {};

  /// Songs LRCLIB lists as instrumental, which are never looked up again.
  Set<int> _instrumental = {};

  /// The database grows, so songs without lyrics are tried again after this.
  static const retryAfter = Duration(days: 30);

  /// How soon a song is tried again after LRCLIB wouldn't answer for it.
  static const retryUnansweredAfter = Duration(days: 1);

  /// Far enough off that [keepOwn] lasts.
  static const _never = 1 << 52;

  static Future<FoundLyrics> open() async {
    final dir = await getApplicationSupportDirectory();
    return openFile(File('${dir.path}/found_lyrics.json'));
  }

  /// Those kept in [file], or none if it can't be read.
  static Future<FoundLyrics> openFile(File file) async {
    final found = FoundLyrics(file);
    try {
      final text = await file.readAsString();
      // Away from the screen's thread: the file can be a few megabytes. Only
      // the plain maps come back, as the object itself holds a Future, which
      // can't pass between threads.
      final (texts, missed, instrumental) = await Isolate.run(() {
        final read = FoundLyrics(null)..decode(text);
        return (read._texts, read._missed, read._instrumental);
      });
      found
        .._texts = texts
        .._missed = missed
        .._instrumental = instrumental;
    } on Object {
      // Nothing found yet, or an unreadable file: start afresh.
    }
    return found;
  }

  int get length => _texts.length;

  Iterable<int> get ids => _texts.keys;

  String? textOf(int id) => _texts[id];

  bool isInstrumental(int id) => _instrumental.contains(id);

  void markInstrumental(int id) {
    _instrumental.add(id);
    _missed.remove(id);
  }

  /// Whether the song with [id] needs no looking up at [now].
  bool settled(int id, DateTime now) {
    if (_texts.containsKey(id) || _instrumental.contains(id)) return true;
    final missed = _missed[id];
    return missed != null && now.millisecondsSinceEpoch - missed < retryAfter.inMilliseconds;
  }

  void put(int id, String text) {
    _texts[id] = text;
    _missed.remove(id);
    _instrumental.remove(id);
  }

  void missed(int id, DateTime now) => _missed[id] = now.millisecondsSinceEpoch;

  /// Forgets the text for [id], now saved in the song's file. Plain lyrics
  /// wait the usual time before timed ones are looked for again.
  void savedInFile(int id, DateTime now) {
    _texts.remove(id);
    missed(id, now);
  }

  /// Notes that LRCLIB wouldn't answer for [id], so nothing is known, and it
  /// shouldn't hold up the songs after it.
  void unanswered(int id, DateTime now) => missed(id, now.subtract(retryAfter - retryUnansweredAfter));

  /// Forgets what was found for [id] and doesn't look again, as when the
  /// user has written its lyrics themselves. Returns whether there was any.
  bool keepOwn(int id) {
    _missed[id] = _never;
    return _texts.remove(id) != null;
  }

  /// Forgets all found lyrics. Instrumentals stay: there's nothing of them
  /// to remove, and looking them up again would only cost requests. So do
  /// songs under [keepOwn], or lyrics found later would cover the user's own.
  void clear() {
    _texts = {};
    _missed.removeWhere((_, at) => at != _never);
  }

  String encode() => _encode(_texts, _missed, _instrumental);

  static String _encode(Map<int, String> texts, Map<int, int> missed, Set<int> instrumental) => jsonEncode({
    'instrumental': instrumental.toList(),
    'texts': {for (final MapEntry(:key, :value) in texts.entries) '$key': value},
    'missed': {for (final MapEntry(:key, :value) in missed.entries) '$key': value},
  });

  void decode(String text) {
    final json = jsonDecode(text) as Map<String, Object?>;
    _texts = {
      for (final MapEntry(:key, :value) in (json['texts'] as Map<String, Object?>).entries)
        if ((int.tryParse(key), value) case (final int id, final String text)) id: text,
    };
    _missed = {
      for (final MapEntry(:key, :value) in (json['missed'] as Map<String, Object?>).entries)
        if ((int.tryParse(key), value) case (final int id, final int at)) id: at,
    };
    _instrumental = {...(json['instrumental'] as List<Object?>? ?? const []).whereType<int>()};
  }

  /// Saves one at a time, as each is written to the same temporary file.
  Future<void> save() => _saved = _saved.then((_) => _write());

  Future<void> _saved = Future.value();

  Future<void> _write() async {
    final file = _file;
    if (file == null) return;
    final texts = _texts, missed = _missed, instrumental = _instrumental;
    // Written beside, then swapped in, so a crash midway loses nothing.
    await Isolate.run(() {
      try {
        final temp = File('${file.path}.tmp')..writeAsStringSync(_encode(texts, missed, instrumental), flush: true);
        temp.renameSync(file.path);
      } on FileSystemException {
        // A full disk, say. It's all still in memory for the next save.
      }
    });
  }
}
