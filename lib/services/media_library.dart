import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'desktop_library.dart';
import 'genres.dart';
import 'lyrics.dart';
import 'search_text.dart';

class Song {
  Song({
    required this.id,
    required this.title,
    required this.uri,
    this.artist,
    this.album,
    this.albumId,
    this.albumArtist,
    this.compilation = false,
    this.duration,
    this.track,
    this.disc,
    this.spoken = false,
    this.year,
    this.genre,
    this.dateAdded,
    this.size = 0,
    this.path,
  });

  factory Song.fromMap(Map<Object?, Object?> map) {
    return Song(
      id: map['id'] as int,
      title: map['title'] as String? ?? 'Unknown title',
      uri: map['uri'] as String,
      artist: map['artist'] as String?,
      album: map['album'] as String?,
      albumId: map['albumId'] as int?,
      albumArtist: map['albumArtist'] as String?,
      compilation: map['compilation'] as bool? ?? false,
      duration: Duration(milliseconds: map['duration'] as int? ?? 0),
      track: map['track'] as int?,
      disc: map['disc'] as int?,
      spoken: map['spoken'] as bool? ?? false,
      year: map['year'] as int?,
      genre: normalizeGenre(map['genre'] as String?),
      dateAdded: switch (map['dateAdded']) {
        final int seconds => DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
        _ => null,
      },
      size: map['size'] as int? ?? 0,
      path: map['path'] as String?,
    );
  }

  final int id;
  final String title;
  final String uri;
  final String? artist;
  final String? album;
  final int? albumId;

  /// Who the album is credited to, when tagged; it can differ from [artist],
  /// as on a compilation or a song with a guest.
  final String? albumArtist;

  /// Tagged as part of a compilation (various artists).
  final bool compilation;
  final Duration? duration;
  final int? track;

  /// Which disc of the album it's on, when tagged.
  final int? disc;

  /// A podcast or audiobook, as Android files it: listened to in sittings,
  /// so it carries on where it was left (see [ResumePoints]).
  final bool spoken;
  final int? year;
  final String? genre;
  final DateTime? dateAdded;

  /// File size in bytes.
  final int size;

  /// Where the file is, e.g. /storage/emulated/0/Music/Song.mp3; null if
  /// Android doesn't say.
  final String? path;

  /// The folder holding the file, e.g. /storage/emulated/0/Music.
  String? get folder => switch (path?.lastIndexOf('/')) {
        final int slash when slash > 0 => path!.substring(0, slash),
        _ => null,
      };

  /// The file's name, e.g. Song.mp3.
  String? get fileName => path?.substring(path!.lastIndexOf('/') + 1);

  static const unknownArtist = 'Unknown artist';

  String get artistName => artist ?? unknownArtist;

  /// Title, artist and album as search compares them (see [searchKey]),
  /// computed once; the title also sorts songs, ignoring case and accents.
  late final List<String> searchFields = [title, ?artist, ?album].map(searchKey).toList();

  @override
  bool operator ==(Object other) => other is Song && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// How a song's audio is encoded, read from the file.
class AudioFormat {
  const AudioFormat({this.mime, this.sampleRate, this.bitrate, this.bitsPerSample, this.channels});

  factory AudioFormat.fromMap(Map<Object?, Object?> map, Song song) {
    var bitrate = map['bitrate'] as int?;
    // Some files don't say; the average from size and length is close enough.
    final ms = song.duration?.inMilliseconds ?? 0;
    if ((bitrate == null || bitrate <= 0) && song.size > 0 && ms > 0) bitrate = song.size * 8 * 1000 ~/ ms;
    return AudioFormat(
      mime: map['mime'] as String?,
      sampleRate: map['sampleRate'] as int?,
      bitrate: bitrate,
      bitsPerSample: map['bitsPerSample'] as int?,
      channels: map['channels'] as int?,
    );
  }

  final String? mime;

  /// In Hz, e.g. 44100.
  final int? sampleRate;

  /// In bits per second.
  final int? bitrate;
  final int? bitsPerSample;
  final int? channels;

