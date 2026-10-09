import 'dart:io';

import 'package:blimp/services/desktop_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('stableId', () {
    test('is the same every time for the same key', () {
      expect(DesktopLibrary.stableId('c:/music/song.mp3'), DesktopLibrary.stableId('c:/music/song.mp3'));
    });

    test('differs between keys', () {
      expect(DesktopLibrary.stableId('c:/music/a.mp3'), isNot(DesktopLibrary.stableId('c:/music/b.mp3')));
    });

    test('fits in 53 bits, so JSON keeps it exact', () {
      for (final key in ['', 'a', 'c:/users/ana/music/some long folder/track 01.flac']) {
        final id = DesktopLibrary.stableId(key);
        expect(id, inInclusiveRange(0, (1 << 53) - 1));
      }
    });
  });

  group('getSongs', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('blimp_library_test');
      SharedPreferences.setMockInitialValues({});
      await DesktopLibrary.setMusicFolder(root.path);
    });

    tearDown(() => root.delete(recursive: true));

    test('finds audio files in subfolders and skips other files', () async {
      await File('${root.path}/Rock/Untagged Song.mp3').create(recursive: true);
      await File('${root.path}/cover.jpg').create();
      await File('${root.path}/notes.txt').create();

      final songs = await DesktopLibrary.getSongs();

      expect(songs, hasLength(1));
      final song = songs.single;
      // No tags, so it goes by its file name.
      expect(song.title, 'Untagged Song');
      expect(song.path, endsWith('/Rock/Untagged Song.mp3'));
      expect(song.path, isNot(contains(r'\')));
      expect(song.folder, endsWith('/Rock'));
    });

    test('gives a file the same id on every scan', () async {
      await File('${root.path}/a.flac').create();
      final first = await DesktopLibrary.getSongs();
      final second = await DesktopLibrary.getSongs();
      expect(first.single.id, second.single.id);
    });

    test('is empty when the folder is gone', () async {
      await DesktopLibrary.setMusicFolder('${root.path}/missing');
      expect(await DesktopLibrary.getSongs(), isEmpty);
    });
  });
}
