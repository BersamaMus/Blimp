import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'music_controller.dart';

/// What closing the window does on desktop.
enum CloseAction {
  /// Asks each time, until an answer is remembered.
  ask,

  /// Keeps playing, with Blimp in the system tray by the clock.
  background,

  /// Quits, as closing an app usually does.
  quit,
}

/// Closing the window to the system tray, to keep playing in the background,
/// and the tray menu's buttons. The Windows half is
/// windows/runner/background.cpp.
class DesktopWindow {
  DesktopWindow._();

  static const _channel = MethodChannel('blimp/window');
  static const _closeActionKey = 'close_action';

  /// What closing the window does; changed in Settings.
  static final closeAction = ValueNotifier(CloseAction.ask);

  static late MusicController _music;
  static late Future<({CloseAction action, bool remember})?> Function() _ask;
  static bool _asking = false;

  /// Whether Blimp has gone to the tray yet this run; the first time, it
  /// says where it went.
  static bool _hidden = false;

  /// Starts listening to the window. [ask] asks what closing should do while
  /// that's [CloseAction.ask], and whether to remember it; null if the
  /// question was dismissed.
  static Future<void> init(
    MusicController music, {
    required Future<({CloseAction action, bool remember})?> Function() ask,
  }) async {
    _music = music;
    _ask = ask;
    _channel.setMethodCallHandler(_onCall);
    final saved = (await SharedPreferences.getInstance()).getString(_closeActionKey);
    closeAction.value = CloseAction.values.asNameMap()[saved] ?? CloseAction.ask;
    await _send();
  }

  static Future<void> setCloseAction(CloseAction action) async {
    closeAction.value = action;
    await (await SharedPreferences.getInstance()).setString(_closeActionKey, action.name);
    await _send();
  }

  static Future<void> _send() async {
    try {
      await _channel.invokeMethod('setCloseAction', closeAction.value.name);
    } on MissingPluginException {
      // Only Windows has a tray to close to; elsewhere closing quits.
    }
  }

  static Future<void> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'closeRequested':
        await _askAndClose();
      case 'tray':
        final player = _music.player;
        switch (call.arguments) {
          case 'playPause':
            player.playing ? await player.pause() : await player.play();
          case 'next':
            if (player.hasNext) await player.seekToNext();
          case 'previous':
            await _music.skipToPrevious();
        }
    }
  }

  /// Quits Blimp, whatever closing the window is set to do.
  static Future<void> quit() async {
    try {
      await _channel.invokeMethod('quit');
    } on MissingPluginException {
      // No tray to stay in elsewhere: closing the window quits.
      await SystemNavigator.pop();
    }
  }

  /// The window's X, while closing is set to ask: asks what to do, then does
  /// it, remembering the answer if asked to. Dismissed, the window stays
  /// open.
  static Future<void> _askAndClose() async {
    if (_asking) return;
    _asking = true;
    final answer = await _ask();
    _asking = false;
    if (answer == null) return;
    if (answer.remember) await setCloseAction(answer.action);
    if (answer.action == CloseAction.quit) {
      await quit();
    } else {
      // The first time, the tray shows a note saying where Blimp went.
      await _channel.invokeMethod('hide', !_hidden);
      _hidden = true;
    }
  }
}
