import 'package:flutter/material.dart';

import '../screens/app_shell.dart';
import '../screens/collection_screen.dart';
import '../services/music_controller.dart';
import '../theme.dart';

enum _MenuAction { history, rescan }

/// The ⋮ button in the top bars, with app-wide actions.
class AppMenuButton extends StatelessWidget {
  const AppMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_MenuAction>(
      tooltip: 'More options',
      icon: const Icon(Icons.more_vert),
      position: PopupMenuPosition.under,
      onSelected: (action) => switch (action) {
        _MenuAction.history => openPage(CollectionScreen.history()),
        _MenuAction.rescan => rescanLibrary(context),
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: _MenuAction.history, child: _Item(Icons.history, 'History')),
        PopupMenuItem(value: _MenuAction.rescan, child: _Item(Icons.refresh, 'Rescan device for music')),
      ],
    );
  }
}

class _Item extends StatelessWidget {
  const _Item(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: AppColors.textSecondary),
        const SizedBox(width: 14),
        Text(label),
      ],
    );
  }
}

/// Scans the device for music again, saying so while it runs and then what
/// changed.
Future<void> rescanLibrary(BuildContext context) async {
  final music = MusicScope.read(context);
  final messenger = ScaffoldMessenger.of(context);
  void say(String message, {Duration duration = const Duration(seconds: 4)}) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), duration: duration));

  say('Scanning for music…', duration: const Duration(minutes: 1));
  final result = await music.load();
  if (music.status == LibraryStatus.permissionDenied) {
    say('Blimp needs access to your music to scan for it');
  } else if (!result.ok) {
    say("Couldn't read your music. Try again in a moment.");
  } else if (result.added == result.total && result.total > 0) {
    // The library was empty before, so everything is new.
    say('Found ${_songs(result.total)}');
  } else if (result.added == 0 && result.removed == 0) {
    say('Library up to date • ${_songs(result.total)}');
  } else {
    say([
      if (result.added > 0) '${_songs(result.added)} added',
      if (result.removed > 0) '${_songs(result.removed)} removed',
    ].join(', '));
  }
}

String _songs(int n) => n == 1 ? '1 song' : '$n songs';
