import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'desktop_library.dart';
import 'media_library.dart';

/// New values for a song's tags. A field left null stays as it is; an empty
/// one is taken out of the file.
class TagChanges {
  const TagChanges({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.genre,
    this.year,
    this.track,
    this.disc,
    this.lyrics,
    this.cover,
  });

  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final String? genre;
  final String? year;
  final String? track;
  final String? disc;

  /// Plain, or timed as LRC lines ("[01:23.45] words"), kept as written.
  final String? lyrics;

  /// A JPEG to add as the front cover, for a song without one.
  final Uint8List? cover;

  bool get isEmpty =>
      cover == null && [title, artist, album, albumArtist, genre, year, track, disc, lyrics].every((v) => v == null);
}

/// Why tags couldn't be saved, as the editor tells the user.
class TagEditException implements Exception {
  const TagEditException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Writes changed tags into songs' files. Only the fields edited change:
/// everything else in the file (covers, lyrics, ReplayGain and other tags
/// Blimp doesn't show) is copied across as it was. The new file is made
/// beside the old and read back before it takes its place, so a failure
/// leaves the song as it was.
abstract final class TagEditor {
  static const _filesChannel = MethodChannel('blimp/files');

  /// MP3 (ID3v2.3 and 2.4 tags), FLAC, Ogg Vorbis, Opus and M4A.
  static bool canEdit(Song song) => const {
    'mp3',
    'flac',
    'ogg',
    'oga',
    'opus',
    'm4a',
    'm4b',
    'mp4',
  }.contains((song.fileName ?? song.uri).split('.').last.toLowerCase());

  /// Saves [changes] into [song]'s file. On a phone, Android asks the user
  /// first; false if they said no. Throws [TagEditException] if it can't be
  /// done. [keepDate] leaves the file's date as it was on desktop, where it's
  /// when the song was added, so saving in the background doesn't reorder
  /// Recently Added.
  static Future<bool> save(Song song, TagChanges changes, {bool keepDate = false}) async {
    if (changes.isEmpty) return true;
    final mp3 = (song.fileName ?? song.uri).toLowerCase().endsWith('.mp3');
    if (isDesktop) {
      final path = song.path;
      if (path == null) throw const TagEditException("Couldn't find the song's file.");
      final edited = '$path.blimp-edit';
      await _edit(path, edited, changes, mp3: mp3);
      try {
        final date = keepDate ? await File(path).lastModified() : null;
        // Replaces the old file in one go.
        await File(edited).rename(path);
        if (date != null) await File(path).setLastModified(date);
      } on FileSystemException {
        await _delete(edited);
        throw const TagEditException("Couldn't save the file. If it's playing, try again once it isn't.");
      }
      return true;
    }
    final String? copy;
    try {
      copy = await _filesChannel.invokeMethod<String>('copySong', {'id': song.id});
    } on PlatformException {
      throw const TagEditException("Couldn't read the song's file.");
    }
    if (copy == null) throw const TagEditException("Couldn't read the song's file.");
    final edited = '$copy.edited';
    try {
      await _edit(copy, edited, changes, mp3: mp3);
    } finally {
      await _delete(copy);
    }
    final saved = await MediaLibrary.writeWithAccess(
      () => _filesChannel.invokeMethod<bool>('writeSong', {'id': song.id, 'path': edited}),
    );
    await _delete(edited);
    return saved;
  }

