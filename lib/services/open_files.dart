import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'music_controller.dart';

/// Songs opened with Blimp: from Explorer or a phone's file manager, or
/// dragged onto the window on desktop. The native halves keep them until
/// they're taken here (windows/runner/open_files.cpp, and AppChannels.kt and
/// MainActivity.kt on Android), so files opened while the app starts wait.
abstract final class OpenFiles {
  static const _channel = MethodChannel('blimp/open');

  /// Whether files are being dragged over the window, to show where to drop.
  static final dragging = ValueNotifier(false);

  static late MusicController _music;

  /// Files taken but not played yet: Explorer opens several files one
  /// launch at a time, so a moment's wait plays them all together.
  static final _waiting = <({String? path, String? uri, int? id, String? name})>[];
  static Timer? _timer;

  static Future<void> init(MusicController music) async {
    _music = music;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'opened':
          await _take();
        case 'dragging':
          dragging.value = call.arguments == true;
      }
    });
    await _take();
  }

  static Future<void> _take() async {
    final List<Object?>? files;
    try {
      files = await _channel.invokeListMethod<Object?>('takeOpened');
    } on MissingPluginException {
      return;
    }
    for (final file in files ?? const []) {
      if (file is! Map) continue;
      _waiting.add((
        path: file['path'] as String?,
        uri: file['uri'] as String?,
        id: (file['id'] as num?)?.toInt(),
        name: file['name'] as String?,
      ));
    }
    if (_waiting.isEmpty) return;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 400), () {
      final files = [..._waiting];
      _waiting.clear();
      _music.playOpened(files);
    });
  }
}
