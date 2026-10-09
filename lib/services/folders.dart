import 'media_library.dart';

/// A folder of music on the device, holding songs and more folders.
class Folder {
  Folder._(this.path, this.name);

  /// Full path, e.g. /storage/emulated/0/Music/Rock.
  final String path;

  /// What it's called in the app. A folder whose only content is one more
  /// folder is merged with it, so this can be a few names, e.g. "Rock/Live".
  String name;

  /// Subfolders A to Z.
  final List<Folder> folders = [];

  /// The songs directly in it, by file name.
  final List<Song> songs = [];

  /// Every song in it and its subfolders, in the order they're listed.
  late final List<Song> allSongs = [...songs, for (final f in folders) ...f.allSongs];
}

/// The folders holding [songs], from the deepest folder they all share
/// (often Music), or null if none of them say where their file is.
({Folder root, Map<String, Folder> byPath})? buildFolderTree(List<Song> songs) {
  final located = [
    for (final s in songs)
      if (s.folder case final folder?) (song: s, folder: folder),
  ];
  if (located.isEmpty) return null;

  // The deepest folder they all share.
  var common = located.first.folder.split('/');
  for (final l in located) {
    final parts = l.folder.split('/');
    var i = 0;
    while (i < common.length && i < parts.length && common[i] == parts[i]) {
      i++;
    }
    common = common.sublist(0, i);
  }
  final rootPath = common.join('/');
  final root = Folder._(rootPath, _friendlyName(rootPath) ?? _lastPart(rootPath));
  final byPath = {rootPath: root};

  Folder folderAt(String path) => byPath[path] ??= () {
        final folder = Folder._(path, _friendlyName(path) ?? _lastPart(path));
        folderAt(path.substring(0, path.lastIndexOf('/'))).folders.add(folder);
        return folder;
      }();

  for (final l in located) {
    folderAt(l.folder).songs.add(l.song);
  }

  void tidy(Folder folder) {
    folder.folders.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    folder.songs.sort((a, b) => a.fileName!.toLowerCase().compareTo(b.fileName!.toLowerCase()));
    for (var i = 0; i < folder.folders.length; i++) {
      // Skip through folders with nothing in them but one more folder.
      var child = folder.folders[i];
      while (child.songs.isEmpty && child.folders.length == 1) {
        final only = child.folders.single;
        only.name = _friendlyName(only.path) ?? '${child.name}/${only.name}';
        child = only;
      }
      folder.folders[i] = child;
      tidy(child);
    }
  }

  tidy(root);
  return (root: root, byPath: byPath);
}

/// The folders from [root] down to [folder], as they're shown (skipping
/// any merged into another).
List<Folder> folderChain(Folder root, Folder folder) {
  final chain = [root];
  while (chain.last != folder) {
    final next = chain.last.folders.where((f) => f == folder || folder.path.startsWith('${f.path}/'));
    if (next.isEmpty) break;
    chain.add(next.first);
  }
  return chain;
}

String _lastPart(String path) {
  final name = path.substring(path.lastIndexOf('/') + 1);
  return name.isEmpty ? 'Storage' : name;
}

/// Names for the storage roots, which are cryptic as paths.
String? _friendlyName(String path) => switch (path) {
      '/storage/emulated/0' => 'Internal storage',
      '/storage' || '' => 'Storage',
      _ when RegExp(r'^/storage/[0-9A-F]{4}-[0-9A-F]{4}$').hasMatch(path) => 'SD card',
      _ => null,
    };
