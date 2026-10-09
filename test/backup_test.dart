import 'dart:convert';

import 'package:blimp/services/backup.dart';
import 'package:blimp/services/listening_log.dart';
import 'package:blimp/services/media_library.dart';
import 'package:blimp/services/playlists.dart';
import 'package:flutter_test/flutter_test.dart';

Song _song(int id, String title, {String? path, String artist = 'A', String album = 'Album'}) =>
    Song(id: id, title: title, uri: 'content://$id', path: path, artist: artist, album: album);

const _songKeys = {
  'liked': SongIds.list,
  'counts': SongIds.keyed,
  'playlists': SongIds.playlists,
};

void main() {
  final oldPhone = [
    _song(1, 'Crown', path: '/storage/emulated/0/Music/Crown.mp3'),
    _song(2, 'Mirror', path: '/storage/emulated/0/Music/Mirror.mp3'),
    _song(3, 'Gone', path: '/storage/emulated/0/Music/Gone.mp3'),
  ];

  String backup() => Backup.create(
    saved: {
      'liked': ['1', '2', '3'],
      'counts': ['1:5', '3:2'],
      'playlists': encodePlaylists([
        Playlist(id: 'p', name: 'Mix', songIds: [2, 1, 3], created: DateTime(2026)),
      ]),
      'speed': 1.25,
      'theme': 'green',
    },
    songKeys: _songKeys,
    listens: [ListenEvent(songId: 3, endedAt: DateTime(2026, 10, 1), listenedMs: 60000)],
    songsById: {for (final s in oldPhone) s.id: s},
    now: DateTime(2026, 10, 9),
  );

  test('restores onto a new phone, matching songs by file and then by tags', () {
    final newPhone = [
      // Same file, new id.
      _song(41, 'Crown', path: '/storage/emulated/0/Music/Crown.mp3'),
      // Moved, but the same tags (accents and case aside).
      _song(42, 'MIRROR', path: '/storage/emulated/0/Download/m.mp3'),
      // "Gone" isn't here.
    ];
    final restored = Backup.restore(backup(), songKeys: _songKeys, library: newPhone);

    expect(restored.saved['liked'], ['41', '42']);
    expect(restored.saved['counts'], ['41:5']);
    expect(decodePlaylists(restored.saved['playlists'] as String).single.songIds, [42, 41]);
    expect(restored.saved['speed'], 1.25);
    expect(restored.saved['theme'], 'green');
    expect((found: restored.songsFound, missing: restored.songsMissing), (found: 2, missing: 1));

    // The missing song's listening still counts, under an id no song has.
    expect(restored.listens.single.listenedMs, 60000);
    expect(restored.listens.single.songId, isNegative);
  });

  test('songs missing across restores never share an id', () {
    final listens = [
      // Song 4 went missing in an earlier restore.
      ListenEvent(songId: -5, endedAt: DateTime(2026, 9, 1), listenedMs: 1000),
      ListenEvent(songId: 5, endedAt: DateTime(2026, 9, 2), listenedMs: 2000),
      ListenEvent(songId: 4, endedAt: DateTime(2026, 9, 3), listenedMs: 3000),
      ListenEvent(songId: 5, endedAt: DateTime(2026, 9, 4), listenedMs: 4000),
    ];
    final text = Backup.create(saved: const {}, songKeys: _songKeys, listens: listens, songsById: const {}, now: DateTime(2026, 10, 9));
    final ids = Backup.restore(text, songKeys: _songKeys, library: const []).listens.map((e) => e.songId).toList();
    expect(ids.every((id) => id < 0), isTrue);
    expect(ids[0], -5);
    expect(ids.sublist(0, 3).toSet(), hasLength(3));
    expect(ids[3], ids[1]);
  });

  test('a backup with unexpected values is refused or read around, never crashes', () {
    final odd = (jsonDecode(backup()) as Map)
      ..['version'] = '1'
      ..['songs'] = [
        {'id': 1, 'title': 'Crown', 'artist': 7, 'album': ['x']},
      ]
      ..['listens'] = 'nope';
    final restored = Backup.restore(jsonEncode(odd), songKeys: _songKeys, library: oldPhone);
    expect(restored.listens, isEmpty);
    expect(Backup.restore('{"format": "blimp-backup", "songs": 3}', songKeys: _songKeys, library: oldPhone).saved, isEmpty);
  });

  test('refuses files that aren\'t backups', () {
    expect(() => Backup.restore('not json', songKeys: _songKeys, library: oldPhone), throwsFormatException);
    expect(() => Backup.restore('{"hello": 1}', songKeys: _songKeys, library: oldPhone), throwsFormatException);
    final future = (jsonDecode(backup()) as Map)..['version'] = 99;
    expect(() => Backup.restore(jsonEncode(future), songKeys: _songKeys, library: oldPhone), throwsFormatException);
  });
}
