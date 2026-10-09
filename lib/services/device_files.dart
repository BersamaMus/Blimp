import 'package:flutter/services.dart';

/// Android's own Save and Open pickers, for backups and playlists. They let
/// the user pick any folder (or Google Drive) without a storage permission.
abstract final class DeviceFiles {
  static const _channel = MethodChannel('blimp/files');

  /// Asks where to save [bytes] as [name]; false if the user backed out.
  static Future<bool> save(String name, String mime, Uint8List bytes) async =>
      await _channel.invokeMethod<bool>('save', {'name': name, 'mime': mime, 'bytes': bytes}) ?? false;

  /// Asks for a file of one of [mimes]; null if the user backed out.
  static Future<({String? name, Uint8List bytes})?> open(List<String> mimes) async {
    final picked = await _channel.invokeMapMethod<String, Object?>('open', {'mimes': mimes});
    if (picked == null) return null;
    return (name: picked['name'] as String?, bytes: picked['bytes'] as Uint8List);
  }

  /// Starts the app afresh, so everything reloads (after a restore).
  static Future<void> restartApp() => _channel.invokeMethod('restart');
}
