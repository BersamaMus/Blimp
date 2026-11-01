import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_library.dart';
import 'lyrics_finder.dart';
import 'media_library.dart';
import 'search_text.dart';
import 'tag_editor.dart';

/// What going online for tags sends, said before Blimp first does.
const tagFinderNotice =
    "Blimp will send each song's title, artist, album and length to Apple's iTunes Search and to MusicBrainz, "
    'a free public music database, and download covers from Apple and the Cover Art Archive. They will see '
    'your internet address, as with any website. Nothing else about you or your music is sent.\n\n'
    "Found tags and covers are saved into your music files. Only what's missing is added: tags a song "
    'already has are left as they are.';

/// How far a song found online can be in length from the file with an artist
/// to go on: any further off and it's likely another version.
const songLengthTolerance = Duration(seconds: 5);

/// How close in length a song must be when there's no artist to go on.
const _lengthWithoutArtist = Duration(seconds: 2);

/// What a song can be missing.
enum MissingTag {
  artist('artist'),
  album('album'),
  genre('genre'),
  year('year'),
  cover('cover');

  const MissingTag(this.label);

  final String label;
}

/// What [song] has no value for, given whether it [hasCover].
Set<MissingTag> missingTags(Song song, {required bool hasCover}) => {
  if (song.artist == null) MissingTag.artist,
  if (song.album == null) MissingTag.album,
  if (song.genre == null) MissingTag.genre,
  if ((song.year ?? 0) <= 0) MissingTag.year,
  if (!hasCover) MissingTag.cover,
};

/// The title and artist to search for. With no artist tag, the title is
/// usually the file's name, and many are "Artist - Song" or "01 Song".
({String title, String? artist, bool fromFileName}) wantedTags(Song song) {
  if (song.artist case final artist?) return (title: song.title, artist: artist, fromFileName: false);
  final name = song.title.replaceFirst(RegExp(r'^\d{1,3}[\s.\-_]+'), '');
  final parts = name.split(RegExp(r'\s+[-–—]\s+'));
  if (parts.length == 2) return (title: parts[1], artist: parts[0], fromFileName: true);
  return (title: name, artist: null, fromFileName: name != song.title);
}

/// A song as a service lists it.
typedef FoundTags = ({
  String title,
  String artist,
  String? album,
  String? genre,
  int? year,
  int? track,
  int? disc,
  String? cover,
});

/// One of a service's results, ready to compare with the song wanted.
typedef _Candidate = ({FoundTags tags, num? millis});

/// Whether albums [a] and [b] are the same, allowing for "(Deluxe Edition)".
bool sameAlbum(String a, String b) {
  String plain(String album) => searchKey(album.replaceAll(RegExp(r'\s*[(\[].*?[)\]]'), ''));
  final (first, second) = (plain(a), plain(b));
  return first.isNotEmpty && second.isNotEmpty && (first.contains(second) || second.contains(first));
}

/// The one of [candidates] that is the song, or null if none is, as wrong
/// tags are worse than none. The title has to match, and the artist and
/// length. With no artist known it must be the only song by that name of
/// nearly that length. One from the song's own [album] comes first.
FoundTags? _pick(Iterable<_Candidate> candidates, String title, String? artist, String? album, Duration? length) {
  final wantedTitle = searchKey(plainTitle(title));
  if (wantedTitle.isEmpty) return null;
  final wantedArtists = artist == null ? const <String>[] : [for (final name in artistNames(artist)) compactKey(searchKey(name))];
  final tolerance = artist == null ? _lengthWithoutArtist : songLengthTolerance;
  final known = length != null && length != Duration.zero;
  if (artist == null && !known) return null;

  final matches = <({FoundTags tags, double off})>[];
  for (final (:tags, :millis) in candidates) {
    if (searchKey(plainTitle(tags.title)) != wantedTitle) continue;
    final artistKey = compactKey(searchKey(tags.artist));
    if (artist != null && !wantedArtists.any((a) => a.isNotEmpty && (artistKey.contains(a) || a.contains(artistKey)))) continue;
    if (known && millis == null) continue;
    final off = known ? (millis! - length.inMilliseconds).abs() / 1000 : 0.0;
    if (off > tolerance.inSeconds) continue;
    matches.add((tags: tags, off: off));
  }
  if (matches.isEmpty) return null;
  if (artist == null && matches.map((m) => compactKey(searchKey(m.tags.artist))).toSet().length > 1) return null;

  bool ownAlbum(FoundTags tags) => album != null && tags.album != null && sameAlbum(album, tags.album!);
  matches.sort((a, b) {
    final (first, second) = (ownAlbum(a.tags), ownAlbum(b.tags));
    return first != second ? (first ? -1 : 1) : a.off.compareTo(b.off);
  });
  return matches.first.tags;
}

