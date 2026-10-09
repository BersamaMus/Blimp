import 'dart:async';

import 'package:flutter/services.dart';

import 'desktop_library.dart';
import 'media_library.dart';
import 'music_controller.dart';

/// Windows' media controls: the keyboard's media keys, and the flyout by the
/// volume indicator, which shows the song playing and plays, pauses and
/// skips it. What the phone app gets from its playback notification. The
/// Windows half is windows/runner/media_controls.cpp.
class DesktopMediaControls {
  DesktopMediaControls(this._music) {
    _channel.setMethodCallHandler(_onCall);
    final player = _music.player;
    _subs = [
      player.sequenceStateStream.listen((_) => _update()),
      player.playingStream.listen((_) => _update()),
      player.positionDiscontinuityStream.listen((_) => _sendTimeline()),
      player.durationStream.listen((_) => _sendTimeline()),
    ];
    // Windows doesn't move the flyout's position along by itself.
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (player.playing) _sendTimeline();
    });
  }

  static const _channel = MethodChannel('blimp/media_controls');

  final MusicController _music;
  late final List<StreamSubscription<Object?>> _subs;
  late final Timer _timer;

  /// The song [_art] is the cover of, and where that's saved.
  int? _artFor;
  String? _art;

  Future<void> _update() async {
    final song = _music.currentSong;
    if (song == null) {
      _artFor = null;
      return _invoke('clear');
    }
    if (song.id != _artFor) {
      _artFor = song.id;
      _art = null;
      _art = await DesktopLibrary.artworkPath(song.id, MediaLibrary.thumbnailSize);
      // Moved on while the cover loaded: that song's update comes instead.
      if (_music.currentSong != song) return;
    }
    final player = _music.player;
    await _invoke('update', {
      'title': song.title,
      'artist': song.artistName,
      'album': song.album ?? '',
      'art': _art,
      'playing': player.playing,
      'canPrevious': true,
      'canNext': player.hasNext,
    });
    await _sendTimeline();
  }

  Future<void> _sendTimeline() async {
    final player = _music.player;
    if (_music.currentSong == null) return;
    await _invoke('timeline', {
      'positionMs': player.position.inMilliseconds,
      'durationMs': (player.duration ?? Duration.zero).inMilliseconds,
    });
  }

  Future<void> _onCall(MethodCall call) async {
    final player = _music.player;
    switch ((call.method, call.arguments)) {
      case ('button', 'play'):
        // Not awaited: play() only finishes when playback stops.
        unawaited(player.play());
      case ('button', 'pause' || 'stop'):
        await player.pause();
      case ('button', 'next'):
        if (player.hasNext) await player.seekToNext();
      case ('button', 'previous'):
        await _music.skipToPrevious();
      case ('seek', final int ms):
        await player.seek(Duration(milliseconds: ms));
    }
  }

  static Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod(method, arguments);
    } on MissingPluginException {
      // Not on Windows: there are no media controls to update.
    } on PlatformException {
      // Windows turned the update down; the next one may fare better.
    }
  }

  void dispose() {
    _timer.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    _channel.setMethodCallHandler(null);
  }
}
