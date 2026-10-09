import 'package:flutter/material.dart';

import '../screens/app_shell.dart';
import '../services/desktop_window.dart';
import '../theme.dart';

/// Asks what closing the window should do: keep playing in the background,
/// or quit; and whether to remember that rather than ask again. Null if
/// dismissed.
Future<({CloseAction action, bool remember})?> askCloseAction() async {
  final context = rootNavigatorKey.currentState?.overlay?.context;
  // Too early to ask: closes as an app usually does.
  if (context == null) return (action: CloseAction.quit, remember: false);
  return showDialog(context: context, builder: (_) => const _CloseDialog());
}

class _CloseDialog extends StatefulWidget {
  const _CloseDialog();

  @override
  State<_CloseDialog> createState() => _CloseDialogState();
}

class _CloseDialogState extends State<_CloseDialog> {
  bool _remember = false;

  void _pick(CloseAction action) => Navigator.pop(context, (action: action, remember: _remember));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.sheet,
      icon: const Icon(Icons.headphones_rounded, color: AppColors.accent),
      title: const Text('Keep playing after closing?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Blimp can keep playing in the background, with its icon in the system tray by the clock. '
            'Click the icon to open Blimp again.',
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            value: _remember,
            onChanged: (value) => setState(() => _remember = value ?? false),
            title: const Text("Don't ask again"),
            subtitle: const Text('You can change this in Settings.'),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => _pick(CloseAction.quit), child: const Text('Quit')),
        FilledButton(onPressed: () => _pick(CloseAction.background), child: const Text('Keep playing')),
      ],
    );
  }
}
