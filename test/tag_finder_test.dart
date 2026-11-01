import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:blimp/services/desktop_library.dart';
import 'package:blimp/services/media_library.dart';
import 'package:blimp/services/tag_editor.dart';
import 'package:blimp/services/tag_finder.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> result({
  String title = 'Hello',
  String artist = 'Adele',
  String album = '25',
  int millis = 295000,
}) => {
  'kind': 'song',
  'trackName': title,
  'artistName': artist,
  'collectionName': album,
  'primaryGenreName': 'Pop',
  'releaseDate': '2015-10-23T07:00:00Z',
  'trackNumber': 1,
  'discNumber': 1,
  'trackTimeMillis': millis,
  'artworkUrl100': 'https://example.com/a/100x100bb.jpg',
};

String results(List<Map<String, Object?>> found) => jsonEncode({'results': found});

Song song({String title = 'Hello', String? artist = 'Adele', String? album, int? year, String? genre}) => Song(
  id: 1,
  title: title,
  uri: 'file:///x.mp3',
  artist: artist,
  album: album,
  year: year,
  genre: genre,
  duration: const Duration(seconds: 295),
);

void main() {
  test('missingTags lists only what is absent', () {
    expect(missingTags(song(album: '25', year: 2015, genre: 'Pop'), hasCover: true), isEmpty);
    expect(missingTags(song(artist: null), hasCover: false), {
      MissingTag.artist,
      MissingTag.album,
      MissingTag.genre,
      MissingTag.year,
      MissingTag.cover,
    });
  });

  group('wantedTags', () {
    test('uses the tags when there is an artist', () {
      final wanted = wantedTags(song());
      expect((wanted.title, wanted.artist, wanted.fromFileName), ('Hello', 'Adele', false));
    });

    test('reads "Artist - Song" from a file name', () {
      final wanted = wantedTags(song(title: '01 Adele - Hello', artist: null));
      expect((wanted.title, wanted.artist, wanted.fromFileName), ('Hello', 'Adele', true));
    });

    test('has no artist to go on from a bare name', () {
      expect(wantedTags(song(artist: null)).artist, isNull);
    });
  });

  group('chooseTags', () {
    const length = Duration(seconds: 295);

    test('reads a match, asking for a big cover', () {
      final found = chooseTags(results([result()]), title: 'Hello', artist: 'Adele', length: length)!;
      expect((found.album, found.genre, found.year, found.track), ('25', 'Pop', 2015, 1));
      expect(found.cover, 'https://example.com/a/600x600bb.jpg');
    });

    test('turns down another artist, title or length', () {
      expect(chooseTags(results([result(artist: 'Lionel Richie')]), title: 'Hello', artist: 'Adele', length: length), isNull);
      expect(chooseTags(results([result(title: 'Skyfall')]), title: 'Hello', artist: 'Adele', length: length), isNull);
      expect(chooseTags(results([result(millis: 400000)]), title: 'Hello', artist: 'Adele', length: length), isNull);
    });

    test('prefers the song\'s own album', () {
      final json = results([result(album: 'Hits', millis: 295000), result(millis: 297000)]);
      expect(chooseTags(json, title: 'Hello', artist: 'Adele', album: '25', length: length)?.album, '25');
    });

    test('with no artist, needs one song of nearly that length', () {
      final one = results([result(millis: 296000)]);
      expect(chooseTags(one, title: 'Hello', length: length)?.artist, 'Adele');
      final two = results([result(millis: 296000), result(artist: 'Someone Else', millis: 295000)]);
      expect(chooseTags(two, title: 'Hello', length: length), isNull);
      expect(chooseTags(results([result(millis: 299000)]), title: 'Hello', length: length), isNull);
      expect(chooseTags(one, title: 'Hello'), isNull);
    });
  });

  group('changesFor', () {
    final found = chooseTags(results([result()]), title: 'Hello', artist: 'Adele')!;

    test('fills gaps and leaves what is there', () {
      final have = song(year: 1999);
      final changes = changesFor(have, found, missingTags(have, hasCover: true));
      expect(changes.album, '25');
      expect(changes.genre, 'Pop');
      expect(changes.year, isNull);
      expect(changes.artist, isNull);
      expect(changes.title, isNull);
      expect(changes.track, '1');
    });

    test('keeps track numbers to the song\'s own album', () {
      final have = song(album: 'Another album', year: 2015, genre: 'Pop');
      final changes = changesFor(have, found, missingTags(have, hasCover: false));
      expect(changes.isEmpty, isTrue);
      expect(coverFits(have.album, found), isFalse);
    });

    test('allows for editions of an album', () {
      expect(coverFits('25 (Deluxe Edition)', found), isTrue);
    });

    test('tidies a title that was a file name', () {
      final have = song(title: 'Adele - Hello', artist: null);
      expect(changesFor(have, found, missingTags(have, hasCover: true)).title, 'Hello');
    });
  });

  group('MusicBrainz', () {
    const length = Duration(seconds: 295);

    Map<String, Object?> release(String title, {String status = 'Official', String type = 'Album', List<String>? extra}) => {
      'title': title,
      'status': status,
      'date': '2015-11-20',
      'release-group': {'id': 'group-$title', 'primary-type': type, 'secondary-types': ?extra},
      'media': [
        {
          'position': 1,
          'track': [
            {'number': '4'},
          ],
        },
      ],
    };

    String recordings(List<Map<String, Object?>> releases, {String note = '', int length = 295493}) => jsonEncode({
      'recordings': [
        {
          'title': 'Hello',
          'length': length,
          'disambiguation': note,
          'first-release-date': '2015-10-23',
          'artist-credit': [
            {'name': 'Adele', 'joinphrase': ' & '},
            {'name': 'Friend'},
          ],
          'releases': releases,
        },
      ],
    });

    ({FoundTags tags, String? group})? choose(String json, {String? album}) =>
        chooseMusicBrainz(json, title: 'Hello', artist: 'Adele', album: album, length: length);

    test('reads the tags and where the cover is', () {
      final found = choose(recordings([release('25')]))!;
      expect(found.tags.artist, 'Adele & Friend');
      expect((found.tags.album, found.tags.year, found.tags.track, found.tags.disc), ('25', 2015, 4, 1));
      expect(found.group, 'group-25');
      expect(found.tags.cover, 'https://coverartarchive.org/release-group/group-25/front-500');
    });

    test('never takes a bootleg', () {
      expect(choose(recordings([release('Live in San Jose', status: 'Bootleg')])), isNull);
    });

    test('skips performances set apart by a note', () {
      expect(choose(recordings([release('25')], note: 'live, 2016')), isNull);
    });

    test('prefers a plain album, then the song\'s own', () {
      final json = recordings([
        release('Now 92', extra: ['Compilation']),
        release('Hello', type: 'Single'),
        release('25'),
      ]);
      expect(choose(json)?.tags.album, '25');
      expect(choose(json, album: 'Now 92')?.tags.album, 'Now 92');
    });

    test('searches by length when there is no artist', () {
      final query = musicBrainzSearch('Hello (Official Video)', null, length).queryParameters['query'];
      expect(query, 'recording:"Hello" AND dur:[293000 TO 297000]');
      expect(musicBrainzSearch('Say "Hi"', 'Adele', length).queryParameters['query'], r'recording:"Say \"Hi\"" AND artist:"Adele"');
    });

    test('takes the genre with the most votes', () {
      final json = jsonEncode({
        'genres': [
          {'name': 'soul', 'count': 3},
          {'name': 'neo soul', 'count': 10},
        ],
      });
      expect(chooseGenre(json), 'Neo Soul');
      expect(chooseGenre('{}'), isNull);
    });
  });

  test('says what was filled in, with its values', () {
    final changes = TagChanges(album: '25', year: '2015', track: '1', cover: Uint8List(1));
    expect(filledSummary(changes), 'album: 25 · year: 2015 · track: 1 · cover');
    expect(filledTags(changes), {MissingTag.album, MissingTag.year, MissingTag.cover});
  });

  test('a filled song lacks nothing before it is read again', () {
    final finder = TagFinder();
    final gap = (song: song(), missing: {MissingTag.year, MissingTag.cover});
    finder
      ..gaps = [gap]
      ..fixes[1] = const TagFix(TagFixState.fixed, 'Filled in', {MissingTag.year});
    expect(finder.lacking(gap), {MissingTag.cover});
    expect(finder.needing, 1);
    finder.fixes[1] = const TagFix(TagFixState.fixed, 'Filled in', {MissingTag.year, MissingTag.cover});
    expect(finder.needing, 0);
  });

  group('songs searched before', () {
    final gap = (song: song(), missing: {MissingTag.year});

    test('are passed over by Find all, with a note', () {
      final finder = TagFinder()..gaps = [gap];
      finder.markSearched({1: searchedAs('Hello', 'Adele')});
      expect(finder.fixes[1]?.state, TagFixState.notFound);
      expect(finder.fixes[1]?.note, 'Searched before, nothing found');
    });

    test('are searched again once their title or artist changes', () {
      final finder = TagFinder()..gaps = [gap];
      finder.markSearched({1: searchedAs('Hello', 'Someone Else')});
      expect(finder.fixes[1], isNull);
    });

    test('keep a result from this run', () {
      final finder = TagFinder()
        ..gaps = [gap]
        ..fixes[1] = const TagFix(TagFixState.fixed, 'Filled in');
      finder.markSearched({1: searchedAs('Hello', 'Adele')});
      expect(finder.fixes[1]?.state, TagFixState.fixed);
    });

    test('survive being saved, and bad data is no problem', () {
      expect(decodeSearched(jsonEncode({'1': 'a'})), {1: 'a'});
      expect(decodeSearched('not json'), isEmpty);
      expect(decodeSearched(null), isEmpty);
    });
  });

  group('using two sources', () {
    FoundTags tags({String? album = '25', String? genre, int? year, int? track, String? cover}) => (
      title: 'Hello',
      artist: 'Adele',
      album: album,
      genre: genre,
      year: year,
      track: track,
      disc: null,
      cover: cover,
    );

    test('fills only the gaps of the first', () {
      final merged = mergeTags(tags(genre: 'Pop', cover: 'a'), tags(genre: 'Soul', year: 2015, track: 2, cover: 'b'));
      expect((merged.genre, merged.year, merged.track, merged.cover), ('Pop', 2015, 2, 'a'));
    });

    test('takes no track number from another album', () {
      expect(mergeTags(tags(), tags(album: 'Hits', track: 9)).track, isNull);
    });

    test('asks the next source only for what is left', () {
      final have = song(album: '25');
      final missing = missingTags(have, hasCover: false);
      expect(stillMissing(have, tags(genre: 'Pop', year: 2015, cover: 'a'), missing), isEmpty);
      expect(stillMissing(have, tags(genre: 'Pop'), missing), {MissingTag.year, MissingTag.cover});
      expect(stillMissing(have, null, missing), missing);
    });

    test('a cover from another album still counts as missing', () {
      final have = song(album: 'Hits', year: 2015, genre: 'Pop');
      expect(stillMissing(have, tags(cover: 'a'), {MissingTag.cover}), {MissingTag.cover});
    });
  });

  group('saving a cover', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('tag_finder_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    final audio = List.generate(5000, (i) => (i * 7) & 0xFF);
    final cover = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]);
    Song at(String path) => Song(id: 1, title: 'A', uri: Uri.file(path).toString(), path: path);

    test('MP3 keeps its audio and shows the cover', () async {
      final path = '${dir.path.replaceAll(r'\', '/')}/song.mp3';
      File(path).writeAsBytesSync(audio);
      await TagEditor.save(at(path), TagChanges(title: 'A', cover: cover));
      final bytes = File(path).readAsBytesSync();
      expect(bytes.sublist(bytes.length - audio.length), audio);
      final picture = readMetadata(File(path), getImage: true).pictures.single;
      expect(picture.bytes, cover);
      expect(picture.pictureType, PictureType.coverFront);
    });

    test('MP3 keeps timed lyrics line by line and reads them back', () async {
      final path = '${dir.path.replaceAll(r'\', '/')}/song.mp3';
      File(path).writeAsBytesSync(audio);
      const lyrics = '[00:01.00] First line\n[00:02.50] Second line';
      await TagEditor.save(at(path), const TagChanges(lyrics: lyrics));
      expect(await DesktopLibrary.embeddedLyrics(at(path)), lyrics);
      final bytes = File(path).readAsBytesSync();
      expect(bytes.sublist(bytes.length - audio.length), audio);
    });

    test('keepDate leaves the file\'s date as it was', () async {
      final path = '${dir.path.replaceAll(r'\', '/')}/song.mp3';
      File(path)
        ..writeAsBytesSync(audio)
        ..setLastModifiedSync(DateTime(2020));
      await TagEditor.save(at(path), const TagChanges(lyrics: 'Words'), keepDate: true);
      expect(File(path).lastModifiedSync(), DateTime(2020));
      await TagEditor.save(at(path), const TagChanges(lyrics: 'More words'));
      expect(File(path).lastModifiedSync().year, isNot(2020));
    });

    test('FLAC keeps its audio and shows the cover', () async {
      final path = '${dir.path.replaceAll(r'\', '/')}/song.flac';
      final info = ByteData(34)..setUint32(10, 44100 << 12 | 1 << 9 | 15 << 4);
      File(path).writeAsBytesSync([
        ...ascii.encode('fLaC'),
        0x80, 0, 0, 34, ...info.buffer.asUint8List(),
        ...audio,
      ]);
      await TagEditor.save(at(path), TagChanges(title: 'A', cover: cover));
      final bytes = File(path).readAsBytesSync();
      expect(bytes.sublist(bytes.length - audio.length), audio);
      expect(readMetadata(File(path), getImage: true).pictures.single.bytes, cover);
    });
  });
}
