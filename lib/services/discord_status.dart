import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import 'lyrics_finder.dart';
import 'media_library.dart';
import 'music_controller.dart';
import 'search_text.dart';
import 'tag_finder.dart';

/// The Blimp application on Discord's developer site. It isn't a secret: it
/// only tells Discord which app's name and logo to show.
const discordApplicationId = '1566864875634954340';

/// The logo uploaded to that application.
const _logo = 'blimp';

/// Discord turns down a status with text shorter or longer than these.
const _shortestText = 2;
const _longestText = 128;

/// What Discord's "Listening to" kind of status is called, by number.
const _listening = 2;

/// [text] made to fit Discord's limits. A one-letter title gets invisible
/// characters, or the whole status would be turned down for it.
String _fitted(String text) {
  final trimmed = text.trim();
  final letters = trimmed.runes;
  if (letters.length > _longestText) {
    return '${String.fromCharCodes(letters.take(_longestText - 1))}…';
  }
  return letters.length < _shortestText ? '$trimmed​​' : trimmed;
}

/// When [song] started, had it played straight through to [position] at
/// [speed], as of [now].
DateTime discordStart(Duration position, {required DateTime now, double speed = 1}) =>
    now.subtract(position * (1 / speed));

/// Discord turns down a status with a longer link than this.
const _longestLink = 256;

/// A search for [song] on YouTube Music, for people to follow from Discord.
/// Blimp only builds the address and never opens it, so nothing is sent
/// unless someone clicks. Null for a song too long to fit.
String? discordSongLink(Song song) {
  final wanted = wantedTags(song);
  final query = [?wanted.artist, plainTitle(wanted.title)].join(' ');
  final link = Uri.https('music.youtube.com', '/search', {'q': query}).toString();
  return link.length > _longestLink ? null : link;
}

/// The web address of [song]'s cover in iTunes Search's [json], or null if
/// it's not there. As with found tags, none is better than the wrong one.
String? discordCover(String json, Song song) {
  final wanted = wantedTags(song);
  final found = chooseTags(json, title: wanted.title, artist: wanted.artist, album: song.album, length: song.duration);
  return found != null && coverFits(song.album, found) ? found.cover : null;
}

/// Whether the Cover Art Archive's [json] for an album lists a front cover.
/// Plenty of albums on MusicBrainz have none.
bool hasFrontCover(String json) {
  final decoded = jsonDecode(json);
  if (decoded is! Map) return false;
  return (decoded['images'] as List? ?? const []).any((image) => image is Map && image['front'] == true);
}

