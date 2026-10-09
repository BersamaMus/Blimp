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
}
