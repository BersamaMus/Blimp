import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/app_shell.dart';
import '../screens/search_screen.dart';
import '../services/music_controller.dart';

/// The desktop app's keyboard shortcuts, anywhere in it: Space plays and
/// pauses, Ctrl+→ and Ctrl+← skip, Ctrl+F searches. While typing, Space and
/// the arrows are left to the text field.
class DesktopShortcuts extends StatelessWidget {
  const DesktopShortcuts({
    super.key,
    required this.onPlayPause,
    required this.onNext,
    required this.onPrevious,
    required this.onSearch,
    required this.child,
  });

  /// The shortcuts acting on [music]'s player, searching with Search.
  factory DesktopShortcuts.forMusic(MusicController music, {Key? key, required Widget child}) {
    final player = music.player;
    return DesktopShortcuts(
      key: key,
      onPlayPause: () {
        if (music.currentSong == null) return;
        player.playing ? player.pause() : player.play();
      },
      onNext: () {
        if (player.hasNext) player.seekToNext();
      },
      onPrevious: () {
        if (music.currentSong != null) music.skipToPrevious();
      },
      onSearch: () => openPage(const SearchScreen()),
      child: child,
    );
  }

  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback onSearch;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: {
        const SingleActivator(LogicalKeyboardKey.space): _Shortcut(onPlayPause),
        const SingleActivator(LogicalKeyboardKey.arrowRight, control: true): _Shortcut(onNext),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true): _Shortcut(onPrevious),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _Shortcut(onSearch, whileTyping: true),
      },
      child: Actions(
        actions: {_Shortcut: _ShortcutAction()},
        // Something has to hold focus for the keys to arrive at all.
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

class _Shortcut extends Intent {
  const _Shortcut(this.run, {this.whileTyping = false});

  final VoidCallback run;

  /// Whether it works with a text field focused too.
  final bool whileTyping;
}

class _ShortcutAction extends Action<_Shortcut> {
  /// Off while a text field has focus, so the key reaches it instead: Space
  /// types a space there, and Ctrl+arrows move by word.
  @override
  bool isEnabled(_Shortcut intent) => intent.whileTyping || !_typing;

  static bool get _typing =>
      FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>() != null;

  @override
  void invoke(_Shortcut intent) => intent.run();
}
