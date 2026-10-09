import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'media_library.dart';

/// Whether this is the desktop app, which finds songs by scanning a music
/// folder instead of asking Android for them.
final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// The desktop app's library: the audio files in one folder and those under
/// it, read from their tags. What Android's media index and Blimp's Kotlin
/// code tell the phone app, this works out from the files themselves.
abstract final class DesktopLibrary {
  static const _folderKey = 'desktopMusicFolder';

  static const _extensions = {'mp3', 'flac', 'm4a', 'aac', 'alac', 'ogg', 'oga', 'opus', 'wav', 'wma', 'aiff', 'aif'};

  /// What each scanned song's file says beyond what [Song] holds (format,
  /// ReplayGain, release type), by song id; see [_read].
  static Map<int, Map<String, Object?>> _details = {};

  /// The user's Music folder, e.g. C:/Users/Ana/Music.
  static String get defaultFolder =>
      '${Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? ''}/Music'.replaceAll(r'\', '/');

  /// The folder scanned for songs: the one picked in Settings, or Music.
  static Future<String> musicFolder() async =>
      (await SharedPreferences.getInstance()).getString(_folderKey) ?? defaultFolder;

  static Future<void> setMusicFolder(String path) async =>
      (await SharedPreferences.getInstance()).setString(_folderKey, path.replaceAll(r'\', '/'));

  /// Where the scan and shrunk covers are kept: the local cache folder, as
  /// both can be made again (on Windows, AppData\Local, not the Roaming
  /// folder that follows the user between PCs). Tests point it elsewhere.
  @visibleForTesting
  static String? cachePathOverride;

  static Future<String> _cachePath() async => cachePathOverride ?? (await getApplicationCacheDirectory()).path;

  /// Every song in [musicFolder]. Tags are read off the UI thread, and only
  /// for files that changed since the last scan, which is saved.
  static Future<List<Song>> getSongs() async {
    final folder = await musicFolder();
    final cache = '${await _cachePath()}/desktop_library.json';
    final maps = await Isolate.run(() => _scan(folder, cache));
    _details = {for (final map in maps) map['id'] as int: map};
    return maps.map(Song.fromMap).toList();
  }

  // ---------------------------------------------------------------------
  // What MediaLibrary asks of Android, answered from the scan.

  /// The song's format, as read in the scan; null if it wasn't.
  static AudioFormat? audioFormat(Song song) => switch (_details[song.id]) {
    final map? when map['mime'] != null => AudioFormat.fromMap(map, song),
    _ => null,
  };

  /// ReplayGain's track gain, in dB, when tagged.
  static double? gain(Song song) => _details[song.id]?['gain'] as double?;

  /// The release type ("album", "ep" or "single") of each of [ids] tagged
  /// with one.
  static Map<int, String> releaseTypes(List<int> ids) => {
    for (final id in ids)
      if (_details[id]?['releaseType'] case final String type) id: type,
  };

  /// The ids of [songs] that are hi-res (lossless, better than CD quality).
  static Set<int> hiRes(List<Song> songs) => {
    for (final song in songs)
      if (audioFormat(song)?.isHiRes ?? false) song.id,
  };

  /// The song's lyrics, from its tags or a .lrc file beside it.
  static Future<String?> lyrics(Song song) async {
    final path = song.path;
    if (path == null) return null;
    return Isolate.run(() => _readLyrics(path));
  }

  static String? _readLyrics(String path) {
    String? text;
    try {
      text = readMetadata(File(path)).lyrics;
    } catch (_) {
      // Unreadable tags: try for a .lrc file instead.
    }
    if (text == null || text.trim().isEmpty) {
      final lrc = File('${path.substring(0, path.lastIndexOf('.'))}.lrc');
      try {
        if (lrc.existsSync()) text = lrc.readAsStringSync();
      } on FileSystemException {
        return null;
      }
    }
    final cleaned = text?.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
    return cleaned == null || cleaned.isEmpty ? null : cleaned;
  }

  /// Covers kept beside the songs, used when a file has none of its own.
  static const _folderCovers = ['cover', 'folder', 'front', 'album', 'albumart'];
  static const _imageExtensions = ['jpg', 'jpeg', 'png'];

  /// The song's cover at most [size] pixels across, as PNG; null if it has
  /// none. Covers are read from the file (or one beside it) and shrunk once,
  /// then kept on disk, as reading and shrinking them takes a moment.
  static Future<Uint8List?> artwork(int songId, int size) async => (await _artworkFile(songId, size))?.readAsBytes();

  /// Where the song's cover at [size] is saved, for Windows' media controls,
  /// which take a file; null if it has none.
  static Future<String?> artworkPath(int songId, int size) async => (await _artworkFile(songId, size))?.path;

  static const _waveformChannel = MethodChannel('blimp/waveform');

  /// How loud the song is across [points] equal slices of it, each 0..255
  /// (255 the loudest slice), for the waveform seek bar; null if the file
  /// can't be decoded. Windows decodes it (windows/runner/waveform.cpp),
  /// once per song: it's then kept on disk.
  static Future<Uint8List?> waveform(int songId, int points) async {
    final details = _details[songId];
    final path = details?['path'] as String?;
    if (path == null) return null;
    // Named by when the song's file changed, as covers are.
    final cached = File('${await _cachePath()}/waveforms/${songId}_${points}_${details!['dateAdded']}');
    if (await cached.exists()) return cached.readAsBytes();
    final levels = await _waveformChannel.invokeMethod<Float64List>('levels', {'path': path, 'points': points});
    if (levels == null || levels.isEmpty) return null;
    final loudest = levels.reduce(max);
    if (loudest <= 0) return null;
    final bytes = Uint8List.fromList([for (final level in levels) (level / loudest * 255).round().clamp(0, 255)]);
    await cached.parent.create(recursive: true);
    await cached.writeAsBytes(bytes);
    return bytes;
  }

  /// The saved PNG of the song's cover at [size], made if it isn't yet;
  /// null if the song has no cover.
  static Future<File?> _artworkFile(int songId, int size) async {
    final details = _details[songId];
    final path = details?['path'] as String?;
    if (path == null) return null;
    // Named by when the song's file changed, so a new cover is picked up.
    final cached = File('${await _cachePath()}/artwork/${songId}_${size}_${details!['dateAdded']}.png');
    if (!await cached.exists()) {
      final original = await Isolate.run(() => _readCover(path));
      final shrunk = original == null ? null : await _shrink(original, size);
      await cached.parent.create(recursive: true);
      await cached.writeAsBytes(shrunk ?? Uint8List(0));
    }
    // Empty means it was looked for before and has none.
    return await cached.length() == 0 ? null : cached;
  }

  static Uint8List? _readCover(String path) {
    try {
      final pictures = readMetadata(File(path), getImage: true).pictures;
      final front = pictures.where((p) => p.pictureType == PictureType.coverFront).firstOrNull ?? pictures.firstOrNull;
      if (front != null && front.bytes.isNotEmpty) return front.bytes;
    } catch (_) {
      // Unreadable tags: look beside the file instead.
    }
    final folder = path.substring(0, path.lastIndexOf('/'));
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(folder).listSync(followLinks: false);
    } on FileSystemException {
      return null;
    }
    // Windows names ignore case: Folder.jpg is folder.jpg.
    final byName = {
      for (final entry in entries)
        if (entry is File) entry.path.replaceAll(r'\', '/').split('/').last.toLowerCase(): entry,
    };
    for (final name in _folderCovers) {
      for (final ext in _imageExtensions) {
        if (byName['$name.$ext'] case final file?) return file.readAsBytesSync();
      }
    }
    return null;
  }

  /// [bytes] decoded and, if bigger, shrunk to [size] across; null if they
  /// aren't an image Flutter can read.
  static Future<Uint8List?> _shrink(Uint8List bytes, int size) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final wide = descriptor.width >= descriptor.height;
      final big = (wide ? descriptor.width : descriptor.height) > size;
      final codec = await descriptor.instantiateCodec(
        targetWidth: big && wide ? size : null,
        targetHeight: big && !wide ? size : null,
      );
      final image = (await codec.getNextFrame()).image;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
      return png?.buffer.asUint8List();
    } on Exception {
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // Scanning, in background isolates.

  /// Bump when [_read] learns something new, so files are read afresh.
  static const _cacheVersion = 2;

  static Future<List<Map<String, Object?>>> _scan(String root, String cachePath) async {
    final cacheFile = File(cachePath);
    // path -> {modified, size, song}; files unchanged since are not re-read.
    var cached = <String, Object?>{};
    try {
      final json = jsonDecode(cacheFile.readAsStringSync()) as Map<String, Object?>;
      if (json['version'] == _cacheVersion) cached = json['files'] as Map<String, Object?>;
    } catch (_) {
      // No cache yet, or an unreadable one: everything is read.
    }

    // Find the files first; that's quick. Reading their tags isn't.
    final found = <({String path, int modified, int size})>[];
    final pending = [Directory(root)];
    while (pending.isNotEmpty) {
      final List<FileSystemEntity> entries;
      try {
        entries = pending.removeLast().listSync(followLinks: false);
      } on FileSystemException {
        // A folder Windows won't let us into: skip it, keep the rest.
        continue;
      }
      for (final entry in entries) {
        final path = entry.path.replaceAll(r'\', '/');
        final name = path.substring(path.lastIndexOf('/') + 1);
        // Hidden folders, and what macOS leaves in zips (__MACOSX, and ._
        // files that only look like songs).
        if (name.startsWith('.') || name == '__MACOSX') continue;
        if (entry is Directory) {
          pending.add(entry);
        } else if (entry is File && _extensions.contains(_extension(name))) {
          try {
            final stat = entry.statSync();
            found.add((path: path, modified: stat.modified.millisecondsSinceEpoch, size: stat.size));
          } on FileSystemException {
            continue;
          }
        }
      }
    }

    final songs = <String, Map<String, Object?>>{
      for (final file in found)
        if (cached[file.path] case {'modified': final m, 'size': final s, 'song': final Map<String, Object?> old}
            when m == file.modified && s == file.size)
          file.path: old,
    };
    // New and changed files, read a share per core: on a first scan, this
    // is most of the wait.
    final unread = [
      for (final file in found)
        if (!songs.containsKey(file.path)) file,
    ];
    final workers = Platform.numberOfProcessors.clamp(1, 8);
    final batches = await Future.wait([
      for (var w = 0; w < workers && w < unread.length; w++)
        Isolate.run(
          () => [
            for (var i = w; i < unread.length; i += workers) _read(unread[i].path, unread[i].modified, unread[i].size),
          ],
        ),
    ]);
    for (final song in batches.expand((batch) => batch)) {
      songs[song['path'] as String] = song;
    }

    try {
      cacheFile.parent.createSync(recursive: true);
      cacheFile.writeAsStringSync(
        jsonEncode({
          'version': _cacheVersion,
          'files': {
            for (final file in found)
              file.path: {'modified': file.modified, 'size': file.size, 'song': songs[file.path]},
          },
        }),
      );
    } on FileSystemException {
      // Not saved: the next scan reads everything again, that's all.
    }
    return [for (final file in found) songs[file.path]!];
  }

  /// The file at [path] as the map [Song.fromMap] takes, as Android sends songs, plus
  /// its format, ReplayGain and release type.
  static Map<String, Object?> _read(String path, int modified, int size) {
    final file = File(path);
    AudioMetadata? tags;
    try {
      tags = readMetadata(file);
    } catch (_) {
      // Untagged or a format the reader doesn't know: still listed, by name.
    }
    final custom = _customTags(file);
    final header = _header(file);
    final ext = _extension(path);
    final name = path.substring(path.lastIndexOf('/') + 1);
    final folder = path.substring(0, path.lastIndexOf('/'));
    final album = _text(tags?.album);
    final albumArtist = _text(tags?.albumArtist);
    final lossless = const {'flac', 'wav', 'aiff', 'aif', 'alac'}.contains(ext);
    return {
      // Windows paths ignore case, so the same file keeps its id however
      // it's spelled.
      'id': stableId(path.toLowerCase()),
      'title': _text(tags?.title) ?? name.substring(0, name.lastIndexOf('.')),
      'uri': file.uri.toString(),
      'artist': _text(tags?.artist),
      'album': album,
      // An album is its name and who it's by, or else its folder, so two
      // albums both called "Greatest Hits" stay apart.
      'albumId': album == null ? null : stableId('${(albumArtist ?? folder).toLowerCase()}\n${album.toLowerCase()}'),
      'albumArtist': albumArtist,
      'duration': tags?.duration?.inMilliseconds,
      'track': tags?.trackNumber,
      'disc': tags?.discNumber,
      'year': tags?.year?.year,
      'genre': tags?.genres.map(_text).nonNulls.firstOrNull,
      'dateAdded': modified ~/ 1000,
      'size': size,
      'path': path,
      // As AudioFormat.fromMap reads them.
      'mime': _mimes[ext],
      'sampleRate': header?.sampleRate ?? tags?.sampleRate,
      // Lossless files show bit depth instead, and the reader's figure for
      // them isn't a bitrate; left out, it's worked out from size and length.
      'bitrate': lossless ? null : _bitsPerSecond(tags?.bitrate),
      'bitsPerSample': header?.bitsPerSample,
      'channels': header?.channels,
      'gain': _parseGain(custom['REPLAYGAIN_TRACK_GAIN']),
      'releaseType': parseReleaseType(_releaseTypeKeys.map((k) => custom[k]).nonNulls.firstOrNull),
    };
  }

  static const _mimes = {
    'mp3': 'audio/mpeg',
    'flac': 'audio/flac',
    'm4a': 'audio/mp4a-latm',
    'aac': 'audio/aac',
    'alac': 'audio/alac',
    'ogg': 'audio/vorbis',
    'oga': 'audio/vorbis',
    'opus': 'audio/opus',
    'wav': 'audio/wav',
    'wma': 'audio/x-ms-wma',
    'aiff': 'audio/aiff',
    'aif': 'audio/aiff',
  };

  /// The reader gives some formats' bitrates in kbps and others in bps.
  static int? _bitsPerSecond(int? rate) => switch (rate) {
    null || <= 0 => null,
    < 2000 => rate * 1000,
    _ => rate,
  };

  /// Where taggers such as MusicBrainz Picard put the release type, as the
  /// phone app reads it (EmbeddedLyrics.kt).
  static const _releaseTypeKeys = ['RELEASETYPE', 'MUSICBRAINZ_ALBUMTYPE', 'MUSICBRAINZ ALBUM TYPE'];

  /// The free-form tags (ID3 TXXX frames, Vorbis comments), upper-cased.
  static Map<String, String> _customTags(File file) {
    // The tag reader reads all of an MP3 to time it; its ID3 tag is at the
    // start, so read just that.
    if (_extension(file.path) == 'mp3') return id3UserText(file);
    final Object raw;
    try {
      raw = readAllMetadata(file, getImage: false);
    } catch (_) {
      return const {};
    }
    final tags = switch (raw) {
      Mp3Metadata(:final customMetadata) => customMetadata,
      VorbisMetadata(:final unknowns, :final replayGainTrackGain) => {
        ...unknowns,
        'REPLAYGAIN_TRACK_GAIN': ?replayGainTrackGain.firstOrNull,
      },
      ApeMetadata(:final unknowns) => unknowns,
      _ => const <String, String>{},
    };
    return {for (final MapEntry(:key, :value) in tags.entries) key.toUpperCase(): value};
  }

  /// No ID3 tag is read past this, so a damaged size can't take all the memory.
  static const _maxId3 = 16 << 20;

  /// The user text frames (TXXX) of the ID3v2.3 or 2.4 tag at the start of
  /// [file], by upper-cased description; empty if it has none. Tags that
  /// are unsynchronised, compressed or encrypted are skipped, as rare.
  @visibleForTesting
  static Map<String, String> id3UserText(File file) {
    final RandomAccessFile reader;
    try {
      reader = file.openSync();
    } on FileSystemException {
      return const {};
    }
    try {
      final header = reader.readSync(10);
      if (header.length < 10 || ascii.decode(header.sublist(0, 3), allowInvalid: true) != 'ID3') return const {};
      final version = header[3];
      final flags = header[5];
      if ((version != 3 && version != 4) || flags & 0x80 != 0) return const {};
      final size = _syncsafe(header, 6);
      final tag = reader.readSync(min(size, _maxId3));
      final data = ByteData.sublistView(tag);
      var at = 0;
      if (flags & 0x40 != 0 && tag.length >= 4) {
        // An extended header to skip.
        at = version == 4 ? _syncsafe(tag, 0) : data.getUint32(0) + 4;
      }
      final frames = <String, String>{};
      while (at + 10 <= tag.length) {
        final id = ascii.decode(tag.sublist(at, at + 4), allowInvalid: true);
        if (id.codeUnitAt(0) == 0) break; // padding
        final length = version == 4 ? _syncsafe(tag, at + 4) : data.getUint32(at + 4);
        final formatFlags = tag[at + 9];
        final start = at + 10;
        at = start + length;
        if (length <= 0 || at > tag.length) break;
        if (id != 'TXXX') continue;
        // Compressed, encrypted or unsynchronised frames aren't worth it here.
        if (version == 4 ? formatFlags & 0x0E != 0 : formatFlags & 0xC0 != 0) continue;
        final body = tag.sublist(start + (version == 4 && formatFlags & 0x01 != 0 ? 4 : 0), at);
        if (_userText(body) case (final description, final value)) frames[description.toUpperCase()] = value;
      }
      return frames;
    } on FileSystemException {
      return const {};
    } finally {
      reader.closeSync();
    }
  }

  static int _syncsafe(List<int> bytes, int at) =>
      (bytes[at] & 0x7F) << 21 | (bytes[at + 1] & 0x7F) << 14 | (bytes[at + 2] & 0x7F) << 7 | bytes[at + 3] & 0x7F;

  /// A TXXX frame's description and value: an encoding byte, then both,
  /// split by a terminator one byte wide, or two for UTF-16.
  static (String, String)? _userText(Uint8List body) {
    if (body.isEmpty) return null;
    final encoding = body[0];
    final wide = encoding == 1 || encoding == 2;
    var end = 1;
    while (wide ? end + 1 < body.length && (body[end] | body[end + 1]) != 0 : end < body.length && body[end] != 0) {
      end += wide ? 2 : 1;
    }
    if (end >= body.length) return null;
    String text(Uint8List bytes) {
      final decoded = switch (encoding) {
        0 => latin1.decode(bytes),
        3 => utf8.decode(bytes, allowMalformed: true),
        _ => _utf16(bytes, bigEndian: encoding == 2),
      };
      return decoded.replaceAll('\u0000', '').trim();
    }

    return (text(body.sublist(1, end)), text(body.sublist(end + (wide ? 2 : 1))));
  }

  /// UTF-16 text, its byte order from a BOM if it starts with one.
  static String _utf16(Uint8List bytes, {required bool bigEndian}) {
    var at = 0;
    if (bytes.length >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
      bigEndian = bytes[0] == 0xFE;
      at = 2;
    }
    final units = [
      for (var i = at; i + 1 < bytes.length; i += 2)
        bigEndian ? bytes[i] << 8 | bytes[i + 1] : bytes[i + 1] << 8 | bytes[i],
    ];
    return String.fromCharCodes(units);
  }

  /// "-6.54 dB" as -6.54.
  static double? _parseGain(String? value) => double.tryParse(
    (value ?? '').trim().replaceFirst(RegExp(r'\s*db$', caseSensitive: false), '').replaceAll(',', '.'),
  );

  /// The main type from a release type tag: "album; compilation" or
  /// "Album/Live" is an album. Null for types other than album, EP and single.
  static String? parseReleaseType(String? value) =>
      switch (value?.trim().toLowerCase().split(RegExp(r'[;,/\s]+')).first) {
        final type? when const {'album', 'ep', 'single'}.contains(type) => type,
        _ => null,
      };

  /// Sample rate, bit depth and channels from a FLAC or WAV file's header,
  /// which the tag reader doesn't give.
  static ({int sampleRate, int bitsPerSample, int channels})? _header(File file) {
    final RandomAccessFile reader;
    try {
      reader = file.openSync();
    } on FileSystemException {
      return null;
    }
    try {
      final head = reader.readSync(64);
      if (head.length < 26) return null;
      final data = ByteData.sublistView(head);
      final magic = ascii.decode(head.sublist(0, 4), allowInvalid: true);
      if (magic == 'fLaC' && head[4] & 0x7F == 0) {
        // STREAMINFO, the first block: 20 bits of sample rate, 3 of channels
        // less one, 5 of bits per sample less one, from byte 18.
        final packed = data.getUint32(18);
        return (
          sampleRate: packed >> 12,
          channels: ((packed >> 9) & 0x7) + 1,
          bitsPerSample: ((packed >> 4) & 0x1F) + 1,
        );
      }
      if (magic == 'RIFF' && ascii.decode(head.sublist(8, 12), allowInvalid: true) == 'WAVE') {
        // Chunks follow; "fmt " is almost always first.
        var at = 12;
        while (at + 8 <= head.length) {
          final id = ascii.decode(head.sublist(at, at + 4), allowInvalid: true);
          final length = data.getUint32(at + 4, Endian.little);
          if (id == 'fmt ' && at + 24 <= head.length) {
            return (
              channels: data.getUint16(at + 10, Endian.little),
              sampleRate: data.getUint32(at + 12, Endian.little),
              bitsPerSample: data.getUint16(at + 22, Endian.little),
            );
          }
          at += 8 + length;
        }
      }
      return null;
    } on FileSystemException {
      return null;
    } finally {
      reader.closeSync();
    }
  }

  static String _extension(String path) => path.substring(path.lastIndexOf('.') + 1).toLowerCase();

  static String? _text(String? s) => switch (s?.trim()) {
    final t? when t.isNotEmpty => t,
    _ => null,
  };

  /// A song id from [key] that stays the same between runs, as playlists,
  /// favourites and history are saved by id. FNV-1a, kept to 53 bits so it
  /// survives a round trip through JSON numbers.
  static int stableId(String key) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(key)) {
      hash ^= byte;
      hash *= 0x100000001b3;
    }
    return hash & 0x1FFFFFFFFFFFFF;
  }
}
