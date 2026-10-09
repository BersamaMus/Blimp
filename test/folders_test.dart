import 'package:blimp/services/folders.dart';
import 'package:blimp/services/media_library.dart';
import 'package:flutter_test/flutter_test.dart';

var _id = 0;
Song _at(String path) => Song(id: _id++, title: path, uri: 'content://$_id', path: path);

void main() {
  test('starts from the deepest folder all songs share', () {
    final tree = buildFolderTree([
      _at('/storage/emulated/0/Music/Rock/a.mp3'),
      _at('/storage/emulated/0/Music/Pop/b.mp3'),
      _at('/storage/emulated/0/Music/c.mp3'),
    ])!;
    expect(tree.root.path, '/storage/emulated/0/Music');
    expect(tree.root.name, 'Music');
    expect([for (final f in tree.root.folders) f.name], ['Pop', 'Rock']);
    expect([for (final s in tree.root.songs) s.fileName], ['c.mp3']);
    expect(tree.root.allSongs, hasLength(3));
  });

  test('merges folders holding nothing but one more folder', () {
    final tree = buildFolderTree([
      _at('/storage/emulated/0/Music/Artist/Album/a.mp3'),
      _at('/storage/emulated/0/Download/b.mp3'),
    ])!;
    expect(tree.root.name, 'Internal storage');
    expect([for (final f in tree.root.folders) f.name], ['Download', 'Music/Artist/Album']);
    final album = tree.root.folders.last;
    expect(folderChain(tree.root, album).map((f) => f.name), ['Internal storage', 'Music/Artist/Album']);
  });

  test('names storage roots plainly', () {
    final tree = buildFolderTree([
      _at('/storage/emulated/0/Music/a.mp3'),
      _at('/storage/1A2B-3C4D/Music/b.mp3'),
    ])!;
    expect(tree.root.name, 'Storage');
    // Each holds only a Music folder, so it's merged in.
    expect([for (final f in tree.root.folders) f.name], ['Internal storage/Music', 'SD card/Music']);
  });

  test('sorts songs by file name and skips songs without a path', () {
    final tree = buildFolderTree([
      _at('/m/02 Second.mp3'),
      _at('/m/01 First.mp3'),
      Song(id: 99, title: 'Nowhere', uri: 'x'),
    ])!;
    expect([for (final s in tree.root.songs) s.fileName], ['01 First.mp3', '02 Second.mp3']);
    expect(buildFolderTree([Song(id: 100, title: 'Nowhere', uri: 'x')]), isNull);
  });
}
