import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
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

  bool get isEmpty => [title, artist, album, albumArtist, genre, year, track, disc, lyrics].every((v) => v == null);
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

  /// MP3 (ID3v2.3 and 2.4 tags) and FLAC.
  static bool canEdit(Song song) =>
      const {'mp3', 'flac'}.contains((song.fileName ?? song.uri).split('.').last.toLowerCase());

  /// Saves [changes] into [song]'s file. On a phone, Android asks the user
  /// first; false if they said no. Throws [TagEditException] if it can't be
  /// done.
  static Future<bool> save(Song song, TagChanges changes) async {
    if (changes.isEmpty) return true;
    if (isDesktop) {
      final path = song.path;
      if (path == null) throw const TagEditException("Couldn't find the song's file.");
      final edited = '$path.blimp-edit';
      await _edit(path, edited, changes);
      try {
        // Replaces the old file in one go.
        await File(edited).rename(path);
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
      await _edit(copy, edited, changes);
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
  /// checks the result reads back.
  static Future<void> _edit(String source, String target, TagChanges changes) async {
    final error = await Isolate.run(() {
      try {
        final input = File(source);
        final head = input.openSync();
        final magic = head.readSync(4);
        head.closeSync();
        if (magic.length == 4 && ascii.decode(magic, allowInvalid: true) == 'fLaC') {
          _editFlac(input, File(target), changes);
        } else {
          _editMp3(input, File(target), changes);
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

  /// Copies [source] from [start] to its end onto [out], a piece at a time.
  static void _copyFrom(File source, int start, RandomAccessFile out) {
    final reader = source.openSync();
    try {
      reader.setPositionSync(start);
      while (true) {
        final chunk = reader.readSync(1 << 20);
        if (chunk.isEmpty) break;
        out.writeFromSync(chunk);
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

    var vendor = 'Blimp';
    var comments = <String>[];
    final at = blocks.indexWhere((b) => b.type == 4);
    if (at >= 0) {
      final data = ByteData.sublistView(blocks[at].data);
      final bytes = blocks[at].data;
      var i = 0;
      int next32() {
        final value = data.getUint32(i, Endian.little);
        i += 4;
        return value;
      }

      final vendorLength = next32();
      vendor = utf8.decode(bytes.sublist(i, i + vendorLength), allowMalformed: true);
      i += vendorLength;
      final count = next32();
      for (var n = 0; n < count && i + 4 <= bytes.length; n++) {
        final length = next32();
        if (i + length > bytes.length) break;
        comments.add(utf8.decode(bytes.sublist(i, i + length), allowMalformed: true));
        i += length;
      }
    }

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
    final comment = (type: 4, data: block.takeBytes());
    if (at >= 0) {
      blocks[at] = comment;
    } else {
      blocks.add(comment);
    }
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
}
