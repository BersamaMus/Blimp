import 'dart:convert';

import 'listening_log.dart';
import 'media_library.dart';
import 'playlists.dart';
import 'search_text.dart';

/// How a saved setting refers to songs, so a backup can be restored on
/// another phone, where Android numbers the same songs differently.
enum SongIds {
  /// A list of ids, as for favourites.
  list,

  /// "id:value" entries, as for play counts.
  keyed,

  /// Playlists, as [encodePlaylists] saves them.
  playlists,
}

/// What a backup brought back.
class RestoredBackup {
  RestoredBackup({required this.saved, required this.listens, required this.songsFound, required this.songsMissing});

  /// Settings to save, by key, with songs renumbered for this phone.
  final Map<String, Object?> saved;

  /// The listening log, renumbered. Listens to songs not on this phone keep
  /// counting toward totals, under ids no song has.
  final List<ListenEvent> listens;

  final int songsFound;
  final int songsMissing;
}

/// Backups are JSON files, marked so others aren't mistaken for them.
abstract final class Backup {
  static const _format = 'blimp-backup';
  static const _version = 1;

  /// A backup of [saved] (settings by key; those in [songKeys] refer to
  /// songs as described there) and the listening log [listens]. Each song
  /// they mention is described by its file and tags, so it can be found
  /// again on another phone.
  static String create({
    required Map<String, Object?> saved,
    required Map<String, SongIds> songKeys,
    required List<ListenEvent> listens,
    required Map<int, Song> songsById,
    required DateTime now,
  }) {
    final ids = <int>{for (final e in listens) e.songId};
    for (final MapEntry(:key, :value) in songKeys.entries) {
      ids.addAll(_idsIn(saved[key], value));
    }
    return const JsonEncoder.withIndent(' ').convert({
      'format': _format,
      'version': _version,
      'created': now.toIso8601String(),
      'songs': [
        for (final id in ids)
          if (songsById[id] case final song?)
            {
              'id': id,
              'path': ?song.path,
              'title': song.title,
              'artist': ?song.artist,
              'album': ?song.album,
            },
      ],
      'settings': saved,
      'listens': [for (final e in listens) e.encode()],
    });
  }

  /// Reads a backup made by [create], matching its songs to [library]: by
  /// file first, then by title, artist and album. Throws [FormatException]
  /// if [text] isn't a Blimp backup.
  static RestoredBackup restore(String text, {required Map<String, SongIds> songKeys, required List<Song> library}) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const FormatException("This isn't a Blimp backup.");
    }
    if (json is! Map || json['format'] != _format) throw const FormatException("This isn't a Blimp backup.");
    if (json['version'] case final int version when version > _version) {
      throw const FormatException('This backup is from a newer version of Blimp. Update the app to restore it.');
    }

    final match = _SongMatcher(library);
    final renumbered = <int, int>{};
    for (final song in _list(json['songs'])) {
      if (song is! Map) continue;
      final id = song['id'], found = match.find(song);
      if (id is int && found != null) renumbered[id] = found.id;
    }
    final mentioned = <int>{};
    int? renumber(int id) {
      mentioned.add(id);
      return renumbered[id];
    }

    final saved = <String, Object?>{};
    final settings = json['settings'];
    if (settings is Map) {
      for (final MapEntry(:key, :value) in settings.entries) {
        if (key is! String) continue;
        saved[key] = switch (songKeys[key]) {
          null => value,
          final kind => _renumber(value, kind, renumber),
        };
      }
    }

    final logged = [
      for (final line in _list(json['listens']))
        if (line is String) ?ListenEvent.decode(line),
    ];
    // A song not here gets an id no song has (Android's are all positive),
    // so its listening still counts toward totals. Ids already standing in
    // for a missing song (from an earlier restore) keep theirs, and each
    // newly missing song gets its own below them, so no two songs share one.
    var nextMissing = logged.fold(0, (low, e) => e.songId < low ? e.songId : low) - 1;
    final missingIds = <int, int>{};
    int idHere(int id) => id < 0 ? id : renumber(id) ?? missingIds.putIfAbsent(id, () => nextMissing--);
    final listens = [
      for (final e in logged)
        ListenEvent(
          songId: idHere(e.songId),
          endedAt: e.endedAt,
          listenedMs: e.listenedMs,
          continued: e.continued,
        ),
    ];
    final found = mentioned.where(renumbered.containsKey).length;
    return RestoredBackup(
      saved: saved,
      listens: listens,
      songsFound: found,
      songsMissing: mentioned.length - found,
    );
  }

  /// [value] if it's a list, or none: a backup edited by hand, or by
  /// another app, may hold anything.
  static List<Object?> _list(Object? value) => value is List ? value : const [];

  static Iterable<int> _idsIn(Object? value, SongIds kind) sync* {
    switch (kind) {
      case SongIds.list:
        if (value is List) yield* value.map((v) => int.tryParse('$v')).nonNulls;
      case SongIds.keyed:
        if (value is List) yield* value.map((v) => int.tryParse('$v'.split(':').first)).nonNulls;
      case SongIds.playlists:
        if (value is String) yield* decodePlaylists(value).expand((p) => p.songIds);
    }
  }

  /// [value] with its songs renumbered, leaving out those not found.
  static Object? _renumber(Object? value, SongIds kind, int? Function(int) renumber) {
    switch (kind) {
      case SongIds.list:
        if (value is! List) return value;
        return [
          for (final v in value)
            if (int.tryParse('$v') case final id?)
              if (renumber(id) case final found?) '$found',
        ];
      case SongIds.keyed:
        if (value is! List) return value;
        return [
          for (final v in value)
            if ('$v'.split(':') case [final id, final rest])
              if (int.tryParse(id) case final id?)
                if (renumber(id) case final found?) '$found:$rest',
        ];
      case SongIds.playlists:
        if (value is! String) return value;
        final playlists = decodePlaylists(value);
        for (final playlist in playlists) {
          final songs = [for (final id in playlist.songIds) ?renumber(id)];
          playlist.songIds
            ..clear()
            ..addAll(songs);
        }
        return encodePlaylists(playlists);
    }
  }
}

/// Finds the song a backup describes in this phone's library.
class _SongMatcher {
  _SongMatcher(List<Song> library) {
    for (final song in library) {
      if (song.path case final path?) _byPath.putIfAbsent(path, () => song);
      _byTags.putIfAbsent(_tags(song.title, song.artist, song.album), () => song);
      _byTitle.putIfAbsent(_tags(song.title, song.artist, null), () => song);
    }
  }

  final _byPath = <String, Song>{};
  final _byTags = <String, Song>{};
  final _byTitle = <String, Song>{};

  static String? _string(Object? value) => value is String ? value : null;

  static String _tags(String title, String? artist, String? album) =>
      [searchKey(title), searchKey(artist ?? ''), searchKey(album ?? '')].join('\u0000');

  Song? find(Map<dynamic, dynamic> described) {
    final title = described['title'];
    if (title is! String) return null;
    final (artist, album) = (_string(described['artist']), _string(described['album']));
    return _byPath[described['path']] ?? _byTags[_tags(title, artist, album)] ?? _byTitle[_tags(title, artist, null)];
  }
}
