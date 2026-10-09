import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import 'desktop_library.dart';

/// Android's own Save and Open pickers, for backups and playlists. They let
/// the user pick any folder (or Google Drive) without a storage permission.
/// On desktop, the system's Save and Open dialogs.
abstract final class DeviceFiles {
  static const _channel = MethodChannel('blimp/files');

  /// Asks where to save [bytes] as [name]; false if the user backed out.
  static Future<bool> save(String name, String mime, Uint8List bytes) async {
    if (isDesktop) {
      final location = await getSaveLocation(suggestedName: name);
      if (location == null) return false;
      await File(location.path).writeAsBytes(bytes);
      return true;
    }
    return await _channel.invokeMethod<bool>('save', {'name': name, 'mime': mime, 'bytes': bytes}) ?? false;
  }

  /// Asks for a file of one of [mimes]; null if the user backed out.
  static Future<({String? name, Uint8List bytes})?> open(List<String> mimes) async {
    if (isDesktop) {
      // Windows' dialog filters by extension, not type, so any file can be
      // picked; reading it tells whether it's the right kind.
      final file = await openFile();
      if (file == null) return null;
      return (name: file.name, bytes: await file.readAsBytes());
    }
    final picked = await _channel.invokeMapMethod<String, Object?>('open', {'mimes': mimes});
    if (picked == null) return null;
    return (name: picked['name'] as String?, bytes: picked['bytes'] as Uint8List);
  }

  /// Starts the app afresh, so everything reloads (after a restore).
  static Future<void> restartApp() async {
    if (isDesktop) {
      // A new window from the same program, then this one closes.
      await Process.start(Platform.resolvedExecutable, const [], mode: ProcessStartMode.detached);
      exit(0);
    }
    await _channel.invokeMethod('restart');
  }
}