int? _yearOf(Object? date) => date is String ? int.tryParse(date.split('-').first) : null;

/// The result in iTunes Search's [json] that is the song; see [_pick].
FoundTags? chooseTags(String json, {required String title, String? artist, String? album, Duration? length}) {
  final decoded = jsonDecode(json);
  if (decoded is! Map) return null;
  final candidates = <_Candidate>[
    for (final result in decoded['results'] as List? ?? const [])
      if (result case {'kind': 'song', 'trackName': final String name, 'artistName': final String by})
        (
          millis: result['trackTimeMillis'] as num?,
          tags: (
            title: name,
            artist: by,
            album: result['collectionName'] as String?,
            genre: result['primaryGenreName'] as String?,
            year: _yearOf(result['releaseDate']),
            track: result['trackNumber'] as int?,
            disc: result['discNumber'] as int?,
            // The address names the size, and bigger ones are there too.
            cover: (result['artworkUrl100'] as String?)?.replaceFirst('100x100bb', '600x600bb'),
          ),
        ),
  ];
  return _pick(candidates, title, artist, album, length);
}

/// The address to search MusicBrainz for the recording, narrowing by length
/// when there's no artist to go on.
Uri musicBrainzSearch(String title, String? artist, Duration? length) {
  String quoted(String text) => '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  final seconds = length?.inMilliseconds ?? 0;
  final wiggle = _lengthWithoutArtist.inMilliseconds;
  final query = [
    'recording:${quoted(plainTitle(title))}',
    if (artist != null) 'artist:${quoted(artistNames(artist).first)}',
    if (artist == null && seconds > 0) 'dur:[${seconds - wiggle} TO ${seconds + wiggle}]',
  ].join(' AND ');
  return Uri.https('musicbrainz.org', '/ws/2/recording', {'query': query, 'fmt': 'json', 'limit': '25'});
}

/// The release of a recording to take tags from, among those in [releases]:
/// official only, as MusicBrainz also lists bootlegs, and the song's own
/// [album] if it's there, then a plain album over a single or compilation.
Map<dynamic, dynamic>? _bestRelease(List<Object?> releases, String? album) {
  final official = [for (final release in releases) if (release is Map && release['status'] == 'Official') release];
  bool plainAlbum(Map<dynamic, dynamic> release) => switch (release['release-group']) {
    {'primary-type': 'Album', 'secondary-types': null || []} => true,
    {'primary-type': 'Album'} && final Map<dynamic, dynamic> group => !group.containsKey('secondary-types'),
    _ => false,
  };
  if (album != null) {
    for (final release in official) {
      if (release['title'] case final String title when sameAlbum(album, title)) return release;
    }
  }
  return official.where(plainAlbum).firstOrNull ?? official.firstOrNull;
}

/// The result in MusicBrainz's [json] that is the song, and the id of its
/// album there, which its genres and cover are filed under. See [_pick].
({FoundTags tags, String? group})? chooseMusicBrainz(
  String json, {
  required String title,
  String? artist,
  String? album,
  Duration? length,
}) {
  final decoded = jsonDecode(json);
  if (decoded is! Map) return null;
  final groups = <FoundTags, String?>{};
  final candidates = <_Candidate>[];
  for (final recording in decoded['recordings'] as List? ?? const []) {
    if (recording is! Map) continue;
    // Set apart by a note like "live, 2016": some other performance.
    if ((recording['disambiguation'] as String? ?? '').isNotEmpty) continue;
    final name = recording['title'];
    final release = _bestRelease(recording['releases'] as List? ?? const [], album);
    if (name is! String || release == null) continue;
    final credit = [
      for (final part in recording['artist-credit'] as List? ?? const [])
        if (part is Map) '${part['name'] ?? ''}${part['joinphrase'] ?? ''}',
    ].join();
    if (credit.isEmpty) continue;
    final group = switch (release['release-group']) {
      {'id': final String id} => id,
      _ => null,
    };
    final medium = (release['media'] as List? ?? const []).whereType<Map<dynamic, dynamic>>().firstOrNull;
    final track = switch (medium?['track']) {
      [{'number': final String number}, ...] => int.tryParse(number),
      _ => null,
    };
    final FoundTags tags = (
      title: name,
      artist: credit,
      album: release['title'] as String?,
      genre: null,
      year: _yearOf(recording['first-release-date']) ?? _yearOf(release['date']),
      track: track,
      disc: medium?['position'] as int?,
      cover: group == null ? null : 'https://coverartarchive.org/release-group/$group/front-500',
    );
    groups[tags] = group;
    candidates.add((tags: tags, millis: recording['length'] as num?));
  }
  final picked = _pick(candidates, title, artist, album, length);
  return picked == null ? null : (tags: picked, group: groups[picked]);
}

