import 'package:blimp/services/lyrics.dart';
import 'package:blimp/services/lyrics_index.dart';
import 'package:blimp/services/media_library.dart';
import 'package:blimp/services/search_text.dart';
import 'package:flutter_test/flutter_test.dart';

Song _song(int id, {int size = 100}) => Song(id: id, title: 'Song $id', uri: '$id', size: size);

void main() {
  final highway = SongLyrics.of(parseLyrics('''
[00:10.00]Living easy, living free
[00:15.00]Season ticket on a one-way ride
[00:20.00]I'm on the highway to hell
[00:25.00]On the highway to hell
[00:30.00]I'm on the highway to hell
'''));
  final plain = SongLyrics.of(parseLyrics('Don\'t stop believin\'\nHold on to that feelin\''));

  List<LyricMatch> search(String text) => searchLyrics(searchKey(text), [(_song(1), highway), (_song(2), plain)]);

  test('finds the song and the line, with when it is sung', () {
    final found = search('highway to hell');
    expect(found, hasLength(1));
    expect(found.single.song.id, 1);
    expect(found.single.text, "I'm on the highway to hell");
    expect(found.single.time, const Duration(seconds: 20));
  });

  test('a chorus is found where it is first sung, and kept once', () {
    expect(highway.lines.where((l) => l.text == "I'm on the highway to hell"), hasLength(1));
  });

  test('ignores case, accents and apostrophes, as other search does', () {
    expect(search('DONT STOP').single.song.id, 2);
    expect(search('believin').single.text, "Don't stop believin'");
    // Untimed lyrics have no time to start from.
    expect(search('believin').single.time, isNull);
  });

  test('words that run on into the next line are found', () {
    final found = search('one way ride im on');
    expect(found.single.text, "Season ticket on a one-way ride / I'm on the highway to hell");
    expect(found.single.time, const Duration(seconds: 15));
  });

  test('matches at the start of a word come first', () {
    final songs = [
      (_song(3), SongLyrics.of(parseLyrics('the reunion was fun'))),
      (_song(4), SongLyrics.of(parseLyrics('union street'))),
    ];
    expect([for (final m in searchLyrics('union', songs)) m.song.id], [4, 3]);
  });

  test('too short a search finds nothing', () {
    expect(search('on'), isEmpty);
  });

  test('the index reads back what it saved, and forgets changed files', () {
    final index = LyricsIndex(null)
      ..put(_song(5), 'a', SongLyrics.of(parseLyrics('[00:01.00]One\n[00:02.00]Two')))
      ..put(_song(6), 'b', SongLyrics.of(null));
    final copy = LyricsIndex(null)..decode(index.encode());
    expect(copy.of(_song(5))!.lines.map((l) => (l.text, l.time)), [
      ('One', const Duration(seconds: 1)),
      ('Two', const Duration(seconds: 2)),
    ]);
    // Read, and found to have none.
    expect(copy.has(_song(6), 'b'), isTrue);
    expect(copy.of(_song(6)), isNull);
    // Its file (or the .lrc beside it) changed since.
    expect(copy.has(_song(5), 'c'), isFalse);
    // Still searchable while it waits to be read again.
    expect(copy.of(_song(5)), isNotNull);
  });

  test('read lyrics are found by search, and deleted songs forgotten', () async {
    final index = LyricsIndex(null);
    final parsed = await LyricsIndex.parse({7: 'Hello from the other side', 8: null});
    index
      ..put(_song(7), 'a', parsed[7]!)
      ..put(_song(8), 'a', parsed[8]!);
    expect(searchLyrics('other side', [(_song(7), index.of(_song(7))!)]).single.song.id, 7);
    expect(index.keepOnly({7}), isTrue);
    expect(index.has(_song(8), 'a'), isFalse);
    expect(index.keepOnly({7}), isFalse);
  });

  test('an older index is read as empty, to be read afresh', () {
    final index = LyricsIndex(null)..decode('{"version":1,"songs":{"5":[100,[-1,"One"]]}}');
    expect(index.has(_song(5), '100'), isFalse);
  });
}
