import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Time spent listening to one song, ending at [endedAt].
///
/// A long listen is saved in pieces (every 30 seconds and when the app goes to
/// the background) so nothing is lost if the app is closed; pieces after the
/// first have [continued] set.
class ListenEvent {
  ListenEvent({required this.songId, required this.endedAt, required this.listenedMs, this.continued = false});

  final int songId;
  final DateTime endedAt;
  final int listenedMs;
  final bool continued;

  /// Whether this piece completes a "play": the moment a listen reaches
  /// [playThreshold]. Worked out from the pieces before it, not saved.
  bool countsAsPlay = false;

  /// Like most music services, a song counts as played after 30 seconds.
  static const playThreshold = Duration(seconds: 30);

  String encode() => '${endedAt.millisecondsSinceEpoch},$songId,$listenedMs,${continued ? 1 : 0}';

  static ListenEvent? decode(String line) {
    final parts = line.split(',');
    if (parts.length != 4) return null;
    final (time, id, ms) = (int.tryParse(parts[0]), int.tryParse(parts[1]), int.tryParse(parts[2]));
    if (time == null || id == null || ms == null) return null;
    return ListenEvent(
      songId: id,
      endedAt: DateTime.fromMillisecondsSinceEpoch(time),
      listenedMs: ms,
      continued: parts[3] == '1',
    );
  }
}

/// Every listen, oldest first, kept in an append-only file in the app's
/// private storage. One short line per piece, merged into one per listen
/// from time to time, keeps years of history small.
class ListeningLog {
  ListeningLog._(this._file);

  /// For tests: a log that only lives in memory.
  ListeningLog.inMemory() : _file = null;

  final File? _file;
  final List<ListenEvent> events = [];

  // Listen progress since the last piece that started a new listen.
  int _currentListenMs = 0;
  bool _currentListenCounted = false;

  // Writes run one after another so lines never interleave.
  Future<void> _writes = Future.value();

  /// Runs [write] after the writes before it. One that fails (storage full,
  /// say) doesn't stop those after it.
  Future<void> _write(Future<void> Function() write) {
    final done = _writes.then((_) => write());
    _writes = done.catchError((Object _) {});
    return done;
  }

  static Future<ListeningLog> open() async {
    final dir = await getApplicationSupportDirectory();
    final log = ListeningLog._(File('${dir.path}/listening_log.csv'));
    final file = log._file!;
    if (!await file.exists()) return log;

    final saved = [for (final line in await file.readAsLines()) ?ListenEvent.decode(line)];
    final events = compact(saved);
    for (final event in events) {
      log._add(event);
    }
    // Rewritten without the pieces once there are enough to be worth it, so
    // the log stays quick to load. Written beside it first, then swapped in,
    // so a crash midway can't lose it.
    if (saved.length - events.length >= _compactAfter) {
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(events.map((e) => '${e.encode()}\n').join(), flush: true);
      await temp.rename(file.path);
    }
    return log;
  }

  /// How many pieces merging must save before the file is rewritten.
  static const _compactAfter = 500;

  /// [events] with each listen's pieces merged into one, ending when the
  /// listen did. A listen never carries on into the next launch, so every
  /// saved one is complete.
  static List<ListenEvent> compact(List<ListenEvent> events) {
    final merged = <ListenEvent>[];
    for (final event in events) {
      final last = merged.lastOrNull;
      if (event.continued && last != null && last.songId == event.songId) {
        merged.last = ListenEvent(
          songId: last.songId,
          endedAt: event.endedAt,
          listenedMs: last.listenedMs + event.listenedMs,
        );
      } else {
        merged.add(ListenEvent(songId: event.songId, endedAt: event.endedAt, listenedMs: event.listenedMs));
      }
    }
    return merged;
  }

  void _add(ListenEvent event) {
    if (!event.continued) {
      _currentListenMs = 0;
      _currentListenCounted = false;
    }
    _currentListenMs += event.listenedMs;
    if (!_currentListenCounted && _currentListenMs >= ListenEvent.playThreshold.inMilliseconds) {
      event.countsAsPlay = true;
      _currentListenCounted = true;
    }
    events.add(event);
  }

  /// Whether a new piece would complete a play, for showing a listen that's
  /// still in progress.
  bool wouldCountAsPlay(ListenEvent event) {
    final total = (event.continued ? _currentListenMs : 0) + event.listenedMs;
    final counted = event.continued && _currentListenCounted;
    return !counted && total >= ListenEvent.playThreshold.inMilliseconds;
  }

  void append(ListenEvent event) {
    _add(event);
    final file = _file;
    if (file == null) return;
    unawaited(_write(() => file.writeAsString('${event.encode()}\n', mode: FileMode.append)));
  }

  Future<void> clear() async {
    events.clear();
    _currentListenMs = 0;
    _currentListenCounted = false;
    final file = _file;
    if (file == null) return;
    await _write(() async {
      if (await file.exists()) await file.delete();
    });
  }

  /// Replaces every listen with [listens], as when restoring a backup.
  Future<void> replaceWith(List<ListenEvent> listens) async {
    events.clear();
    _currentListenMs = 0;
    _currentListenCounted = false;
    for (final event in listens) {
      _add(event);
    }
    final file = _file;
    if (file == null) return;
    await _write(() => file.writeAsString(listens.map((e) => '${e.encode()}\n').join(), flush: true));
  }
}