  static const _codecs = {
    'audio/mpeg': 'MP3',
    'audio/mp4a-latm': 'AAC',
    'audio/aac': 'AAC',
    'audio/flac': 'FLAC',
    'audio/x-flac': 'FLAC',
    'audio/alac': 'ALAC',
    'audio/raw': 'WAV',
    'audio/wav': 'WAV',
    'audio/x-wav': 'WAV',
    'audio/opus': 'Opus',
    'audio/vorbis': 'Ogg Vorbis',
    'audio/ogg': 'Ogg',
    'audio/3gpp': 'AMR',
    'audio/amr-wb': 'AMR-WB',
    'audio/ac3': 'AC-3',
    'audio/eac3': 'E-AC-3',
    'audio/x-ms-wma': 'WMA',
  };

  String? get codec => switch (mime) {
        null => null,
        final mime => _codecs[mime] ?? mime.split('/').last.toUpperCase(),
      };

  /// Lossless files are described by bit depth; their bitrate just follows
  /// how busy the music is.
  bool get isLossless => const {'FLAC', 'ALAC', 'WAV'}.contains(codec);

  /// Better than CD quality (16-bit, 44.1 kHz), as labelled in stores.
  bool get isHiRes => isLossless && ((bitsPerSample ?? 0) > 16 || (sampleRate ?? 0) > 48000);

  /// E.g. "320 kbps".
  String? get bitrateText => switch (bitrate) {
        final rate? when rate > 0 => '${(rate / 1000).round()} kbps',
        _ => null,
      };

  /// E.g. "44.1 kHz".
  String? get sampleRateText => switch (sampleRate) {
        final hz? when hz > 0 => '${_trim(hz / 1000)} kHz',
        _ => null,
      };

  /// E.g. "MP3 · 320 kbps · 44.1 kHz" or "FLAC · 24-bit · 96 kHz".
  String get label {
    final bits = bitsPerSample;
    return [
      ?codec,
      if (isLossless && bits != null) '$bits-bit' else ?bitrateText,
      ?sampleRateText,
      if (channels == 1) 'Mono',
    ].join(' · ');
  }

  /// 44.1 stays 44.1, 48.0 becomes 48.
  static String _trim(double value) => value == value.roundToDouble() ? '${value.round()}' : value.toStringAsFixed(1);
}

/// A pending artwork load that can be cancelled when its widget goes away.
class ArtworkRequest {
  ArtworkRequest._(this.future, this._cancel);

  final Future<Uint8List?> future;
  final void Function() _cancel;

  /// Drops the load if it hasn't started and nothing else is waiting for it.
  void cancel() => _cancel();
}

class _PendingArtwork {
  final completer = Completer<Uint8List?>();
  int listeners = 0;
}

/// A small least-recently-used cache.
class _LruCache<K, V> {
  _LruCache(this.capacity);

  final int capacity;
  // Map literals keep insertion order, so the first key is the least recent.
  final _map = <K, V>{};

  bool containsKey(K key) => _map.containsKey(key);

  V? operator [](K key) {
    if (!_map.containsKey(key)) return null;
    final value = _map.remove(key) as V;
    return _map[key] = value;
  }

  void operator []=(K key, V value) {
    _map.remove(key);
    _map[key] = value;
    if (_map.length > capacity) _map.remove(_map.keys.first);
  }
}

/// Reads songs and artwork from Android's MediaStore via the platform channel
/// implemented in MainActivity.kt.
class MediaLibrary {
  MediaLibrary._();

  static const _channel = MethodChannel('blimp/media');

  /// Pixel size of list thumbnails and of the full-screen player artwork.
  static const thumbnailSize = 256;
  static const largeSize = 1024;

  // Bounded so memory stays flat however far the user scrolls. Thumbnails are
  // ~10-20 KB of JPEG each; large covers ~150 KB.
  static final _thumbnails = _LruCache<int, Uint8List?>(400);
  static final _largeArtwork = _LruCache<int, Uint8List?>(6);
  static final _colorCache = _LruCache<int, Color?>(400);

  // Few loads at once, newest first: when flinging through a list, the rows
  // on screen now matter more than ones that already scrolled past.
  static const _maxConcurrentLoads = 3;
  static final _queue = <(int, int), _PendingArtwork>{};
  static final _loading = <(int, int), _PendingArtwork>{};

  static Future<List<Song>> getSongs() async {
    if (isDesktop) return DesktopLibrary.getSongs();
    final result = await _channel.invokeListMethod<Map<Object?, Object?>>('getSongs');
    return (result ?? []).map(Song.fromMap).toList();
  }

  static final _formats = _LruCache<int, Future<AudioFormat?>>(50);

