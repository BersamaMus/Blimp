import 'package:flutter/services.dart';

import 'media_library.dart';

/// What a home screen widget asked for when it opened the app: to show the
/// player, or that and press one of its buttons, since nothing was loaded
/// for the button to control. The app icon's long-press shortcuts (see
/// res/xml/shortcuts.xml) ask for [play] (Resume), [shuffleAll] and
/// [favourites] the same way.
enum WidgetRequest { openPlayer, play, previous, next, shuffleAll, favourites }

/// Keeps the home screen widgets (NowPlayingWidgets.kt) showing what's
/// playing. Only sends when something they show changed.
class HomeWidgets {
  HomeWidgets._();

  static const _channel = MethodChannel('blimp/widgets');
  static (int?, bool)? _last;

  /// Shows [song] and whether it's playing. With no song loaded ([song]
  /// null) the widgets keep showing the last one, paused, and their buttons
  /// open the app to play it.
  static void update(Song? song, {required bool playing}) {
    final next = (song?.id, playing && song != null);
    if (next == _last) return;
    _last = next;
    _channel.invokeMethod('update', {
      'songId': song?.id,
      'title': song?.title,
      'artist': song?.artistName,
      'album': song?.album,
      'playing': next.$2,
    }).catchError((Object _) {
      // Not on Android: there are no widgets to update.
    });
  }

  /// Colours the widgets' play button in the theme's [accent], its icon in
  /// [onAccent].
  static void setColors(Color accent, Color onAccent) {
    _channel.invokeMethod('setColors', {
      'accent': accent.toARGB32(),
      'onAccent': onAccent.toARGB32(),
    }).catchError((Object _) {});
  }

  /// Shows nothing playing, for when there's no last song to go back to.
  static void clear() {
    _last = null;
    _channel.invokeMethod('clear').catchError((Object _) {});
  }

  /// Calls [onRequest] when a widget opens the app, and once now if one was
  /// tapped to start the app.
  static Future<void> onRequest(void Function(WidgetRequest request) onRequest) async {
    void handle(Object? name) {
      if (WidgetRequest.values.asNameMap()[name] case final request?) onRequest(request);
    }

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'request') handle(call.arguments);
    });
    try {
      handle(await _channel.invokeMethod<String>('takeRequest'));
    } on MissingPluginException {
      // Not on Android: there are no widgets.
    }
  }
}
