import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where a newer version can be downloaded: the latest release's page,
/// which has the Windows installer, the Android app and what's changed.
final releasesPage = Uri.https('github.com', '/BersamaMus/Blimp/releases/latest');

/// Whether Blimp looks for a new version when it opens. On unless the user
/// turns it off. Left out of backups, like the other settings that go online.
const checkForUpdatesKey = 'check_for_updates';

/// Asks GitHub which version of Blimp is the newest, once each time the app
/// opens. Only the question is sent: nothing about the user or their music.
///
/// Copies from the Google Play Store or the Microsoft Store are left alone,
/// as the store updates them, and the download offered wouldn't fit them.
abstract final class UpdateCheck {
  /// The newer version's number, like "1.8.0", or null when this one is the
  /// newest, the check is off, or GitHub couldn't be reached.
  static Future<String?> newerVersion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool(checkForUpdatesKey) ?? true)) return null;
      final info = await PackageInfo.fromPlatform();
      if (_fromStore(info)) return null;
      final latest = await _latestVersion();
      return latest != null && isNewerVersion(latest, info.version) ? latest : null;
    } on Object {
      // Offline, or an answer that isn't GitHub's (a Wi-Fi sign-in page):
      // try again next time.
      return null;
    }
  }

  static bool _fromStore(PackageInfo info) {
    // The Microsoft Store installs apps under Program Files\WindowsApps.
    if (Platform.isWindows) return Platform.resolvedExecutable.contains(r'\WindowsApps\');
    return info.installerStore == 'com.android.vending';
  }

  static Future<String?> _latestVersion() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'Blimp (https://github.com/BersamaMus/Blimp)';
    try {
      final request = await client.getUrl(Uri.https('api.github.com', '/repos/BersamaMus/Blimp/releases/latest'));
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
      final tag = (jsonDecode(body) as Map<String, dynamic>)['tag_name'];
      return tag is String ? tag.replaceFirst(RegExp('^v'), '') : null;
    } finally {
      client.close(force: true);
    }
  }
}

/// Whether version [latest] ("1.8.0") comes after [current] ("1.7.1"),
/// comparing each number in turn, so 1.10.0 is newer than 1.9.0. Anything
/// after a "-" or "+" is ignored, and a missing number counts as 0.
bool isNewerVersion(String latest, String current) {
  List<int> parts(String version) => [
    for (final part in version.split(RegExp('[-+]')).first.trim().split('.')) int.tryParse(part) ?? 0,
  ];
  final a = parts(latest);
  final b = parts(current);
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}
