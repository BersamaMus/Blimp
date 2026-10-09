import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'media_library.dart';

/// Whether this is the desktop app, which finds songs by scanning a music
/// folder instead of asking Android for them.
final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// The desktop app's library: the audio files in one folder and those under
/// it, read from their tags.
abstract final class DesktopLibrary {
  static const _folderKey = 'desktopMusicFolder';

  static const _extensions = {'mp3', 'flac', 'm4a', 'aac', 'alac', 'ogg', 'oga', 'opus', 'wav', 'wma', 'aiff', 'aif'};

  /// The user's Music folder, e.g. C:/Users/Ana/Music.
  static String get defaultFolder =>
      '${Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? ''}/Music'.replaceAll(r'\', '/');

  /// The folder scanned for songs: the one picked in Settings, or Music.
  static Future<String> musicFolder() async =>
      (await SharedPreferences.getInstance()).getString(_folderKey) ?? defaultFolder;

  static Future<void> setMusicFolder(String path) async =>
      (await SharedPreferences.getInstance()).setString(_folderKey, path.replaceAll(r'\', '/'));

  /// Every song in [musicFolder]. Tags are read off the UI thread, as a big
  /// library takes a while.
  static Future<List<Song>> getSongs() async {
    final folder = await musicFolder();
    final maps = await Isolate.run(() => _scan(folder));
    return maps.map(Song.fromMap).toList();
  }

  static List<Map<String, Object?>> _scan(String root) {
    final songs = <Map<String, Object?>>[];
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
        if (entry is Directory) {
          pending.add(entry);
        } else if (entry is File && _extensions.contains(_extension(entry.path))) {
          if (_read(entry) case final song?) songs.add(song);
        }
      }
    }
    return songs;
  }

  /// [file] as the map [Song.fromMap] takes, as Android sends songs; null
  /// if it's gone.
  static Map<String, Object?>? _read(File file) {
    final FileStat stat;
    try {
      stat = file.statSync();
    } on FileSystemException {
      return null;
    }
    AudioMetadata? tags;
    try {
      tags = readMetadata(file);
    } catch (_) {
      // Untagged or a format the reader doesn't know: still listed, by name.
    }
    // Forward slashes, as Android paths have; the folder views split on them.
    final path = file.path.replaceAll(r'\', '/');
    final name = path.substring(path.lastIndexOf('/') + 1);
    final folder = path.substring(0, path.lastIndexOf('/'));
    final album = _text(tags?.album);
    final albumArtist = _text(tags?.albumArtist);
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
      'dateAdded': stat.modified.millisecondsSinceEpoch ~/ 1000,
      'size': stat.size,
      'path': path,
    };
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
