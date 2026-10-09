import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:blimp/services/desktop_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The start of a FLAC file: its marker and STREAMINFO block.
Uint8List flacHeader({required int sampleRate, required int channels, required int bits}) {
  final bytes = ByteData(42);
  bytes.setUint32(0, 0x664C6143); // fLaC
  bytes.setUint32(4, 0x80000022); // last block, STREAMINFO, 34 bytes
  bytes.setUint32(18, sampleRate << 12 | (channels - 1) << 9 | (bits - 1) << 4);
  return bytes.buffer.asUint8List();
}

/// A WAV file's header with no samples after it.
Uint8List wavHeader({required int sampleRate, required int channels, required int bits}) {
  final bytes = ByteData(44);
  void tag(int at, String s) => bytes.buffer.asUint8List().setRange(at, at + 4, ascii.encode(s));
  tag(0, 'RIFF');
  bytes.setUint32(4, 36, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little); // PCM
  bytes.setUint16(22, channels, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * channels * bits ~/ 8, Endian.little);
  bytes.setUint16(32, channels * bits ~/ 8, Endian.little);
  bytes.setUint16(34, bits, Endian.little);
  tag(36, 'data');
  return bytes.buffer.asUint8List();
}

/// An ID3v2 tag holding [frames], each an id and its body.
Uint8List id3Tag(int version, List<(String, List<int>)> frames) {
  final body = <int>[];
  for (final (id, data) in frames) {
    final n = data.length;
    body
      ..addAll(ascii.encode(id))
      // 2.4 sizes are syncsafe (7 bits a byte); 2.3 sizes are plain.
      ..addAll(
        version == 4
            ? [n >> 21 & 0x7F, n >> 14 & 0x7F, n >> 7 & 0x7F, n & 0x7F]
            : [n >> 24, n >> 16 & 0xFF, n >> 8 & 0xFF, n & 0xFF],
      )
      ..addAll([0, 0])
      ..addAll(data);
  }
  body.addAll(List.filled(16, 0)); // padding
  final n = body.length;
  return Uint8List.fromList([
    ...ascii.encode('ID3'),
    version,
    0,
    0,
    n >> 21 & 0x7F,
    n >> 14 & 0x7F,
    n >> 7 & 0x7F,
    n & 0x7F,
    ...body,
  ]);
}

/// A TXXX frame body in Latin-1 (0), UTF-16 with a BOM (1) or UTF-8 (3).
List<int> userText(int encoding, String description, String value) => switch (encoding) {
  1 => [1, 0xFF, 0xFE, ...utf16le(description), 0, 0, 0xFF, 0xFE, ...utf16le(value)],
  3 => [3, ...utf8.encode(description), 0, ...utf8.encode(value)],
  _ => [0, ...latin1.encode(description), 0, ...latin1.encode(value)],
};

List<int> utf16le(String s) => [
  for (final unit in s.codeUnits) ...[unit & 0xFF, unit >> 8],
];

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

  test('parseReleaseType reads the main type, as the phone app does', () {
    expect(DesktopLibrary.parseReleaseType('Album'), 'album');
    expect(DesktopLibrary.parseReleaseType('album; compilation'), 'album');
    expect(DesktopLibrary.parseReleaseType('EP/Live'), 'ep');
    expect(DesktopLibrary.parseReleaseType(' single '), 'single');
    expect(DesktopLibrary.parseReleaseType('compilation'), isNull);
    expect(DesktopLibrary.parseReleaseType(null), isNull);
  });

  group('id3UserText', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('blimp_id3_test'));
    tearDown(() => dir.delete(recursive: true));

    Future<Map<String, String>> read(Uint8List tag) async {
      final file = File('${dir.path}/song.mp3');
      await file.writeAsBytes([...tag, 0xFF, 0xFB, 0x90, 0x00]);
      return DesktopLibrary.id3UserText(file);
    }

    test('reads ReplayGain and release type from ID3v2.3, in Latin-1 and UTF-16', () async {
      final tags = await read(
        id3Tag(3, [
          ('TIT2', [0, ...ascii.encode('A song')]),
          ('TXXX', userText(0, 'replaygain_track_gain', '-6.54 dB')),
          ('TXXX', userText(1, 'RELEASETYPE', 'single')),
        ]),
      );
      expect(tags, {'REPLAYGAIN_TRACK_GAIN': '-6.54 dB', 'RELEASETYPE': 'single'});
    });

    test('reads ID3v2.4, with syncsafe sizes and UTF-8', () async {
      final tags = await read(id3Tag(4, [('TXXX', userText(3, 'MusicBrainz Album Type', 'ep'))]));
      expect(tags, {'MUSICBRAINZ ALBUM TYPE': 'ep'});
    });

    test('is empty for a file with no ID3 tag', () async {
      expect(await read(Uint8List.fromList(ascii.encode('not a tag at all'))), isEmpty);
    });
  });

  group('getSongs', () {
    late Directory root;
    late Directory support;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('blimp_library_test');
      support = await Directory.systemTemp.createTemp('blimp_support_test');
      DesktopLibrary.cachePathOverride = support.path;
      SharedPreferences.setMockInitialValues({});
      await DesktopLibrary.setMusicFolder(root.path);
    });

    tearDown(() async {
      await root.delete(recursive: true);
      await support.delete(recursive: true);
    });

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

    test('skips hidden folders and what macOS leaves in zips', () async {
      await File('${root.path}/Album/__MACOSX/._01 Song.mp3').create(recursive: true);
      await File('${root.path}/Album/._01 Song.mp3').create(recursive: true);
      await File('${root.path}/.hidden/song.mp3').create(recursive: true);
      await File('${root.path}/Album/01 Song.mp3').create(recursive: true);

      final songs = await DesktopLibrary.getSongs();

      expect(songs.map((s) => s.title), ['01 Song']);
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

    test("reuses the saved scan for files that haven't changed", () async {
      await File('${root.path}/a.mp3').create();
      await DesktopLibrary.getSongs();

      // Rewrite the saved title: if the file were read again, it'd be lost.
      final cache = File('${support.path}/desktop_library.json');
      final json = jsonDecode(await cache.readAsString()) as Map<String, Object?>;
      final entry = (json['files'] as Map<String, Object?>).values.single as Map<String, Object?>;
      (entry['song'] as Map<String, Object?>)['title'] = 'From the cache';
      await cache.writeAsString(jsonEncode(json));

      expect((await DesktopLibrary.getSongs()).single.title, 'From the cache');
    });

    test('reads bit depth from FLAC and WAV headers for hi-res', () async {
      await File('${root.path}/hires.flac').writeAsBytes(flacHeader(sampleRate: 96000, channels: 2, bits: 24));
      await File('${root.path}/cd.flac').writeAsBytes(flacHeader(sampleRate: 44100, channels: 2, bits: 16));
      await File('${root.path}/studio.wav').writeAsBytes(wavHeader(sampleRate: 48000, channels: 1, bits: 24));

      final songs = await DesktopLibrary.getSongs();
      final byTitle = {for (final s in songs) s.title: s};

      expect(DesktopLibrary.audioFormat(byTitle['hires']!)?.label, startsWith('FLAC · 24-bit · 96 kHz'));
      expect(DesktopLibrary.audioFormat(byTitle['cd']!)?.isHiRes, isFalse);
      expect(DesktopLibrary.audioFormat(byTitle['studio']!)?.channels, 1);
      expect(DesktopLibrary.hiRes(songs), {byTitle['hires']!.id, byTitle['studio']!.id});
    });
  });
}