  static Future<void> _delete(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  /// Writes [source] with [changes] to [target], off the UI thread, then
  /// checks the result reads back. Only [mp3] files get an ID3 tag: an MP3 can
  /// start with anything, but one put on the front of another format moves
  /// its audio away from where the file says it is.
  static Future<void> _edit(String source, String target, TagChanges changes, {required bool mp3}) async {
    final error = await Isolate.run(() {
      try {
        final input = File(source);
        final head = input.openSync();
        final magic = head.readSync(8);
        head.closeSync();
        final start = latin1.decode(magic);
        if (start.startsWith('fLaC')) {
          _editFlac(input, File(target), changes);
        } else if (start.startsWith('OggS')) {
          _editOgg(input, File(target), changes);
        } else if (start.length == 8 && start.endsWith('ftyp')) {
          _editMp4(input, File(target), changes);
        } else if (mp3) {
          _editMp3(input, File(target), changes);
        } else {
          throw const TagEditException('This file is stored in a way Blimp can’t edit.');
        }
        // Read back: a file the reader can't make sense of isn't saved.
        final check = readMetadata(File(target));
        if (changes.title case final title? when title.isNotEmpty && check.title != title) {
          throw const TagEditException("Couldn't save the tags in this file.");
        }
        return null;
      } on TagEditException catch (e) {
        return e.message;
      } catch (_) {
        return "Couldn't save the tags in this file.";
      }
    });
    if (error != null) {
      await _delete(target);
      throw TagEditException(error);
    }
  }

  // -------------------------------------------------------------------------
  // MP3: ID3v2 frames

  static void _editMp3(File source, File target, TagChanges changes) {
    final reader = source.openSync();
    var version = 4;
    var audioStart = 0;
    final frames = <Id3Frame>[];
    try {
      final header = reader.readSync(10);
      if (header.length == 10 && ascii.decode(header.sublist(0, 3), allowInvalid: true) == 'ID3') {
        version = header[3];
        final flags = header[5];
        if (version != 3 && version != 4) {
          throw const TagEditException('This file has an old kind of tag Blimp can’t edit.');
        }
        // Unsynchronised tags are rare and would need undoing byte by byte.
        if (flags & 0x80 != 0) throw const TagEditException('This file’s tags are stored in a way Blimp can’t edit.');
        final size = _syncsafe(header, 6);
        audioStart = 10 + size + (flags & 0x10 != 0 ? 10 : 0);
        final body = reader.readSync(size);
        // Any extended header is left out of the new tag.
        final read = DesktopLibrary.id3Frames(body, version: version, flags: flags);
        // Never saved with frames missing: the rest of the tag would be lost.
        if (read == null) throw const TagEditException('This file’s tags look damaged, so Blimp left them alone.');
        frames.addAll(read);
      }
    } finally {
      reader.closeSync();
    }

    Uint8List text(String value) => version == 4
        // UTF-8, which version 2.4 allows.
        ? Uint8List.fromList([3, ...utf8.encode(value)])
        // UTF-16 with a byte order mark, as 2.3 has no UTF-8.
        : Uint8List.fromList([
            1,
            0xFF,
            0xFE,
            for (final unit in value.codeUnits) ...[unit & 0xFF, unit >> 8],
          ]);
    void set(List<String> ids, String? value) {
      if (value == null) return;
      frames.removeWhere((f) => ids.contains(f.id));
      if (value.trim().isNotEmpty) frames.add((id: ids.first, flags: Uint8List(2), data: text(value.trim())));
    }

    set(['TIT2'], changes.title);
    set(['TPE1'], changes.artist);
    set(['TALB'], changes.album);
    set(['TPE2'], changes.albumArtist);
    set(['TCON'], changes.genre);
    set(['TRCK'], changes.track);
    set(['TPOS'], changes.disc);
    set(version == 4 ? ['TDRC', 'TYER'] : ['TYER', 'TDRC'], changes.year);
    if (changes.cover case final cover?) {
      frames.add((
        id: 'APIC',
        flags: Uint8List(2),
        // The encoding, the image type, "front cover", no description, then
        // the picture.
        data: Uint8List.fromList([0, ...ascii.encode(_coverType), 0, 3, 0, ...cover]),
      ));
    }
    if (changes.lyrics case final lyrics?) {
      // Only the words the editor showed are replaced, keeping their
      // language; lyrics in other languages stay. Emptied, the song has no
      // lyrics, so they all go.
      if (lyrics.trim().isEmpty) {
        frames.removeWhere((f) => f.id == 'USLT');
      } else {
        final shown = DesktopLibrary.shownLyricsFrame(frames, version);
        // "XXX" is ID3's language for unknown.
        final (language, description) =
            shown >= 0 ? DesktopLibrary.lyricsLabel(frames[shown], version) : (ascii.encode('XXX'), '');
        final body = text(lyrics.trim());
        final frame = (
          id: 'USLT',
          flags: Uint8List(2),
          // The encoding, a language, a description, then the words.
          data: Uint8List.fromList([
            body[0],
            ...language,
            if (description.isNotEmpty) ...text(description).skip(1),
            ...(version == 4 ? [0] : [0, 0]),
            ...body.skip(1),
          ]),
        );
        if (shown >= 0) {
          frames[shown] = frame;
        } else {
          frames.add(frame);
        }
      }
      // Lyrics some taggers keep in a user text frame go too, so the old
      // ones can't turn up again in apps that read those.
      frames.removeWhere(
        (f) => f.id == 'TXXX' && DesktopLibrary.lyricsKeys.contains(DesktopLibrary.userTextFrame(f.data)?.$1.toUpperCase()),
      );
    }

    final tag = BytesBuilder();
    for (final frame in frames) {
      tag
        ..add(ascii.encode(frame.id))
        ..add(version == 4 ? _toSyncsafe(frame.data.length) : _uint32(frame.data.length))
        ..add(frame.flags)
        ..add(frame.data);
    }
    // Room to grow, so the next edit can be smaller work for other taggers.
    tag.add(Uint8List(_padding));
    final out = target.openSync(mode: FileMode.write);
    try {
      out
        ..writeFromSync(ascii.encode('ID3'))
        ..writeFromSync([version, 0, 0])
        ..writeFromSync(_toSyncsafe(tag.length))
        ..writeFromSync(tag.takeBytes());
      _copyFrom(source, audioStart, out);
    } finally {
      out.closeSync();
    }
  }

  static const _padding = 1024;

  static const _coverType = 'image/jpeg';

  static int _syncsafe(List<int> bytes, int at) =>
      (bytes[at] & 0x7F) << 21 | (bytes[at + 1] & 0x7F) << 14 | (bytes[at + 2] & 0x7F) << 7 | bytes[at + 3] & 0x7F;

  static List<int> _toSyncsafe(int value) => [
    (value >> 21) & 0x7F,
    (value >> 14) & 0x7F,
    (value >> 7) & 0x7F,
    value & 0x7F,
  ];

  static List<int> _uint32(int value) => [(value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF];

  static List<int> _uint32le(int value) => [value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF, (value >> 24) & 0xFF];

  /// Copies [source] from [start] up to [end] (or its end) onto [out], a
  /// piece at a time.
  static void _copyFrom(File source, int start, RandomAccessFile out, [int? end]) {
    final reader = source.openSync();
    try {
      reader.setPositionSync(start);
      var left = (end ?? reader.lengthSync()) - start;
      while (left > 0) {
        final chunk = reader.readSync(min(1 << 20, left));
        if (chunk.isEmpty) break;
        out.writeFromSync(chunk);
        left -= chunk.length;
      }
    } finally {
      reader.closeSync();
    }
  }

  // -------------------------------------------------------------------------
  // FLAC: the Vorbis comment block

  static void _editFlac(File source, File target, TagChanges changes) {
    final reader = source.openSync();
    final blocks = <({int type, Uint8List data})>[];
    var audioStart = 4;
    try {
      reader.setPositionSync(4);
      while (true) {
        final header = reader.readSync(4);
        if (header.length < 4) throw const TagEditException('This FLAC file looks damaged.');
        final length = header[1] << 16 | header[2] << 8 | header[3];
        final data = reader.readSync(length);
        if (data.length < length) throw const TagEditException('This FLAC file looks damaged.');
        // Padding is made afresh at the end.
        if (header[0] & 0x7F != 1) blocks.add((type: header[0] & 0x7F, data: data));
        audioStart += 4 + length;
        if (header[0] & 0x80 != 0) break;
      }
    } finally {
      reader.closeSync();
    }

    final at = blocks.indexWhere((b) => b.type == 4);
    final (:vendor, :comments, end: _) =
        at >= 0 ? _readComments(blocks[at].data) : (vendor: 'Blimp', comments: <String>[], end: 0);
    final comment = (type: 4, data: _writeComments(vendor, _changedComments(comments, changes)));
    if (at >= 0) {
      blocks[at] = comment;
    } else {
      blocks.add(comment);
    }
    if (changes.cover case final cover?) blocks.add((type: 6, data: _flacPicture(cover)));
    blocks.add((type: 1, data: Uint8List(_padding)));

    final out = target.openSync(mode: FileMode.write);
    try {
      out.writeFromSync(ascii.encode('fLaC'));
      for (final (i, b) in blocks.indexed) {
        final last = i == blocks.length - 1;
        out
          ..writeFromSync([(last ? 0x80 : 0) | b.type, (b.data.length >> 16) & 0xFF, (b.data.length >> 8) & 0xFF, b.data.length & 0xFF])
          ..writeFromSync(b.data);
      }
      _copyFrom(source, audioStart, out);
    } finally {
      out.closeSync();
    }
  }

  /// The vendor and comments of a Vorbis comment block in [bytes], and where
  /// the block ends.
  static ({String vendor, List<String> comments, int end}) _readComments(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    var i = 0;
    int next32() {
      final value = data.getUint32(i, Endian.little);
      i += 4;
      return value;
    }

    final vendorLength = next32();
    final vendor = utf8.decode(bytes.sublist(i, i + vendorLength), allowMalformed: true);
    i += vendorLength;
    final count = next32();
    final comments = <String>[];
    for (var n = 0; n < count && i + 4 <= bytes.length; n++) {
      final length = next32();
      if (i + length > bytes.length) break;
      comments.add(utf8.decode(bytes.sublist(i, i + length), allowMalformed: true));
      i += length;
    }
    return (vendor: vendor, comments: comments, end: i);
  }

  static Uint8List _writeComments(String vendor, List<String> comments) {
    final block = BytesBuilder()
      ..add(_uint32le(utf8.encode(vendor).length))
      ..add(utf8.encode(vendor))
      ..add(_uint32le(comments.length));
    for (final comment in comments) {
      final bytes = utf8.encode(comment);
      block
        ..add(_uint32le(bytes.length))
        ..add(bytes);
    }
    return block.takeBytes();
  }

  /// [comments] with [changes] made, for FLAC and Ogg files alike.
  static List<String> _changedComments(List<String> comments, TagChanges changes) {
    void set(List<String> keys, String? value) {
      if (value == null) return;
      comments = [
        for (final comment in comments)
          if (!keys.contains(comment.split('=').first.toUpperCase())) comment,
      ];
      if (value.trim().isNotEmpty) comments.add('${keys.first}=${value.trim()}');
    }

    set(['TITLE'], changes.title);
    set(['ARTIST'], changes.artist);
    set(['ALBUM'], changes.album);
    set(['ALBUMARTIST', 'ALBUM ARTIST', 'ALBUM_ARTIST'], changes.albumArtist);
    set(['GENRE'], changes.genre);
    set(['DATE', 'YEAR'], changes.year);
    set(['TRACKNUMBER'], changes.track);
    set(['DISCNUMBER'], changes.disc);
    set(DesktopLibrary.lyricsKeys, changes.lyrics);
    return comments;
  }

  /// A FLAC picture block holding [cover]. Ogg files keep the same block in
  /// a comment.
  static Uint8List _flacPicture(Uint8List cover) {
    final picture = BytesBuilder()
      // "Front cover", the image type, and no description.
      ..add(_uint32(3))
      ..add(_uint32(_coverType.length))
      ..add(ascii.encode(_coverType))
      ..add(_uint32(0))
      // Width, height, colour depth and palette size, which readers take
      // from the image itself when they're zero.
      ..add(Uint8List(16))
      ..add(_uint32(cover.length))
      ..add(cover);
    return picture.takeBytes();
  }

  // -------------------------------------------------------------------------
  // Ogg Vorbis and Opus: the comment packet

  static void _editOgg(File source, File target, TagChanges changes) {
    const unsupported = TagEditException('Blimp can only edit tags in plain Ogg Vorbis and Opus files.');
    const damaged = TagEditException('This Ogg file looks damaged.');
    final reader = source.openSync();
    final out = target.openSync(mode: FileMode.write);
    try {
      ({Uint8List header, Uint8List lacing, Uint8List body})? nextPage() {
        final header = reader.readSync(27);
        if (header.isEmpty) return null;
        if (header.length < 27 || latin1.decode(header.sublist(0, 4)) != 'OggS') throw damaged;
        final lacing = reader.readSync(header[26]);
        if (lacing.length < header[26]) throw damaged;
        final length = lacing.fold(0, (sum, segment) => sum + segment);
        final body = reader.readSync(length);
        if (body.length < length) throw damaged;
        return (header: header, lacing: lacing, body: body);
      }

      var page = nextPage() ?? (throw damaged);
      final serial = page.header.sublist(14, 18);
      bool sameStream(Uint8List header) => listEquals(header.sublist(14, 18), serial);

      // The packets before the audio: Opus has two, Vorbis three. They end
      // with a page, so the audio pages after them can be copied whole.
      final idMagic = latin1.decode(page.body.take(8).toList());
      final vorbis = idMagic.startsWith('\x01vorbis');
      if (!vorbis && idMagic != 'OpusHead') throw unsupported;
      final wanted = vorbis ? 3 : 2;
      final commentMagic = vorbis ? '\x03vorbis' : 'OpusTags';
      final packets = <Uint8List>[];
      final partial = BytesBuilder();
      while (true) {
        if (!sameStream(page.header)) throw unsupported;
        var at = 0;
        for (final segment in page.lacing) {
          partial.add(page.body.sublist(at, at + segment));
          at += segment;
          if (segment < 255) packets.add(partial.takeBytes());
        }
        if (packets.length >= wanted) break;
        page = nextPage() ?? (throw damaged);
      }
      if (packets.length > wanted || partial.isNotEmpty) throw unsupported;

      final comment = packets[1];
      if (latin1.decode(comment.take(commentMagic.length).toList()) != commentMagic) throw unsupported;
      final (:vendor, :comments, :end) = _readComments(comment.sublist(commentMagic.length));
      final changed = [
        ..._changedComments(comments, changes),
        if (changes.cover case final cover?) 'METADATA_BLOCK_PICTURE=${base64.encode(_flacPicture(cover))}',
      ];
      packets[1] = Uint8List.fromList([
        ...latin1.encode(commentMagic),
        ..._writeComments(vendor, changed),
        // Vorbis's closing bit, or whatever Opus keeps after the comments.
        ...comment.sublist(commentMagic.length + end),
      ]);

      var sequence = 0;
      for (final (i, packet) in packets.indexed) {
        sequence = _writeOggPacket(out, packet, serial, sequence, first: i == 0);
      }
      // The audio, numbered on from the new pages.
      for (var next = nextPage(); next != null; next = nextPage()) {
        if (!sameStream(next.header)) throw unsupported;
        _writeOggPage(out, next.header, next.lacing, next.body, sequence++);
      }
    } finally {
      reader.closeSync();
      out.closeSync();
    }
  }

  /// Writes [packet] as pages of its own, numbered from [sequence]; returns
  /// the next page's number. [first] marks the start of the stream.
  static int _writeOggPacket(RandomAccessFile out, Uint8List packet, List<int> serial, int sequence, {required bool first}) {
    const segmentSize = 255, pageSegments = 255;
    var at = 0;
    while (true) {
      final left = packet.length - at;
      // A packet ends with a segment shorter than 255, even an empty one.
      final ends = left ~/ segmentSize + 1 <= pageSegments;
      final segments = ends ? left ~/ segmentSize + 1 : pageSegments;
      final length = ends ? left : segments * segmentSize;
      final header = Uint8List(27)..setAll(0, ascii.encode('OggS'));
      header[5] = at > 0 ? 1 : (first ? 2 : 0);
      // No packet ends on this page: its position is "none", all ones.
      if (!ends) header.fillRange(6, 14, 0xFF);
      header.setAll(14, serial);
      header[26] = segments;
      final lacing = Uint8List(segments)..fillRange(0, segments, segmentSize);
      if (ends) lacing[segments - 1] = left % segmentSize;
      _writeOggPage(out, header, lacing, packet.sublist(at, at + length), sequence++);
      at += length;
      if (ends) return sequence;
    }
  }

  /// Writes a page as number [sequence], with its checksum worked out again.
  static void _writeOggPage(RandomAccessFile out, Uint8List header, Uint8List lacing, Uint8List body, int sequence) {
    final view = ByteData.sublistView(header)
      ..setUint32(18, sequence, Endian.little)
      ..setUint32(22, 0, Endian.little);
    var crc = 0;
    for (final part in [header, lacing, body]) {
      for (final byte in part) {
        crc = (crc << 8 & 0xFFFFFFFF) ^ _oggCrcTable[(crc >> 24) ^ byte];
      }
    }
    view.setUint32(22, crc, Endian.little);
    out
      ..writeFromSync(header)
      ..writeFromSync(lacing)
      ..writeFromSync(body);
  }

  static final _oggCrcTable = [
    for (var i = 0; i < 256; i++)
      () {
        var value = i << 24;
        for (var bit = 0; bit < 8; bit++) {
          value = (value & 0x80000000 != 0 ? value << 1 ^ 0x04C11DB7 : value << 1) & 0xFFFFFFFF;
        }
        return value;
      }(),
  ];

  // -------------------------------------------------------------------------
  // M4A: the atoms under moov/udta/meta/ilst

  static void _editMp4(File source, File target, TagChanges changes) {
    const damaged = TagEditException('This M4A file looks damaged.');
    final reader = source.openSync();
    final int moovStart, moovSize;
    final _Atom moov;
    try {
      final length = reader.lengthSync();
      int? foundAt, foundSize;
      var at = 0;
      while (at + 8 <= length) {
        reader.setPositionSync(at);
        final head = reader.readSync(16);
        final view = ByteData.sublistView(head);
        final name = latin1.decode(head.sublist(4, 8));
        var size = view.getUint32(0);
        if (size == 0) size = length - at;
        if (size == 1) {
          if (head.length < 16) throw damaged;
          size = view.getUint64(8);
        }
        if (size < 8 || at + size > length) throw damaged;
        // Songs in fragments keep their places elsewhere.
        if (name == 'moof') throw const TagEditException('This file is stored in a way Blimp can’t edit.');
        if (name == 'moov') (foundAt, foundSize) = (at, size);
        at += size;
      }
      if (foundAt == null || foundSize == null) throw damaged;
      (moovStart, moovSize) = (foundAt, foundSize);
      reader.setPositionSync(moovStart);
      moov = _Atom.parse(reader.readSync(moovSize)) ?? (throw damaged);
    } finally {
      reader.closeSync();
    }

    _changeItems(moov, changes);

    // Where the audio is stored is kept as places in the file, so any audio
    // after the tags moves by however much they grew.
    final moved = moov.size - moovSize;
    if (moved != 0) _moveChunks(moov, moovStart + moovSize, moved);

    final out = target.openSync(mode: FileMode.write);
    try {
      _copyFrom(source, 0, out, moovStart);
      out.writeFromSync(moov.bytes());
      _copyFrom(source, moovStart + moovSize, out);
    } finally {
      out.closeSync();
    }
  }

  static void _changeItems(_Atom moov, TagChanges changes) {
    final udta = moov.childOrAdd('udta');
    var meta = udta.child('meta');
    if (meta == null) {
      meta = _Atom.container('meta', prefix: Uint8List(4));
      // Says the tags are iTunes's kind.
      meta.children!.add(_Atom('hdlr', Uint8List.fromList([...Uint8List(8), ...ascii.encode('mdirappl'), ...Uint8List(9)])));
      udta.children!.add(meta);
    }
    final items = meta.childOrAdd('ilst').children!;

    Uint8List data(int type, List<int> value) =>
        Uint8List.fromList([..._uint32(16 + value.length), ...ascii.encode('data'), ..._uint32(type), 0, 0, 0, 0, ...value]);

    void set(List<String> names, String? value) {
      if (value == null) return;
      items.removeWhere((item) => names.contains(item.name));
      if (value.trim().isNotEmpty) items.add(_Atom(names.first, data(1, utf8.encode(value.trim()))));
    }

    // Numbers are "3" or "3/12"; a total already there stays if none's given.
    void number(String name, String? value) {
      if (value == null) return;
      final old = items.where((item) => item.name == name).firstOrNull?.data;
      items.removeWhere((item) => item.name == name);
      if (value.trim().isEmpty) return;
      final parts = value.trim().split('/');
      final n = int.tryParse(parts[0].trim());
      if (n == null) throw const TagEditException('Track and disc need to be numbers.');
      final total = (parts.length > 1 ? int.tryParse(parts[1].trim()) : null) ??
          (old != null && old.length >= 22 ? old[20] << 8 | old[21] : 0);
      items.add(_Atom(name, data(0, [0, 0, n >> 8, n & 0xFF, total >> 8, total & 0xFF, if (name == 'trkn') ...[0, 0]])));
    }

    set(['\xA9nam'], changes.title);
    set(['\xA9ART'], changes.artist);
    set(['\xA9alb'], changes.album);
    set(['aART'], changes.albumArtist);
    // The old numbered kind of genre goes too.
    set(['\xA9gen', 'gnre'], changes.genre);
    set(['\xA9day'], changes.year);
    number('trkn', changes.track);
    number('disk', changes.disc);
    set(['\xA9lyr'], changes.lyrics);
    if (changes.cover case final cover?) {
      const jpeg = 13;
      final covers = items.where((item) => item.name == 'covr').firstOrNull;
      if (covers == null) {
        items.add(_Atom('covr', data(jpeg, cover)));
      } else {
        covers.data = Uint8List.fromList([...covers.data!, ...data(jpeg, cover)]);
      }
    }
  }

  /// Adds [moved] to each place in [atom]'s tracks that's [from] or later.
  static void _moveChunks(_Atom atom, int from, int moved) {
    for (final child in atom.children ?? const <_Atom>[]) {
      _moveChunks(child, from, moved);
      if (child.name != 'stco' && child.name != 'co64') continue;
      final width = child.name == 'co64' ? 8 : 4;
      final view = ByteData.sublistView(child.data!);
      final count = view.getUint32(4);
      if (8 + count * width > child.data!.length) throw const TagEditException('This M4A file looks damaged.');
      for (var i = 0; i < count; i++) {
        final at = 8 + i * width;
        final place = width == 8 ? view.getUint64(at) : view.getUint32(at);
        if (place < from) continue;
        if (width == 8) {
          view.setUint64(at, place + moved);
        } else {
          if (place + moved > 0xFFFFFFFF) throw const TagEditException('This file is too big for Blimp to edit.');
          view.setUint32(at, place + moved);
        }
      }
    }
  }
}

/// One atom of an MP4 file: either [data], or [children] after a [prefix].
class _Atom {
  _Atom(this.name, this.data) : children = null, prefix = null, tail = null;

  _Atom.container(this.name, {this.prefix, this.tail}) : children = [], data = null;

  final String name;
  Uint8List? data;
  final List<_Atom>? children;

  /// Bytes before the children: most meta atoms start with a version.
  final Uint8List? prefix;

  /// Blank bytes after the last child, which some files end udta with.
  final Uint8List? tail;

  static const _containers = {'moov', 'trak', 'mdia', 'minf', 'stbl', 'udta', 'meta', 'ilst'};

  /// The atom at the start of [bytes]; null if it doesn't fit together.
  static _Atom? parse(Uint8List bytes) {
    final first = _at(bytes, 0);
    return first == null ? null : _build(first.name, first.body);
  }

  /// The atom at [at] in [bytes]: its name, what's in it, and its full size.
  static ({String name, Uint8List body, int size})? _at(Uint8List bytes, int at) {
    if (at + 8 > bytes.length) return null;
    final view = ByteData.sublistView(bytes);
    var size = view.getUint32(at);
    var header = 8;
    if (size == 0) size = bytes.length - at;
    if (size == 1) {
      if (at + 16 > bytes.length) return null;
      size = view.getUint64(at + 8);
      header = 16;
    }
    if (size < header || at + size > bytes.length) return null;
    return (name: latin1.decode(bytes.sublist(at + 4, at + 8)), body: bytes.sublist(at + header, at + size), size: size);
  }

  static _Atom? _build(String name, Uint8List body) {
    if (!_containers.contains(name)) return _Atom(name, body);
    // A meta atom has a version first, unless it's QuickTime's kind.
    final start = name == 'meta' && body.length >= 8 && latin1.decode(body.sublist(4, 8)) != 'hdlr' ? 4 : 0;
    final children = <_Atom>[];
    var at = start;
    while (true) {
      final next = _at(body, at);
      if (next == null) break;
      final child = _build(next.name, next.body);
      if (child == null) return null;
      children.add(child);
      at += next.size;
    }
    final tail = body.sublist(at);
    if (tail.any((byte) => byte != 0)) return null;
    return _Atom.container(name, prefix: body.sublist(0, start), tail: tail)..children!.addAll(children);
  }

  _Atom? child(String name) => children!.where((c) => c.name == name).firstOrNull;

  _Atom childOrAdd(String name) {
    if (child(name) case final found?) return found;
    final added = _Atom.container(name);
    children!.add(added);
    return added;
  }

  int get size =>
      8 +
      (data?.length ?? 0) +
      (prefix?.length ?? 0) +
      (tail?.length ?? 0) +
      (children?.fold<int>(0, (sum, child) => sum + child.size) ?? 0);

  Uint8List bytes() {
    final out = BytesBuilder(copy: false)
      ..add(TagEditor._uint32(size))
      ..add(latin1.encode(name));
    if (data case final data?) out.add(data);
    if (prefix case final prefix?) out.add(prefix);
    for (final child in children ?? const <_Atom>[]) {
      out.add(child.bytes());
    }
    if (tail case final tail?) out.add(tail);
    return out.takeBytes();
  }
}