/// The genre with the most votes in MusicBrainz's [json] for an album.
String? chooseGenre(String json) {
  final decoded = jsonDecode(json);
  if (decoded is! Map) return null;
  final genres = [
    for (final genre in decoded['genres'] as List? ?? const [])
      if (genre case {'name': final String name, 'count': final int count}) (name: name, count: count),
  ]..sort((a, b) => b.count.compareTo(a.count));
  if (genres.isEmpty) return null;
  return genres.first.name.split(' ').map((word) => word.isEmpty ? word : word[0].toUpperCase() + word.substring(1)).join(' ');
}

/// [first] with its gaps filled from [second]. Track and disc numbers belong
/// to an album, so they only come across with it or for the same one.
FoundTags mergeTags(FoundTags first, FoundTags? second) {
  if (second == null) return first;
  final album = first.album ?? second.album;
  final sameRelease = first.album == null || (second.album != null && sameAlbum(first.album!, second.album!));
  return (
    title: first.title,
    artist: first.artist,
    album: album,
    genre: first.genre ?? second.genre,
    year: first.year ?? second.year,
    track: first.track ?? (sameRelease ? second.track : null),
    disc: first.disc ?? (sameRelease ? second.disc : null),
    cover: first.cover ?? second.cover,
  );
}

/// Whether [found]'s cover can go on a song of [album]. A song with an album
/// takes only that album's cover, or one album's songs would end up with
/// different ones.
bool coverFits(String? album, FoundTags found) =>
    album == null || (found.album != null && sameAlbum(album, found.album!));

/// What of [missing] [found] leaves unfilled for [song], and so is worth
/// asking the next service for.
Set<MissingTag> stillMissing(Song song, FoundTags? found, Set<MissingTag> missing) {
  if (found == null) return missing;
  return {
    for (final tag in missing)
      if (switch (tag) {
        MissingTag.artist => false,
        MissingTag.album => found.album == null,
        MissingTag.genre => found.genre == null,
        MissingTag.year => found.year == null,
        MissingTag.cover => found.cover == null || !coverFits(song.album ?? found.album, found),
      })
        tag,
  };
}

/// What to write to fill [missing] from [found]: nothing a song already has.
/// Track and disc numbers belong to an album, so they come only with it.
TagChanges changesFor(Song song, FoundTags found, Set<MissingTag> missing, {Uint8List? cover}) {
  final wanted = wantedTags(song);
  final albumMatches = song.album == null || (found.album != null && sameAlbum(song.album!, found.album!));
  String? blankNumber(int? have, int? value) => (have ?? 0) <= 0 && (value ?? 0) > 0 ? '$value' : null;
  return TagChanges(
    title: wanted.fromFileName ? found.title : null,
    artist: missing.contains(MissingTag.artist) ? found.artist : null,
    album: missing.contains(MissingTag.album) ? found.album : null,
    genre: missing.contains(MissingTag.genre) ? found.genre : null,
    year: missing.contains(MissingTag.year) && found.year != null ? '${found.year}' : null,
    track: albumMatches ? blankNumber(song.track, found.track) : null,
    disc: albumMatches ? blankNumber(song.disc, found.disc) : null,
    cover: cover,
  );
}

/// What [changes] wrote, to show: "year: 2026 · album: 25 · cover".
String filledSummary(TagChanges changes) => [
  if (changes.title case final title?) 'title: $title',
  if (changes.artist case final artist?) 'artist: $artist',
  if (changes.album case final album?) 'album: $album',
  if (changes.genre case final genre?) 'genre: $genre',
  if (changes.year case final year?) 'year: $year',
  if (changes.track case final track?) 'track: $track',
  if (changes.disc case final disc?) 'disc: $disc',
  if (changes.cover != null) 'cover',
].join(' · ');

