import 'package:blimp/services/lyrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads timed LRC lines in order, with the offset applied', () {
    final lyrics = parseLyrics('''
[ti:Song]
[offset:+500]
[00:12.00]Second line
[00:05.5]First line
[01:02:30][01:30.250]Chorus <00:31.00>word
''')!;
    expect(lyrics.synced, isTrue);
    expect([for (final l in lyrics.lines) (l.text, l.time)], [
      ('First line', const Duration(seconds: 5)),
      ('Second line', const Duration(milliseconds: 11500)),
      ('Chorus word', const Duration(minutes: 1, seconds: 1, milliseconds: 800)),
      ('Chorus word', const Duration(minutes: 1, seconds: 29, milliseconds: 750)),
    ]);
  });

  test('finds the line being sung', () {
    final lyrics = parseLyrics('[00:10]a\n[00:20]b\n[00:30]c')!;
    expect(lyrics.lineAt(const Duration(seconds: 5)), -1);
    expect(lyrics.lineAt(const Duration(seconds: 20)), 1);
    expect(lyrics.lineAt(const Duration(minutes: 5)), 2);
  });

  test('plain lyrics keep their lines, without blank ones at the ends', () {
    final lyrics = parseLyrics('\n\nVerse one\n\nVerse two\n\n')!;
    expect(lyrics.synced, isFalse);
    expect([for (final l in lyrics.lines) l.text], ['Verse one', '', 'Verse two']);
  });

  test('a single timed line is shown as plain text', () {
    final lyrics = parseLyrics('[ar:Someone]\n[00:05.00]Only <00:06.00>line')!;
    expect(lyrics.synced, isFalse);
    expect(lyrics.lines.map((l) => l.text), ['Only line']);
  });

  test('nothing to show is no lyrics', () {
    expect(parseLyrics('  \n\n'), isNull);
    expect(parseLyrics('[ar:Someone]\n[ti:Something]'), isNull);
  });

  test('word timings are kept for karaoke, with the offset applied', () {
    final lyrics = parseLyrics(
      '[offset:+500]\n'
      '[00:10.00]<00:10.00>Hello <00:10.80>bright <00:11.40>world<00:12.00>\n'
      '[00:13.00]No word times here',
    )!;
    final words = lyrics.lines.first.words!;
    expect(lyrics.lines.first.text, 'Hello bright world');
    expect(words.map((w) => w.text).join(), 'Hello bright world');
    expect(words.map((w) => w.time), [
      const Duration(milliseconds: 9500),
      const Duration(milliseconds: 10300),
      const Duration(milliseconds: 10900),
    ]);
    expect(lyrics.lines.last.words, isNull);
    expect(lyrics.endOf(0), const Duration(milliseconds: 12500));
    expect(lyrics.endOf(1, songEnd: const Duration(minutes: 3)), const Duration(minutes: 3));
  });

  test('words with an end tag each still join up into the line', () {
    final line = parseLyrics('[00:01.00]<00:01.00>Hello<00:01.50> <00:01.60>world<00:02.00>\n[00:03.00]Next')!.lines.first;
    expect(line.text, 'Hello world');
    expect(line.words!.map((w) => w.text), ['Hello ', 'world']);
    expect(line.words!.map((w) => w.time), [const Duration(seconds: 1), const Duration(milliseconds: 1600)]);
  });

  test('a line sung at several times keeps no word timings', () {
    final lyrics = parseLyrics('[00:01.00][00:20.00]<00:01.00>La <00:01.50>la\n[00:10.00]Verse')!;
    expect(lyrics.lines.first.words, isNull);
  });
}
