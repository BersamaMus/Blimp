import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:blimp/services/desktop_library.dart';
import 'package:blimp/services/media_library.dart';
import 'package:blimp/services/tag_editor.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> syncsafe(int v) => [(v >> 21) & 0x7F, (v >> 14) & 0x7F, (v >> 7) & 0x7F, v & 0x7F];
List<int> be32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
List<int> le32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

/// An ID3v2.3 tag: title, artist, lyrics, a ReplayGain TXXX frame and a cover.
List<int> id3v23() {
  List<int> frame(String id, List<int> body) => [...ascii.encode(id), ...be32(body.length), 0, 0, ...body];
  final frames = [
    ...frame('TIT2', [0, ...latin1.encode('Old title')]),
    ...frame('TPE1', [0, ...latin1.encode('Old artist')]),
    ...frame('USLT', [0, ...ascii.encode('eng'), 0, ...latin1.encode('Some lyrics')]),
    ...frame('TXXX', [0, ...latin1.encode('REPLAYGAIN_TRACK_GAIN'), 0, ...latin1.encode('-6.50 dB')]),
    ...frame('APIC', [0, ...ascii.encode('image/png'), 0, 3, 0, 1, 2, 3, 4]),
  ];
  return [...ascii.encode('ID3'), 3, 0, 0, ...syncsafe(frames.length), ...frames];
}

/// A FLAC header with STREAMINFO, Vorbis comments, a picture and padding.
List<int> flac({List<String> extra = const []}) {
  final info = ByteData(34)..setUint32(10, 44100 << 12 | 1 << 9 | 15 << 4);
  final comments = ['TITLE=Old title', 'ARTIST=Old artist', 'REPLAYGAIN_TRACK_GAIN=-6.50 dB', 'RELEASETYPE=single', ...extra];
  final vorbis = [
    ...le32(5), ...ascii.encode('test!'), ...le32(comments.length),
    for (final c in comments) ...[...le32(utf8.encode(c).length), ...utf8.encode(c)],
  ];
  final picture = [...be32(3), ...be32(9), ...ascii.encode('image/png'), ...be32(0), ...be32(1), ...be32(1), ...be32(24), ...be32(0), ...be32(4), 1, 2, 3, 4];
  List<int> block(int type, List<int> data, {bool last = false}) =>
      [(last ? 0x80 : 0) | type, (data.length >> 16) & 0xFF, (data.length >> 8) & 0xFF, data.length & 0xFF, ...data];
  return [
    ...ascii.encode('fLaC'),
    ...block(0, info.buffer.asUint8List()),
    ...block(4, vorbis),
    ...block(6, picture),
    ...block(1, List.filled(16, 0), last: true),
  ];
}

