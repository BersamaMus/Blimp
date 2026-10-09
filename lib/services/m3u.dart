import 'dart:convert';

import 'media_library.dart';
import 'search_text.dart';

/// M3U playlists, the format most music players import and export.
abstract final class M3u {
  /// [songs] as an extended M3U playlist, by their full paths, which other
  /// Android players can open. Songs with no known file are left out.
  static String encode(List<Song> songs) {
    final out = StringBuffer('#EXTM3U\n');
    for (final song in songs) {
      final path = song.path;
      if (path == null) continue;
      final seconds = song.duration?.inSeconds ?? -1;
      out
        ..write('#EXTINF:${seconds > 0 ? seconds : -1},')
        ..write(song.artist == null ? song.title : '${song.artist} - ${song.title}')
        ..write('\n$path\n');
    }
    return out.toString();
  }

  /// The songs of [library] an M3U playlist lists, in its order, and how
  /// many entries couldn't be found. Entries are matched by path, then by
  /// the end of their path (for playlists made on a computer or another
  /// phone), then by the "Artist - Title" an extended playlist gives them.
  static ({List<Song> songs, int missing}) decode(String text, List<Song> library) {
    final match = _EntryMatcher(library);
    final songs = <Song>[];
    var missing = 0;
    String? described;
    for (var line in const LineSplitter().convert(text)) {
      line = line.trim().replaceFirst('﻿', '');
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        if (line.toUpperCase().startsWith('#EXTINF:')) {
          final comma = line.indexOf(',');
          described = comma < 0 ? null : line.substring(comma + 1).trim();
        }
        continue;
      }
      final song = match.find(line, described);
      described = null;
      if (song == null) {
        missing++;
      } else {
        songs.add(song);
      }
    }
    return (songs: songs, missing: missing);
  }
}

class _EntryMatcher {
  _EntryMatcher(List<Song> library) {
    for (final song in library) {
      final path = song.path;
      if (path != null) {
        _byPath.putIfAbsent(path.toLowerCase(), () => song);
        _byName.putIfAbsent(_segments(path).last, () => []).add(song);
      }
      _byTitle.putIfAbsent(_described(song.artist, song.title), () => song);
      _byTitle.putIfAbsent(searchKey(song.title), () => song);
    }
  }

  final _byPath = <String, Song>{};
  final _byName = <String, List<Song>>{};
  final _byTitle = <String, Song>{};

  static String _described(String? artist, String title) => searchKey(artist == null ? title : '$artist - $title');

  /// A path's folders and file name, lowercase, whichever slashes it uses.
  static List<String> _segments(String path) =>
      path.toLowerCase().split(RegExp(r'[\\/]+')).where((s) => s.isNotEmpty).toList();

  Song? find(String entry, String? described) {
    var path = entry;
    if (path.toLowerCase().startsWith('file://')) path = path.substring(7);
    try {
      path = Uri.decodeFull(path);
    } on ArgumentError {
      // Not encoded after all ("100%.mp3"): use it as it is.
    }
    if (_byPath[path.toLowerCase()] case final song?) return song;

    // The same file name, and as many of the folders above it as possible.
    final segments = _segments(path);
    final sameName = segments.isEmpty ? const <Song>[] : _byName[segments.last] ?? const <Song>[];
    Song? best;
    var bestShared = 0;
    if (sameName.isNotEmpty) {
      for (final song in sameName) {
        final theirs = _segments(song.path!);
        var shared = 0;
        while (shared < segments.length &&
            shared < theirs.length &&
            segments[segments.length - 1 - shared] == theirs[theirs.length - 1 - shared]) {
          shared++;
        }
        if (shared > bestShared) (best, bestShared) = (song, shared);
      }
      // A folder in common too: the same file.
      if (bestShared >= 2) return best;
    }

    // Only the file name in common, which names like "01 Intro.mp3" often
    // are: the title the playlist gives comes first, and the name counts only
    // if no other song here has it.
    if (described != null && described.isNotEmpty) {
      if (_byTitle[searchKey(described)] case final song?) return song;
    }
    return sameName.length == 1 ? best : null;
  }
}