/// What of [MissingTag] [changes] filled in.
Set<MissingTag> filledTags(TagChanges changes) => {
  if (changes.artist != null) MissingTag.artist,
  if (changes.album != null) MissingTag.album,
  if (changes.genre != null) MissingTag.genre,
  if (changes.year != null) MissingTag.year,
  if (changes.cover != null) MissingTag.cover,
};

/// What a search for a song went by, to notice when that changes.
String searchedAs(String title, String? artist) => '${searchKey(title)}\n${searchKey(artist ?? '')}';

/// The songs noted as searched, from [text] as saved, or none if it can't be
/// read: the worst that does is search them again.
Map<int, String> decodeSearched(String? text) {
  if (text == null) return {};
  try {
    return {
      for (final MapEntry(:key, :value) in (jsonDecode(text) as Map<String, Object?>).entries)
        if ((int.tryParse(key), value) case (final int id, final String searched)) id: searched,
    };
  } on Object {
    return {};
  }
}

/// How one song's search went.
enum TagFixState { waiting, working, fixed, notFound, failed }

class TagFix {
  const TagFix(this.state, [this.note, this.filled = const {}]);

  final TagFixState state;
  final String? note;

  /// What was filled in, which the song may not yet show if it's not been
  /// read again.
  final Set<MissingTag> filled;
}

/// A song with gaps in its tags.
typedef TagGap = ({Song song, Set<MissingTag> missing});

class TagFindException implements Exception {
  const TagFindException(this.message);

  final String message;
}

/// Settings' tag finder: finds songs with gaps and fills them from iTunes
/// Search, then MusicBrainz for what it doesn't have, one song at a time.
/// Lives outside the screen so it goes on after leaving it. Desktop only:
/// Android asks the user before each file is changed.
class TagFinder extends ChangeNotifier {
  /// Apple allows about 20 searches a minute.
  static const _pause = Duration(milliseconds: 3500);

  /// MusicBrainz allows one request a second.
  static const _musicBrainzPause = Duration(milliseconds: 1100);

  /// Songs with gaps as of the last check, and any filled in since Blimp
  /// started, kept so what they were given can still be seen.
  List<TagGap> gaps = const [];

  /// What [gap] still lacks, going by what's been filled in.
  Set<MissingTag> lacking(TagGap gap) => gap.missing.difference(fixes[gap.song.id]?.filled ?? const {});

  /// How many songs still have gaps.
  int get needing => gaps.where((gap) => lacking(gap).isNotEmpty).length;

  /// Songs with gaps in a format Blimp can't write.
  int unsupported = 0;

  /// Songs checked for covers so far, and how many there are, while checking.
  (int, int)? checking;

  bool get running => _running;
  bool _running = false;

  /// Why finding stopped early, if it did.
  String? problem;

  /// How songs fared since Blimp started, by id. Songs that found nothing
  /// aren't tried again by the one button until then.
  final Map<int, TagFix> fixes = {};

  /// Called after songs change, to read them again.
  VoidCallback? onChanged;

  static const _searchedKey = 'tag_finder_searched';

  /// Songs searched for with something left unfound, by id: what they were
  /// searched by (see [searchedAs]), so changing that searches them again.
  /// Kept between runs, so Find all doesn't ask about them every time. Each
  /// song's own search button still does. Not in backups: ids are this PC's.
  Map<int, String>? _searched;

  /// Whether MusicBrainz gave an answer for the song being searched. If not,
  /// nothing is known about it, so it isn't noted as searched.
  bool _musicBrainzAnswered = true;

  final List<TagGap> _queue = [];
  bool _stopping = false;
  bool _scanning = false;
  List<Song>? _rescan;

  /// Whether each file has a cover, by path, with the song's date and size to
  /// notice when it changes, as looking inside every file is slow. The date
  /// alone won't do: saving a found cover keeps it.
  final Map<String, ((DateTime?, int), bool)> _covers = {};

