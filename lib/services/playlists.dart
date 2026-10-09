import 'dart:convert';

/// A playlist the user made: a name and songs in the order they chose.
///
/// Songs are kept by id, so a song that's removed from the device (or hidden
/// from the library) drops out of the list shown, and comes back if it returns.
class Playlist {
  Playlist({required this.id, required this.name, required this.songIds, required this.created});

  factory Playlist.fromJson(Map<String, Object?> json) => Playlist(
        id: json['id'] as String,
        name: json['name'] as String,
        songIds: [for (final id in json['songs'] as List) id as int],
        created: DateTime.fromMillisecondsSinceEpoch(json['created'] as int),
      );

  final String id;
  String name;
  final List<int> songIds;
  final DateTime created;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'songs': songIds,
        'created': created.millisecondsSinceEpoch,
      };
}

String encodePlaylists(List<Playlist> playlists) => jsonEncode([for (final p in playlists) p.toJson()]);

/// The saved playlists, or none if [saved] is missing or unreadable.
List<Playlist> decodePlaylists(String? saved) {
  if (saved == null) return [];
  try {
    return [for (final p in jsonDecode(saved) as List) Playlist.fromJson(p as Map<String, Object?>)];
  } on Object {
    return [];
  }
}