/// Stands in for the audio after the tags: must come through untouched.
final audio = List.generate(5000, (i) => (i * 7) & 0xFF);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('tag_editor_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  Song songAt(String path) => Song(id: 1, title: 'Old title', uri: Uri.file(path).toString(), path: path);

  test('MP3: changes only the fields edited, keeps lyrics, custom tags, cover and audio', () async {
    final path = '${dir.path.replaceAll(r'\', '/')}/song.mp3';
    File(path).writeAsBytesSync([...id3v23(), ...audio]);
    expect(isDesktop, isTrue);

    await TagEditor.save(songAt(path), const TagChanges(title: 'New title', album: 'New album', year: '2001'));

    final bytes = File(path).readAsBytesSync();
    expect(bytes.sublist(bytes.length - audio.length), audio);
    final tags = readAllMetadata(File(path)) as Mp3Metadata;
    expect(tags.songName, 'New title');
    expect(tags.leadPerformer, 'Old artist');
    expect(tags.album, 'New album');
    expect(tags.year, 2001);
    expect(tags.lyric, contains('Some lyrics'));
    // As the app reads it.
    expect(DesktopLibrary.id3UserText(File(path))['REPLAYGAIN_TRACK_GAIN'], '-6.50 dB');
    expect(tags.pictures.single.bytes, [1, 2, 3, 4]);
    expect(File('$path.blimp-edit').existsSync(), isFalse);
  });

  test('MP3 with no tag gets one', () async {
    final path = '${dir.path.replaceAll(r'\', '/')}/bare.mp3';
    File(path).writeAsBytesSync(audio);
    await TagEditor.save(songAt(path), const TagChanges(title: 'Named', artist: 'Someone'));
    final bytes = File(path).readAsBytesSync();
    expect(ascii.decode(bytes.sublist(0, 3)), 'ID3');
    expect(bytes.sublist(bytes.length - audio.length), audio);
    final tags = readAllMetadata(File(path)) as Mp3Metadata;
    expect(tags.songName, 'Named');
    expect(tags.leadPerformer, 'Someone');
  });

  test('FLAC: changes only the fields edited, keeps other comments, picture and audio', () async {
    final path = '${dir.path.replaceAll(r'\', '/')}/song.flac';
    File(path).writeAsBytesSync([...flac(), ...audio]);

    await TagEditor.save(songAt(path), const TagChanges(title: 'New title', artist: '', genre: 'Jazz'));

    final bytes = File(path).readAsBytesSync();
    expect(bytes.sublist(bytes.length - audio.length), audio);
    final tags = readAllMetadata(File(path)) as VorbisMetadata;
    expect(tags.title, ['New title']);
    expect(tags.artist, isEmpty);
    expect(tags.genres, ['Jazz']);
    expect(tags.replayGainTrackGain, ['-6.50 dB']);
    expect(tags.unknowns['RELEASETYPE'], 'single');
    expect(tags.pictures.single.bytes, [1, 2, 3, 4]);
  });

  test('a file it can’t make sense of is left as it was', () async {
    final path = '${dir.path.replaceAll(r'\', '/')}/old.mp3';
    // An ID3v2.2 tag, which isn't edited.
    final original = [...ascii.encode('ID3'), 2, 0, 0, 0, 0, 0, 0, ...audio];
    File(path).writeAsBytesSync(original);
    await expectLater(
      TagEditor.save(songAt(path), const TagChanges(title: 'New')),
      throwsA(isA<TagEditException>()),
    );
    expect(File(path).readAsBytesSync(), original);
  });

  test('v2.4 tags with plain sizes, as iTunes writes them, keep every frame', () async {
    List<int> frame(String id, List<int> body) => [...ascii.encode(id), ...be32(body.length), 0, 0, ...body];
    // A cover over 127 bytes: its plain size isn't valid read as syncsafe.
    final frames = [
      ...frame('TIT2', [3, ...utf8.encode('Old title')]),
      ...frame('APIC', [0, ...ascii.encode('image/png'), 0, 3, 0, ...List.filled(300, 7)]),
    ];
    final path = '${dir.path.replaceAll(r'\', '/')}/itunes.mp3';
    File(path).writeAsBytesSync([...ascii.encode('ID3'), 4, 0, 0, ...syncsafe(frames.length), ...frames, ...audio]);

    await TagEditor.save(songAt(path), const TagChanges(title: 'New title'));

    final tags = readAllMetadata(File(path)) as Mp3Metadata;
    expect(tags.songName, 'New title');
    expect(tags.pictures.single.bytes, List.filled(300, 7));
  });

  test('a damaged tag is left alone rather than saved with frames missing', () async {
    List<int> frame(String id, List<int> body) => [...ascii.encode(id), ...be32(body.length), 0, 0, ...body];
    // The second frame claims to run past the end of the tag.
    final frames = [
      ...frame('TIT2', [0, ...latin1.encode('Old title')]),
      ...ascii.encode('APIC'), ...be32(5000), 0, 0, 1, 2, 3,
    ];
    final path = '${dir.path.replaceAll(r'\', '/')}/damaged.mp3';
    final original = [...ascii.encode('ID3'), 3, 0, 0, ...syncsafe(frames.length), ...frames, ...audio];
    File(path).writeAsBytesSync(original);
    await expectLater(
      TagEditor.save(songAt(path), const TagChanges(title: 'New')),
      throwsA(isA<TagEditException>()),
    );
    expect(File(path).readAsBytesSync(), original);
  });

  /// The bodies of [id]'s frames in the ID3 tag at the start of [bytes].
  List<Uint8List> id3Frames(Uint8List bytes, String id) {
    final v4 = bytes[3] == 4;
    final size = (bytes[6] << 21) | (bytes[7] << 14) | (bytes[8] << 7) | bytes[9];
    final found = <Uint8List>[];
    var at = 10;
    while (at + 10 <= 10 + size && bytes[at] != 0) {
      final length = v4
          ? (bytes[at + 4] << 21) | (bytes[at + 5] << 14) | (bytes[at + 6] << 7) | bytes[at + 7]
          : ByteData.sublistView(bytes).getUint32(at + 4);
      if (ascii.decode(bytes.sublist(at, at + 4)) == id) found.add(bytes.sublist(at + 10, at + 10 + length));
      at += 10 + length;
    }
    return found;
  }

  const newLyrics = '[00:01.00] First line, café\n[00:05.50] 第二行\n\n[00:09.00] Last line';

  test('MP3 (v2.3): the lyrics shown are replaced, other languages stay, old user text frames go', () async {
    List<int> frame(String id, List<int> body) => [...ascii.encode(id), ...be32(body.length), 0, 0, ...body];
    final frames = [
      ...id3v23().sublist(10),
      ...frame('USLT', [0, ...ascii.encode('fra'), 0, ...latin1.encode('Autres paroles')]),
      ...frame('TXXX', [0, ...latin1.encode('UNSYNCEDLYRICS'), 0, ...latin1.encode('Old words')]),
    ];
    final path = '${dir.path.replaceAll(r'\', '/')}/lyrics.mp3';
    File(path).writeAsBytesSync([...ascii.encode('ID3'), 3, 0, 0, ...syncsafe(frames.length), ...frames, ...audio]);
    final song = songAt(path);

    await TagEditor.save(song, const TagChanges(lyrics: newLyrics));

    final bytes = File(path).readAsBytesSync();
    expect(bytes.sublist(bytes.length - audio.length), audio);
    final uslt = id3Frames(bytes, 'USLT');
    expect(uslt, hasLength(2));
    expect(ascii.decode(uslt[0].sublist(1, 4)), 'eng');
    expect(uslt[1], [0, ...ascii.encode('fra'), 0, ...latin1.encode('Autres paroles')]);
    expect(DesktopLibrary.id3UserText(File(path)), isNot(contains('UNSYNCEDLYRICS')));
    expect(DesktopLibrary.id3UserText(File(path))['REPLAYGAIN_TRACK_GAIN'], '-6.50 dB');
    expect(await DesktopLibrary.embeddedLyrics(song), newLyrics);
    expect((readAllMetadata(File(path)) as Mp3Metadata).songName, 'Old title');
  });

  test('MP3 (v2.4): lyrics are saved as UTF-8 and read back', () async {
    final path = '${dir.path.replaceAll(r'\', '/')}/new.mp3';
    File(path).writeAsBytesSync(audio);
    final song = songAt(path);
    await TagEditor.save(song, const TagChanges(title: 'Named', lyrics: newLyrics));

    final bytes = File(path).readAsBytesSync();
    expect(bytes[3], 4);
    final uslt = id3Frames(bytes, 'USLT').single;
    expect(uslt.sublist(0, 5), [3, ...ascii.encode('XXX'), 0]);
    expect(utf8.decode(uslt.sublist(5)), newLyrics);
    expect(await DesktopLibrary.embeddedLyrics(song), newLyrics);
  });

  /// A tag of [frames] in [version], then the audio, saved as [name].
  Song tagged(String name, int version, List<int> frames) {
    final path = '${dir.path.replaceAll(r'\', '/')}/$name';
    File(path).writeAsBytesSync([...ascii.encode('ID3'), version, 0, 0, ...syncsafe(frames.length), ...frames, ...audio]);
    return songAt(path);
  }

  List<int> plainFrame(String id, List<int> body, {int format = 0}) =>
      [...ascii.encode(id), ...be32(body.length), 0, format, ...body];

  test('MP3: with several languages the first with words is shown, and keeps its label', () async {
    final song = tagged('languages.mp3', 3, [
      ...plainFrame('USLT', [0, ...ascii.encode('eng'), 0]),
      ...plainFrame('USLT', [0, ...ascii.encode('fra'), ...latin1.encode('Paroles'), 0, ...latin1.encode('Mots')]),
      ...plainFrame('USLT', [0, ...ascii.encode('deu'), 0, ...latin1.encode('Worte')]),
    ]);
    expect(await DesktopLibrary.embeddedLyrics(song), 'Mots');
    expect(await DesktopLibrary.lyrics(song), 'Mots');

    await TagEditor.save(song, const TagChanges(lyrics: 'Nouveaux mots'));

    final uslt = id3Frames(File(song.path!).readAsBytesSync(), 'USLT');
    expect(uslt, hasLength(3));
    expect(ascii.decode(uslt[1].sublist(1, 4)), 'fra');
    expect(uslt[2], [0, ...ascii.encode('deu'), 0, ...latin1.encode('Worte')]);
    expect(await DesktopLibrary.embeddedLyrics(song), 'Nouveaux mots');
  });

  test('MP3: emptied lyrics take out every language', () async {
    final song = tagged('all.mp3', 3, [
      ...plainFrame('USLT', [0, ...ascii.encode('eng'), 0, ...latin1.encode('Words')]),
      ...plainFrame('USLT', [0, ...ascii.encode('fra'), 0, ...latin1.encode('Mots')]),
    ]);
    await TagEditor.save(song, const TagChanges(lyrics: ''));
    expect(id3Frames(File(song.path!).readAsBytesSync(), 'USLT'), isEmpty);
  });

  test('MP3: v2.4 lyrics with plain sizes are read', () async {
    final song = tagged('itunes_lyrics.mp3', 4, [
      ...plainFrame('APIC', [0, ...ascii.encode('image/png'), 0, 3, 0, ...List.filled(300, 7)]),
      ...plainFrame('USLT', [3, ...ascii.encode('eng'), 0, ...utf8.encode('Words')]),
    ]);
    expect(await DesktopLibrary.embeddedLyrics(song), 'Words');
  });

  test('MP3: empty frames are not damage', () async {
    final song = tagged('empty.mp3', 3, [
      ...plainFrame('TCOM', const []),
      ...plainFrame('USLT', [0, ...ascii.encode('eng'), 0, ...latin1.encode('Words')]),
    ]);
    expect(await DesktopLibrary.embeddedLyrics(song), 'Words');
  });

  test('MP3: lyrics that can\'t be read stop the editor, rather than showing as none', () async {
    final compressed = tagged('compressed.mp3', 3, plainFrame('USLT', [0, ...ascii.encode('eng'), 0, 1, 2], format: 0x80));
    await expectLater(DesktopLibrary.embeddedLyrics(compressed), throwsA(anything));
    final hidden = tagged('hidden.mp3', 3, plainFrame('TXXX', [0, ...latin1.encode('LYRICS'), 0, 1, 2], format: 0x80));
    await expectLater(DesktopLibrary.embeddedLyrics(hidden), throwsA(anything));
    final damaged = tagged('damaged.mp3', 3, [...ascii.encode('USLT'), ...be32(5000), 0, 0, 0, 1, 2]);
    await expectLater(DesktopLibrary.embeddedLyrics(damaged), throwsA(anything));
    // Unsynchronised, which the editor can't save.
    final path = '${dir.path.replaceAll(r'\', '/')}/unsync.mp3';
    final frames = plainFrame('USLT', [0, ...ascii.encode('eng'), 0, ...latin1.encode('Words')]);
    File(path).writeAsBytesSync([...ascii.encode('ID3'), 3, 0, 0x80, ...syncsafe(frames.length), ...frames, ...audio]);
    await expectLater(DesktopLibrary.embeddedLyrics(songAt(path)), throwsA(anything));
  });

  test('MP3: emptied lyrics are taken out', () async {
    final path = '${dir.path.replaceAll(r'\', '/')}/clear.mp3';
    File(path).writeAsBytesSync([...id3v23(), ...audio]);
    final song = songAt(path);
    expect(await DesktopLibrary.embeddedLyrics(song), 'Some lyrics');

    await TagEditor.save(song, const TagChanges(lyrics: ''));

    expect(id3Frames(File(path).readAsBytesSync(), 'USLT'), isEmpty);
    expect(await DesktopLibrary.embeddedLyrics(song), isNull);
    expect((readAllMetadata(File(path)) as Mp3Metadata).pictures.single.bytes, [1, 2, 3, 4]);
  });

  test('FLAC: lyrics keep their lines, and replace those under other names', () async {
    final path = '${dir.path.replaceAll(r'\', '/')}/lyrics.flac';
    File(path).writeAsBytesSync([...flac(), ...audio]);
    final song = songAt(path);
    await TagEditor.save(song, const TagChanges(lyrics: 'Old words'));
    expect(await DesktopLibrary.embeddedLyrics(song), 'Old words');

    await TagEditor.save(song, const TagChanges(lyrics: newLyrics));

    final tags = readAllMetadata(File(path)) as VorbisMetadata;
    expect(tags.lyric, newLyrics);
    expect(tags.title, ['Old title']);
    expect(tags.unknowns['RELEASETYPE'], 'single');
    expect(await DesktopLibrary.embeddedLyrics(song), newLyrics);

    await TagEditor.save(song, const TagChanges(lyrics: ''));
    expect(await DesktopLibrary.embeddedLyrics(song), isNull);
    final bytes = File(path).readAsBytesSync();
    expect(bytes.sublist(bytes.length - audio.length), audio);
  });

  test('MP3: lyrics only in a user text frame are shown, so saving can\'t lose them unseen', () async {
    List<int> frame(String id, List<int> body) => [...ascii.encode(id), ...be32(body.length), 0, 0, ...body];
    final frames = [
      ...frame('TIT2', [0, ...latin1.encode('Old title')]),
      ...frame('TXXX', [0, ...latin1.encode('UNSYNCEDLYRICS'), 0, ...latin1.encode('Hidden words')]),
    ];
    final path = '${dir.path.replaceAll(r'\', '/')}/txxx.mp3';
    File(path).writeAsBytesSync([...ascii.encode('ID3'), 3, 0, 0, ...syncsafe(frames.length), ...frames, ...audio]);

    expect(await DesktopLibrary.embeddedLyrics(songAt(path)), 'Hidden words');
    expect(await DesktopLibrary.lyrics(songAt(path)), 'Hidden words');
  });

  test('FLAC: lyrics under another name are shown', () async {
    final path = '${dir.path.replaceAll(r'\', '/')}/other.flac';
    File(path).writeAsBytesSync([...flac(extra: ['UNSYNCEDLYRICS=Hidden words']), ...audio]);

    expect(await DesktopLibrary.embeddedLyrics(songAt(path)), 'Hidden words');
  });

  test('only MP3 and FLAC can be edited', () {
    expect(TagEditor.canEdit(Song(id: 1, title: 't', uri: 'x', path: '/m/a.MP3')), isTrue);
    expect(TagEditor.canEdit(Song(id: 1, title: 't', uri: 'x', path: '/m/a.flac')), isTrue);
    expect(TagEditor.canEdit(Song(id: 1, title: 't', uri: 'x', path: '/m/a.ogg')), isFalse);
  });
}