  /// Works out which of [songs] have gaps. Comes back at once if it's
  /// checking already, and goes again after with the latest songs.
  Future<void> scan(List<Song> songs) async {
    if (_scanning) {
      _rescan = songs;
      return;
    }
    _scanning = true;
    final prefs = await SharedPreferences.getInstance();
    _searched ??= decodeSearched(prefs.getString(_searchedKey));
    final usable =[for (final song in songs) if (!song.spoken && song.path != null) song];
    final unknown = [
      for (final song in usable)
        if (_covers[song.path!]?.$1 != (song.dateAdded, song.size)) song,
    ];
    for (var i = 0; i < unknown.length; i += 25) {
      checking = (i, unknown.length);
      notifyListeners();
      final batch = unknown.sublist(i, (i + 25).clamp(0, unknown.length));
      final without = await DesktopLibrary.withoutCovers([for (final song in batch) song.path!]);
      for (final song in batch) {
        _covers[song.path!] = ((song.dateAdded, song.size), !without.contains(song.path));
      }
    }
    checking = null;
    final all = [
      for (final song in usable)
        (song: song, missing: missingTags(song, hasCover: _covers[song.path!]!.$2)),
    ].where((gap) => gap.missing.isNotEmpty || fixes[gap.song.id]?.state == TagFixState.fixed);
    gaps = [for (final gap in all) if (TagEditor.canEdit(gap.song)) gap];
    unsupported = all.length - gaps.length;
    markSearched();
    _scanning = false;
    notifyListeners();
    if (_rescan case final next?) {
      _rescan = null;
      await scan(next);
    }
  }

  /// Notes the songs in [gaps] already searched in an earlier run, unless
  /// their title or artist has changed since, so Find all passes over them.
  @visibleForTesting
  void markSearched([Map<int, String>? searched]) {
    final known = searched ?? _searched ?? const {};
    for (final (:song, :missing) in gaps) {
      if (missing.isEmpty || fixes.containsKey(song.id)) continue;
      if (known[song.id] == searchedAs(song.title, song.artist)) {
        fixes[song.id] = const TagFix(TagFixState.notFound, 'Searched before, nothing found');
      }
    }
  }

