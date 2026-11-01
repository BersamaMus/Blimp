import 'dart:convert';
import 'dart:io';

import 'package:blimp/services/lyrics_finder.dart';
import 'package:blimp/services/lyrics_index.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> result({
  String title = 'Blinding Lights',
  String artist = 'The Weeknd',
  double? duration = 200,
  String? timed,
  String? plain,
  bool instrumental = false,
  bool wordTimed = false,
}) => {
  'trackName': title,
  'artistName': artist,
  'duration': duration,
  'syncedLyrics': timed,
  'plainLyrics': plain,
  'instrumental': instrumental,
  'hasWordSync': wordTimed,
};

String? choose(
  List<Map<String, Object?>> results, {
  String title = 'Blinding Lights',
  String artist = 'The Weeknd',
  Duration? length = const Duration(seconds: 200),
  bool timedOnly = false,
}) => chooseLyrics(jsonEncode(results), title: title, artist: artist, length: length, timedOnly: timedOnly);

void main() {
  test('lyrics saved in a file leave Blimp, and wait before another look', () {
    final found = FoundLyrics(null)..put(1, 'Words');
    final now = DateTime(2026);
    found.savedInFile(1, now);
    expect(found.textOf(1), isNull);
    expect(found.settled(1, now), isTrue);
    expect(found.settled(1, now.add(FoundLyrics.retryAfter)), isFalse);
  });

  group('chooseLyrics', () {
    test('timed lyrics beat plain ones, even listed later', () {
      expect(choose([result(plain: 'plain'), result(timed: '[00:01.00]timed')]), '[00:01.00]timed');
    });

    test('plain lyrics are used when nothing is timed', () {
      expect(choose([result(plain: 'plain')]), 'plain');
    });

    test('plain lyrics are passed over for a song with its own', () {
      expect(choose([result(plain: 'plain')], timedOnly: true), isNull);
    });

    test('word-timed lyrics beat line-timed ones', () {
      expect(choose([result(timed: 'lines'), result(timed: 'words', wordTimed: true)]), 'words');
    });

    test('the nearest in length wins', () {
      expect(choose([result(duration: 202, timed: 'far'), result(duration: 200.5, timed: 'near')]), 'near');
    });

    test('another length is another version', () {
      expect(choose([result(duration: 170, timed: 'radio edit')]), isNull);
      expect(choose([result(duration: 204, timed: 'just over')]), isNull);
      expect(choose([result(duration: 203, timed: 'just within')]), 'just within');
    });

    test('a result of unknown length is passed over', () {
      expect(choose([result(duration: null, timed: 'who knows')]), isNull);
    });

    test('any result will do for length when the file has none', () {
      expect(choose([result(duration: 170, timed: 'timed')], length: null), 'timed');
      expect(choose([result(duration: 170, timed: 'timed')], length: Duration.zero), 'timed');
    });

    test('other songs and artists are passed over', () {
      expect(choose([result(title: 'Save Your Tears', timed: 'timed')]), isNull);
      expect(choose([result(artist: 'Someone Else', timed: 'timed')]), isNull);
    });

    test('titles and artists match the way search does', () {
      expect(
        choose([result(title: 'Beyoncé', artist: 'AC/DC', timed: 'timed')], title: 'beyonce', artist: 'acdc'),
        'timed',
      );
    });

    test('a credit with more artists still matches', () {
      expect(choose([result(artist: 'The Weeknd & Ariana Grande', timed: 'timed')]), 'timed');
      expect(choose([result(timed: 'timed')], artist: 'The Weeknd, Ariana Grande'), 'timed');
      expect(
        choose([result(artist: 'The Weeknd & Ariana Grande', timed: 'timed')], artist: 'The Weeknd, Ariana Grande'),
        'timed',
      );
    });

    test('titles match without what versions add', () {
      expect(choose([result(timed: 'timed')], title: 'Blinding Lights (Official Video)'), 'timed');
    });

    test('instrumentals have no lyrics', () {
      expect(choose([result(instrumental: true, timed: 'timed')]), isNull);
    });

    test('blank lyrics count as none', () {
      expect(choose([result(timed: '  ', plain: 'plain')]), 'plain');
      expect(choose([result(timed: '', plain: '')]), isNull);
    });

    test('nothing to go on finds nothing', () {
      expect(choose([result(timed: 'timed')], title: '???'), isNull);
      expect(chooseLyrics('{"message":"busy"}', title: 'a', artist: 'b'), isNull);
      expect(choose(const []), isNull);
    });
  });

  group('listedInstrumental', () {
    bool listed(List<Map<String, Object?>> results) => listedInstrumental(
      jsonEncode(results),
      title: 'Blinding Lights',
      artist: 'The Weeknd',
      length: const Duration(seconds: 200),
    );

    test('finds the flag on the same song', () {
      expect(listed([result(instrumental: true)]), isTrue);
      expect(listed([result(plain: 'plain')]), isFalse);
    });

    test("another song's or version's flag doesn't count", () {
      expect(listed([result(title: 'Save Your Tears', instrumental: true)]), isFalse);
      expect(listed([result(duration: 120, instrumental: true)]), isFalse);
    });
  });

  group('looksInstrumental', () {
    test('goes by what titles say', () {
      expect(looksInstrumental('Song (Instrumental)', null), isTrue);
      expect(looksInstrumental('Song [Instrumental Version]', null), isTrue);
      expect(looksInstrumental('Song - Instrumental', null), isTrue);
      expect(looksInstrumental('Song (Off Vocal)', null), isTrue);
      expect(looksInstrumental('Song (Karaoke Version)', null), isTrue);
    });

    test('goes by the genre', () {
      expect(looksInstrumental('Song', 'Instrumental'), isTrue);
      expect(looksInstrumental('Song', 'Instrumental Hip-Hop'), isTrue);
    });

    test('leaves other songs alone', () {
      expect(looksInstrumental('Song', 'Pop'), isFalse);
      expect(looksInstrumental('Instrumental Love', null), isFalse);
      expect(looksInstrumental('Karaoke Night', null), isFalse);
    });
  });

  group('plainTitle', () {
    test('drops what versions add', () {
      expect(plainTitle('Song (Official Music Video)'), 'Song');
      expect(plainTitle('Song [Official Audio]'), 'Song');
      expect(plainTitle('Song (feat. Someone)'), 'Song');
      expect(plainTitle('Song (Lyrics)'), 'Song');
      expect(plainTitle('Song - Remastered 2011'), 'Song');
      expect(plainTitle('Song - 2011 Remaster'), 'Song');
    });

    test('keeps what is part of the title', () {
      expect(plainTitle("Don't Stop (Thinking About Tomorrow)"), "Don't Stop (Thinking About Tomorrow)");
      expect(plainTitle('Song (Live)'), 'Song (Live)');
      expect(plainTitle('Song (Remix)'), 'Song (Remix)');
    });

    test('keeps a title that would be left empty', () {
      expect(plainTitle('(Official Video)'), '(Official Video)');
    });
  });

  test('artistNames tries a credit whole, then the name before a comma', () {
    expect(artistNames('The Weeknd'), ['The Weeknd']);
    expect(artistNames('Drake feat. Rihanna'), ['Drake']);
    expect(artistNames('Earth, Wind & Fire'), ['Earth, Wind & Fire', 'Earth']);
    expect(artistNames('Simon & Garfunkel'), ['Simon & Garfunkel', 'Simon']);
  });

  group('bestLyrics', () {
    const timed = '[00:01.00]mine\n[00:02.00]too';

    test("a song's own timed lyrics always stay", () {
      expect(bestLyrics(timed, 'found'), timed);
    });

    test('what was found beats plain lyrics', () {
      expect(bestLyrics('mine', '[00:01.00]found'), '[00:01.00]found');
    });

    test('either alone is used', () {
      expect(bestLyrics('mine', null), 'mine');
      expect(bestLyrics(null, 'found'), 'found');
      expect(bestLyrics(null, null), isNull);
    });
  });

  group('FoundLyrics', () {
    final now = DateTime(2026, 11, 2);

    test('found songs are settled', () {
      final found = FoundLyrics(null)..put(1, 'text');
      expect(found.settled(1, now), isTrue);
      expect(found.settled(2, now), isFalse);
      expect(found.textOf(1), 'text');
    });

    test('songs without lyrics are tried again after a while', () {
      final found = FoundLyrics(null)..missed(1, now);
      expect(found.settled(1, now.add(const Duration(days: 29))), isTrue);
      expect(found.settled(1, now.add(const Duration(days: 31))), isFalse);
    });

    test('songs LRCLIB would not answer for are tried again soon', () {
      final found = FoundLyrics(null)..unanswered(1, now);
      expect(found.settled(1, now.add(const Duration(hours: 23))), isTrue);
      expect(found.settled(1, now.add(const Duration(hours: 25))), isFalse);
    });

    test('instrumentals are never looked up again', () {
      final found = FoundLyrics(null)
        ..missed(1, now)
        ..markInstrumental(1);
      expect(found.isInstrumental(1), isTrue);
      expect(found.settled(1, now.add(const Duration(days: 3650))), isTrue);
    });

    test('instrumentals outlast removing found lyrics, and survive being saved', () {
      final found = FoundLyrics(null)
        ..markInstrumental(1)
        ..clear();
      final back = FoundLyrics(null)..decode(found.encode());
      expect(back.isInstrumental(1), isTrue);
    });

    test('lyrics found later overrule the mark', () {
      final found = FoundLyrics(null)
        ..markInstrumental(1)
        ..put(1, 'text');
      expect(found.isInstrumental(1), isFalse);
    });

    test('keepOwn drops what was found, for good', () {
      final found = FoundLyrics(null)..put(1, 'text');
      expect(found.keepOwn(1), isTrue);
      expect(found.textOf(1), isNull);
      expect(found.settled(1, now.add(const Duration(days: 3650))), isTrue);
      expect(found.keepOwn(1), isFalse);
    });

    test("removing found lyrics doesn't undo keepOwn", () {
      final found = FoundLyrics(null)
        ..put(1, 'text')
        ..missed(2, now)
        ..keepOwn(3)
        ..clear();
      expect(found.ids, isEmpty);
      expect(found.settled(2, now), isFalse);
      expect(found.settled(3, now.add(const Duration(days: 3650))), isTrue);
    });

    test('saves at the same time take turns', () async {
      final dir = await Directory.systemTemp.createTemp('blimp_found');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/found.json');
      final found = FoundLyrics(file)..put(1, 'text');
      await Future.wait([for (var i = 0; i < 8; i++) found.save()]);
      expect((FoundLyrics(null)..decode(file.readAsStringSync())).textOf(1), 'text');
      final index = LyricsIndex(File('${dir.path}/index.json'));
      await Future.wait([for (var i = 0; i < 8; i++) index.save()]);
      expect(File('${dir.path}/index.json').existsSync(), isTrue);
    });

    test('survives being saved and read back', () {
      final found = FoundLyrics(null)
        ..put(1, '[00:01.00]line')
        ..missed(2, now)
        ..keepOwn(3);
      final back = FoundLyrics(null)..decode(found.encode());
      expect(back.textOf(1), '[00:01.00]line');
      expect(back.settled(2, now), isTrue);
      expect(back.settled(3, now.add(const Duration(days: 3650))), isTrue);
    });
  });
}