/// Finds covers for Discord, which can only show pictures from the web, not
/// those on this PC: on iTunes Search, then on MusicBrainz and the Cover Art
/// Archive for what it doesn't have. Covers are remembered until Blimp closes,
/// so each album is only looked up once.
class DiscordCovers {
  DiscordCovers(
    this._get, {
    this.pause = const Duration(milliseconds: 3500),
    this.musicBrainzPause = const Duration(milliseconds: 1100),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// How long to leave a song alone after a service fails or asks Blimp to
  /// slow down.
  static const _retryAfter = Duration(minutes: 5);

  /// Fetches a web address, giving its status and text.
  final Future<(int, String)> Function(Uri) _get;

  /// Apple allows about 20 searches a minute.
  final Duration pause;

  /// MusicBrainz allows one request a second.
  final Duration musicBrainzPause;
  final DateTime Function() _clock;

  final _found = <String, String>{};
  final _notFound = <int>{};
  DateTime? _lastSearch;
  DateTime? _tryAgainAt;

  bool get busy => _busy;
  bool _busy = false;

  /// Songs of an album share a cover; songs without one are on their own.
  static String _key(Song song) {
    final album = searchKey(song.album ?? '');
    return album.isEmpty ? '${song.id}' : '${searchKey(song.albumArtist ?? song.artistName)}\n$album';
  }

  /// The address of [song]'s cover, if it's been found.
  String? cover(Song song) => _found[_key(song)];

  /// Whether [song] is worth searching for now.
  bool wants(Song song) {
    if (_found.containsKey(_key(song)) || _notFound.contains(song.id)) return false;
    final tryAgainAt = _tryAgainAt;
    return tryAgainAt == null || !_clock().isBefore(tryAgainAt);
  }

  Future<String?> _fromApple(Song song) async {
    final wanted = wantedTags(song);
    final (status, body) = await _get(iTunesSearch(wanted.title, wanted.artist));
    if (status != 200) throw HttpException('iTunes Search answered $status');
    return discordCover(body, song);
  }

  Future<String?> _fromMusicBrainz(Song song) async {
    final wanted = wantedTags(song);
    await Future<void>.delayed(musicBrainzPause);
    final (status, body) = await _get(musicBrainzSearch(wanted.title, wanted.artist, song.duration));
    if (status != 200) throw HttpException('MusicBrainz answered $status');
    final match = chooseMusicBrainz(body, title: wanted.title, artist: wanted.artist, album: song.album, length: song.duration);
    final group = match?.group;
    if (match == null || group == null || !coverFits(song.album, match.tags)) return null;
    final (coverStatus, covers) = await _get(Uri.https('coverartarchive.org', '/release-group/$group'));
    if (coverStatus == 404) return null;
    if (coverStatus != 200) throw HttpException('The Cover Art Archive answered $coverStatus');
    return hasFrontCover(covers) ? match.tags.cover : null;
  }

  /// Searches for [song]'s cover, going on to the next service if one has
  /// none or can't be reached, or answers with something unexpected. If
  /// nothing was found and a service failed, that isn't held against the
  /// song, so it's tried again later.
  Future<void> find(Song song) async {
    if (_busy) return;
    _busy = true;
    try {
      if (_lastSearch case final last?) {
        final wait = last.add(pause).difference(_clock());
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      _lastSearch = _clock();
      var failed = false;
      for (final search in [_fromApple, _fromMusicBrainz]) {
        try {
          if (await search(song) case final cover?) {
            _found[_key(song)] = cover;
            return;
          }
        } on Object {
          failed = true;
        }
      }
      if (failed) {
        _tryAgainAt = _clock().add(_retryAfter);
      } else {
        _notFound.add(song.id);
      }
    } finally {
      _busy = false;
    }
  }
}

/// What Discord shows for [song], which started at [start]. Discord moves the
/// progress bar along by itself from the start and end times. Blimp's logo
/// stands in for a [cover] that wasn't found, and sits on the corner of one
/// that was.
Map<String, Object?> discordActivity(
  Song song, {
  required DateTime start,
  Duration? length,
  double speed = 1,
  String? cover,
}) {
  final album = song.album?.trim() ?? '';
  final total = length ?? song.duration;
  return {
    'type': _listening,
    'details': _fitted(song.title),
    'details_url': ?discordSongLink(song),
    'state': _fitted(song.artistName),
    'timestamps': {
      'start': start.millisecondsSinceEpoch,
      if (total != null && total > Duration.zero) 'end': start.add(total * (1 / speed)).millisecondsSinceEpoch,
    },
    'assets': {
      'large_image': cover ?? _logo,
      if (album.isNotEmpty) 'large_text': _fitted(album),
      if (cover != null) 'small_image': _logo,
    },
  };
}

/// Shows the song playing on the user's Discord profile, while the setting
/// is on, through the Discord app on this PC. Nothing is shown while paused.
/// The Windows half is windows/runner/discord_status.cpp.
class DiscordStatus {
  DiscordStatus(this._music) {
    _music.discordStatus.addListener(_update);
    final player = _music.player;
    _subs = [
      player.sequenceStateStream.listen((_) => _update()),
      player.playerStateStream.listen((_) => _update()),
      player.positionDiscontinuityStream.listen((_) => _update()),
      player.durationStream.listen((_) => _update()),
      player.speedStream.listen((_) => _update()),
    ];
    // Seeks can report their position late, so this catches up with them.
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _update());
  }

  static const _channel = MethodChannel('blimp/discord');

  static Future<(int, String)> _fetch(Uri url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = 'Blimp (https://github.com/BersamaMus/Blimp)';
    try {
      final response = await (await client.getUrl(url)).close().timeout(const Duration(seconds: 10));
      final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
      return (response.statusCode, body);
    } finally {
      client.close(force: true);
    }
  }

  /// How far the progress bar can be out before it's worth sending again.
  /// Discord limits how often a status can change.
  static const _drift = Duration(seconds: 3);

  /// How long a new song waits for its cover before showing with the logo,
  /// so a slow search doesn't leave the last song showing.
  static const _coverWait = Duration(seconds: 4);

  final MusicController _music;
  late final List<StreamSubscription<Object?>> _subs;
  late final Timer _timer;
  final _covers = DiscordCovers(_fetch);

  /// The song waiting for its cover, and since when.
  int? _waitingSong;
  DateTime? _waitingSince;
  Timer? _waitTimer;

  /// What Discord was last sent, null for nothing showing.
  int? _shownSong;
  DateTime? _shownStart;
  Duration? _shownLength;
  double? _shownSpeed;
  String? _shownCover;

  Future<void> _update() async {
    final player = _music.player;
    final song = _music.currentSong;
    final playing = player.playing && player.processingState != ProcessingState.completed;
    if (!_music.discordStatus.value || song == null || !playing) {
      if (_shownSong == null) return;
      _shownSong = null;
      return _invoke('clear');
    }
    // Waits for the cover, rather than showing the logo for a moment first,
    // though not for long.
    if (_covers.wants(song)) {
      if (!_covers.busy) unawaited(_covers.find(song).whenComplete(_update));
      if (song.id != _waitingSong) {
        _waitingSong = song.id;
        _waitingSince = DateTime.now();
        _waitTimer?.cancel();
        _waitTimer = Timer(_coverWait, _update);
      }
      if (DateTime.now().difference(_waitingSince!) < _coverWait) return;
    }
    final cover = _covers.cover(song);
    final start = discordStart(player.position, now: DateTime.now(), speed: player.speed);
    final shownStart = _shownStart;
    if (song.id == _shownSong &&
        player.duration == _shownLength &&
        player.speed == _shownSpeed &&
        cover == _shownCover &&
        shownStart != null &&
        start.difference(shownStart).abs() < _drift) {
      return;
    }
    _shownSong = song.id;
    _shownStart = start;
    _shownLength = player.duration;
    _shownSpeed = player.speed;
    _shownCover = cover;
    await _invoke('show', {
      'applicationId': discordApplicationId,
      'activity': jsonEncode(
        discordActivity(song, start: start, length: player.duration, speed: player.speed, cover: cover),
      ),
    });
  }

  static Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod(method, arguments);
    } on MissingPluginException {
      // Not on Windows: there's no Discord status to update.
    }
  }

  void dispose() {
    _timer.cancel();
    _waitTimer?.cancel();
    _music.discordStatus.removeListener(_update);
    for (final sub in _subs) {
      sub.cancel();
    }
  }
}