  Future<void> _remember(Song song, {String? title, String? artist}) async {
    if (!_musicBrainzAnswered) return;
    final searched = _searched ??= {};
    searched[song.id] = searchedAs(title ?? song.title, song.artist ?? artist);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_searchedKey, jsonEncode({for (final MapEntry(:key, :value) in searched.entries) '$key': value}));
  }

  /// Fills in every song not tried yet.
  void fixAll() => fix([for (final gap in gaps) if (!fixes.containsKey(gap.song.id)) gap]);

  void fix(List<TagGap> chosen) {
    problem = null;
    for (final gap in chosen) {
      if (_queue.any((queued) => queued.song == gap.song)) continue;
      _queue.add(gap);
      fixes[gap.song.id] = const TagFix(TagFixState.waiting);
    }
    notifyListeners();
    unawaited(_work());
  }

  void stop() {
    _stopping = true;
    for (final gap in _queue) {
      fixes.remove(gap.song.id);
    }
    _queue.clear();
    notifyListeners();
  }

  Future<void> _work() async {
    if (_running) return;
    _running = true;
    _stopping = false;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'Blimp (https://github.com/BersamaMus/Blimp)';
    var changed = false;
    TagGap? current;
    try {
      while (_queue.isNotEmpty && !_stopping) {
        final gap = current = _queue.removeAt(0);
        fixes[gap.song.id] = const TagFix(TagFixState.working);
        notifyListeners();
        final fix = await _fix(client, gap);
        fixes[gap.song.id] = fix;
        current = null;
        changed |= fix.state == TagFixState.fixed;
        notifyListeners();
        if (_queue.isNotEmpty) await Future<void>.delayed(_pause);
      }
    } on Object catch (e) {
      problem = e is TagFindException ? e.message : "Couldn't search right now. Try again later.";
      // Including the song being searched, so it can be tried again.
      for (final gap in [?current, ..._queue]) {
        fixes.remove(gap.song.id);
      }
      _queue.clear();
    } finally {
      client.close(force: true);
      _running = false;
      notifyListeners();
      if (changed) onChanged?.call();
    }
  }

  Future<TagFix> _fix(HttpClient client, TagGap gap) async {
    final (:song, :missing) = gap;
    final wanted = wantedTags(song);
    _musicBrainzAnswered = true;
    final apple = chooseTags(
      await _search(client, wanted.title, wanted.artist),
      title: wanted.title,
      artist: wanted.artist,
      album: song.album,
      length: song.duration,
    );
    final unfilled = stillMissing(song, apple, missing);
    final other = unfilled.isEmpty ? null : await _musicBrainz(client, song, wanted.title, wanted.artist, unfilled);
    final found = apple == null ? other : mergeTags(apple, other);
    if (found == null) {
      await _remember(song);
      return const TagFix(TagFixState.notFound, 'No match found');
    }

    final cover = missing.contains(MissingTag.cover)
        ? await _firstCover(client, song.album ?? found.album, [?apple, ?other])
        : null;
    final changes = changesFor(song, found, missing, cover: cover);
    if (changes.isEmpty) {
      await _remember(song);
      return const TagFix(TagFixState.notFound, 'Nothing new found');
    }
    try {
      await TagEditor.save(song, changes, keepDate: true);
    } on TagEditException catch (e) {
      return TagFix(TagFixState.failed, e.message);
    }
    MediaLibrary.forget(song.id);
    // What's still blank wasn't found, so it needn't be asked about again.
    if (missing.difference(filledTags(changes)).isNotEmpty) {
      await _remember(song, title: changes.title, artist: changes.artist);
    }
    return TagFix(TagFixState.fixed, 'Filled in ${filledSummary(changes)}', filledTags(changes));
  }

  Future<String> _search(HttpClient client, String title, String? artist) async {
    final term = [?artist, plainTitle(title)].join(' ');
    final url = Uri.https('itunes.apple.com', '/search', {'term': term, 'entity': 'song', 'limit': '25'});
    try {
      final (status, body) = await _get(client, url);
      if (status == 403 || status == 429) {
        throw const TagFindException('Apple asked Blimp to slow down. Try again in a few minutes.');
      }
      if (status != 200) throw const TagFindException("Couldn't search right now. Try again later.");
      return body;
    } on TagFindException {
      rethrow;
    } on Exception {
      throw const TagFindException("Couldn't connect. Check your internet.");
    }
  }

  /// MusicBrainz's answer for the song, genre included if [unfilled] asks for
  /// it. Null if it can't be had: what Apple found is still worth keeping.
  Future<FoundTags?> _musicBrainz(HttpClient client, Song song, String title, String? artist, Set<MissingTag> unfilled) async {
    _musicBrainzAnswered = false;
    try {
      await Future<void>.delayed(_musicBrainzPause);
      final (status, body) = await _get(client, musicBrainzSearch(title, artist, song.duration));
      if (status != 200) return null;
      final match =chooseMusicBrainz(body, title: title, artist: artist, album: song.album, length: song.duration);
      if (match == null) {
        _musicBrainzAnswered = true;
        return null;
      }
      final (:tags, :group) = match;
      if (group == null || !unfilled.contains(MissingTag.genre)) {
        _musicBrainzAnswered = true;
        return tags;
      }
      await Future<void>.delayed(_musicBrainzPause);
      final url = Uri.https('musicbrainz.org', '/ws/2/release-group/$group', {'inc': 'genres', 'fmt': 'json'});
      final (genreStatus, genres) = await _get(client, url);
      if (genreStatus != 200) return tags;
      _musicBrainzAnswered = true;
      return (
        title: tags.title,
        artist: tags.artist,
        album: tags.album,
        genre: chooseGenre(genres),
        year: tags.year,
        track: tags.track,
        disc: tags.disc,
        cover: tags.cover,
      );
    } on Exception {
      return null;
    }
  }

  Future<(int, String)> _get(HttpClient client, Uri url) async {
    final response = await (await client.getUrl(url)).close().timeout(const Duration(seconds: 30));
    final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
    return (response.statusCode, body);
  }

  /// The first cover of [sources] that fits [album] and can be fetched.
  Future<Uint8List?> _firstCover(HttpClient client, String? album, List<FoundTags> sources) async {
    for (final source in sources) {
      if (!coverFits(album, source)) continue;
      if (await _cover(client, source.cover) case final cover?) return cover;
    }
    return null;
  }

  /// The cover at [url], or null if there isn't one to be had: the tags are
  /// still worth saving without it.
  Future<Uint8List?> _cover(HttpClient client, String? url) async {
    if (url == null) return null;
    try {
      final response = await (await client.getUrl(Uri.parse(url))).close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return null;
      final bytes = await response.fold(BytesBuilder(copy: false), (all, chunk) => all..add(chunk));
      final cover = bytes.takeBytes();
      // JPEG, as saved tags say it is.
      return cover.length > 2 && cover[0] == 0xFF && cover[1] == 0xD8 ? cover : null;
    } on Exception {
      return null;
    }
  }
}

/// The one finder, shared with the Settings page.
final tagFinder = TagFinder();
