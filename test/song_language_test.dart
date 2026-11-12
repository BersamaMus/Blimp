import 'package:blimp/services/media_library.dart';
import 'package:blimp/services/song_language.dart';
import 'package:flutter_test/flutter_test.dart';

var _id = 0;
Song song(String title, {String? artist, String? album, String? genre}) =>
    Song(id: _id++, title: title, uri: 'u$_id', artist: artist, album: album, genre: genre);

String? languageOf(Song s, [List<Song> library = const []]) => SongLanguages([...library, s]).of(s);

void main() {
  group('writing system', () {
    test('Korean, Japanese and Chinese', () {
      expect(scriptOf('사랑해요'), 'ko');
      expect(scriptOf('ありがとう'), 'ja');
      expect(scriptOf('千と千尋の神隠し'), 'ja'); // kanji with kana
      expect(scriptOf('月亮代表我的心'), 'han');
    });

    test('other scripts', () {
      expect(scriptOf('Кино'), 'cyrl');
      expect(scriptOf('حبيبي'), 'arab');
      expect(scriptOf('तुम ही हो'), 'hi');
      expect(scriptOf('ขอใจเธอแลกเบอร์โทร'), 'th');
    });

    test('a few English words in brackets do not outweigh the script', () {
      expect(scriptOf('봄날 (Spring Day)'), 'ko');
    });

    test('Latin text has no script language', () {
      expect(scriptOf('Hello'), isNull);
      expect(scriptOf('Café del Mar'), isNull);
    });
  });

  group('Latin-alphabet languages', () {
    test('common words', () {
      expect(latinLanguage('Here Comes the Sun').$1, 'en');
      expect(latinLanguage('Bésame Mucho').$1, 'es');
      expect(latinLanguage('Isabela Cinta Kita').$1, 'ms');
      expect(latinLanguage('Non, je ne regrette rien').$1, 'fr');
      expect(latinLanguage('Ich will dich').$1, 'de');
      expect(latinLanguage('Mahal Kita').$1, isNotNull);
    });

    test('letters as hints', () {
      expect(latinLanguage('Niño').$1, 'es');
      expect(latinLanguage('Đi đâu đó').$1, 'vi');
    });

    test('đ alone is not Vietnamese: Croatian and Serbian use it too', () {
      expect(latinLanguage('Đurđevdan').$1, isNull);
    });

    test('words shared with English do not decide alone', () {
      expect(latinLanguage('Die Young').$1, isNull);
      expect(latinLanguage('Die With A Smile').$1, 'en');
      expect(latinLanguage('O Holy Night').$1, 'en');
      expect(latinLanguage('Tu').$1, isNull);
    });

    test('shared words back up the rest of the title', () {
      expect(latinLanguage('Que Me Quedes Tú'), ('es', 2));
    });

    test('credits and versions are ignored', () {
      expect(latinLanguage('Despacito (feat. Justin Bieber) [Remix]').$1, isNull);
      expect(latinLanguage('Bohemian Rhapsody - Remastered').$1, isNull);
    });
  });

  group('a song\'s language', () {
    test('comes from its own title when that is clear', () {
      expect(languageOf(song('눈의 꽃')), 'ko');
      expect(languageOf(song('Love Me Like You Do')), 'en');
    });

    test('comes from the artist when the title says nothing', () {
      final library = [
        for (final title in ['봄날', '피 땀 눈물', '작은 것들을 위한 시']) song(title, artist: 'BTS'),
      ];
      expect(languageOf(song('Dynamite', artist: 'BTS'), library), 'ko');
    });

    test('the artist named in its own script counts', () {
      expect(languageOf(song('Blueming', artist: '아이유')), 'ko');
    });

    test('Chinese characters are Japanese from an artist who uses kana', () {
      final library = [song('さくら', artist: 'Ikimonogakari'), song('ありがとう', artist: 'Ikimonogakari')];
      expect(languageOf(song('花火', artist: 'Ikimonogakari'), library), 'ja');
      expect(languageOf(song('月亮代表我的心', artist: 'Teresa Teng')), 'zh');
    });

    test('a clearly English title beats a Spanish artist', () {
      final library = [
        for (final title in ['Ojos Así', 'Estoy Aquí', 'Que Me Quedes Tú', 'La Tortura']) song(title, artist: 'Shakira'),
      ];
      expect(languageOf(song("Can't Remember to Forget You", artist: 'Shakira'), library), 'en');
      // One telling word isn't enough to overrule the artist.
      expect(languageOf(song("Hips Don't Lie", artist: 'Shakira'), library), 'es');
      expect(languageOf(song('Whenever, Wherever', artist: 'Shakira'), library), 'es');
    });

    test('untagged songs do not share an artist language', () {
      final library = [
        for (final title in ['Love Me Do', 'Here Comes the Sun', 'Let It Be', 'Yesterday Once More']) song(title),
      ];
      expect(languageOf(song('Gelora', album: 'Hati'), library), isNot('en'));
      final various = [for (final s in library) song(s.title, artist: 'Various Artists')];
      expect(languageOf(song('Gelora', artist: 'Various Artists'), various), isNull);
    });

    test('a song outside the library is worked out once and kept', () {
      final languages = SongLanguages([]);
      final outside = song('Love Me Like You Do');
      expect(languages.of(outside), 'en');
      expect(languages.of(outside), 'en');
    });

    test('genre is a last resort', () {
      expect(languageOf(song('Gee', artist: 'Girls Generation', genre: 'K-Pop')), 'ko');
    });

    test('unknown when nothing gives it away', () {
      expect(languageOf(song('Gangnam Style', artist: 'PSY')), isNull);
    });
  });
}