  /// The song's codec, bitrate and so on; null if the file can't be read.
  static Future<AudioFormat?> getAudioFormat(Song song) {
    if (_formats[song.id] case final format?) return format;
    return _formats[song.id] = _channel
        .invokeMapMethod<Object?, Object?>('getAudioFormat', {'id': song.id})
        .then((map) => map == null || map.isEmpty ? null : AudioFormat.fromMap(map, song))
        .catchError((Object _) => null);
  }

  /// How many slices of a song its waveform has.
  static const waveformPoints = 100;

  static final _waveforms = _LruCache<int, Future<Uint8List?>>(10);
  static final _loadedWaveforms = _LruCache<int, Uint8List>(10);

  /// How loud each of [waveformPoints] slices of the song is, 0..255, for
  /// the waveform seek bar; null if the file can't be decoded. The first
  /// time for a song takes a moment while it's decoded; after that it's
  /// saved.
  static Future<Uint8List?> getWaveform(int songId) {
    if (_waveforms[songId] case final waveform?) return waveform;
    return _waveforms[songId] = _channel
        .invokeMethod<Uint8List>('getWaveform', {'id': songId, 'points': waveformPoints})
        .then((levels) {
          if (levels != null) _loadedWaveforms[songId] = levels;
          return levels;
        })
        .catchError((Object _) => null);
  }

  /// The song's waveform if it's been loaded lately, so it shows at once.
  static Uint8List? cachedWaveform(int songId) => _loadedWaveforms[songId];

  /// The song's file name, full path and when it was last modified; null if
  /// it can't be read.
  static Future<({String? name, String? path, DateTime? modified})?> getFileInfo(Song song) async {
    if (isDesktop) {
      // The scan already has the path; Windows has no media index to ask.
      final path = song.path;
      if (path == null) return null;
      try {
        return (name: song.fileName, path: path, modified: File(path).lastModifiedSync());
      } on FileSystemException {
        return null;
      }
    }
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('getFileInfo', {'id': song.id});
      if (map == null || map.isEmpty) return null;
      return (
        name: map['name'] as String?,
        path: map['path'] as String?,
        modified: switch (map['modified']) {
          final int seconds => DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
          _ => null,
        },
      );
    } on PlatformException {
      return null;
    }
  }

  static final _gains = _LruCache<int, Future<double?>>(50);

  /// How many decibels to change the song's volume by so it plays about as
  /// loud as others: from its ReplayGain tag, or measured from it. Null if
  /// it can't be told. Measuring takes a moment the first time.
  static Future<double?> getGain(Song song) {
    if (_gains[song.id] case final gain?) return gain;
    return _gains[song.id] = _channel
        .invokeMethod<double>('getGain', {'id': song.id})
        .catchError((Object _) => null);
  }

  /// The release type ("album", "ep" or "single") tagged in each of the
  /// songs with [ids] that has one. Slow the first time for each song, as
  /// its tags are read; null if they can't be.
  static Future<Map<int, String>?> getReleaseTypes(List<int> ids) async {
    if (isDesktop) return null;
    try {
      final types = await _channel.invokeMapMethod<String, String>('getReleaseTypes', {'ids': ids});
      return {
        for (final MapEntry(:key, :value) in (types ?? const {}).entries)
          ?int.tryParse(key): value,
      };
    } on PlatformException {
      return null;
    }
  }

  /// The ids of [songs] that are hi-res (lossless, better than CD quality).
  /// Slow the first time for each lossless song, as its file is opened;
  /// empty if they can't be checked.
  static Future<Set<int>> getHiRes(List<Song> songs) async {
    if (isDesktop) return const {};
    try {
      final ids = await _channel.invokeListMethod<int>('getHiRes', {
        'songs': [
          for (final s in songs) {'id': s.id, 'path': s.path},
        ],
      });
      return {...?ids};
    } on PlatformException {
      return const {};
    }
  }

  static final _lyrics = _LruCache<int, Future<Lyrics?>>(20);

  /// The song's lyrics, from its tags or a .lrc file beside it; null if it
  /// has none.
  static Future<Lyrics?> getLyrics(Song song) {
    if (_lyrics[song.id] case final lyrics?) return lyrics;
    return _lyrics[song.id] = _channel
        .invokeMethod<String>('getLyrics', {'id': song.id})
        .then((raw) => raw == null ? null : parseLyrics(raw))
        .catchError((Object _) => null);
  }

  /// Sends the song's file to another app, through Android's share sheet.
  static Future<void> shareSong(Song song) async {
    if (isDesktop) return;
    try {
      await _channel.invokeMethod('shareSong', {'id': song.id, 'title': song.title});
    } on PlatformException {
      // The share sheet couldn't open; nothing else to do.
    }
  }

  /// Opens the folder holding [path] in the Files app; false if none could.
  static Future<bool> openFolder(String path) async {
    if (isDesktop) {
      // Opens its folder in Explorer with the file selected. Explorer wants
      // backslashes, and exits with 1 even when it opens fine.
      if (!Platform.isWindows) return false;
      await Process.run('explorer', ['/select,${path.replaceAll('/', r'\')}']);
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>('openFolder', {'path': path}) ?? false;
    } on PlatformException {
      return false;
    }
  }

  static _LruCache<int, Uint8List?> _cacheFor(int size) => size == largeSize ? _largeArtwork : _thumbnails;

  /// Whether artwork for [songId] at [size] has already been loaded,
  /// so widgets can paint it on the first frame instead of flickering.
  static bool hasCachedArtwork(int songId, int size) => _cacheFor(size).containsKey(songId);

  static Uint8List? cachedArtwork(int songId, int size) => _cacheFor(size)[songId];

  static Future<Uint8List?> getArtwork(int songId, {int size = thumbnailSize}) =>
      requestArtwork(songId, size: size).future;

  static ArtworkRequest requestArtwork(int songId, {int size = thumbnailSize}) {
    final cache = _cacheFor(size);
    if (cache.containsKey(songId)) return ArtworkRequest._(Future.value(cache[songId]), () {});

    final key = (songId, size);
    final pending = _loading[key] ?? _queue.remove(key) ?? _PendingArtwork();
    pending.listeners++;
    // (Re)inserting moves it to the back of the queue, which is served first.
    if (!_loading.containsKey(key)) _queue[key] = pending;
    _pump();

    var cancelled = false;
    return ArtworkRequest._(pending.completer.future, () {
      if (cancelled) return;
      cancelled = true;
      if (--pending.listeners == 0 && _queue.remove(key) != null) {
        pending.completer.complete(null);
      }
    });
  }

  static void _pump() {
    while (_loading.length < _maxConcurrentLoads && _queue.isNotEmpty) {
      final key = _queue.keys.last;
      final pending = _queue.remove(key)!;
      _loading[key] = pending;
      final (songId, size) = key;
      _channel
          .invokeMethod<Uint8List>('getArtwork', {'id': songId, 'size': size})
          .catchError((Object _) => null)
          .then((bytes) {
            _cacheFor(size)[songId] = bytes;
            _loading.remove(key);
            pending.completer.complete(bytes);
            _pump();
          });
    }
  }

  /// The most vivid color of the song's artwork, used to tint the player and
  /// collection headers. Null when the song has no artwork.
  static Future<Color?> getDominantColor(int songId) async {
    if (_colorCache.containsKey(songId)) return _colorCache[songId];
    final bytes = await getArtwork(songId);
    if (bytes == null) return _colorCache[songId] = null;

    final ByteData? data;
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 12, targetHeight: 12);
      final image = (await codec.getNextFrame()).image;
      codec.dispose();
      data = await image.toByteData();
      image.dispose();
    } on Exception {
      // A cover Flutter can't decode: no colour, same as no cover.
      return _colorCache[songId] = null;
    }
    if (data == null) return _colorCache[songId] = null;

    // Average the pixels, weighting saturated ones more so a colorful cover
    // isn't washed out by a gray or black background.
    double r = 0, g = 0, b = 0, total = 0;
    for (var i = 0; i < data.lengthInBytes; i += 4) {
      final pr = data.getUint8(i), pg = data.getUint8(i + 1), pb = data.getUint8(i + 2);
      final maxC = pr > pg ? (pr > pb ? pr : pb) : (pg > pb ? pg : pb);
      final minC = pr < pg ? (pr < pb ? pr : pb) : (pg < pb ? pg : pb);
      final weight = 0.1 + (maxC - minC) / 255;
      r += pr * weight;
      g += pg * weight;
      b += pb * weight;
      total += weight;
    }
    return _colorCache[songId] =
        Color.fromARGB(255, (r / total).round(), (g / total).round(), (b / total).round());
  }
}
