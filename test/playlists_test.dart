import 'package:blimp/services/playlists.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('playlists survive saving and loading', () {
    final saved = encodePlaylists([
      Playlist(id: '1', name: 'Gym', songIds: [3, 1, 2], created: DateTime(2026, 10, 8)),
    ]);
    final [playlist] = decodePlaylists(saved);
    expect(playlist.name, 'Gym');
    expect(playlist.songIds, [3, 1, 2]);
    expect(playlist.created, DateTime(2026, 10, 8));
  });

  test('unreadable saved playlists load as none', () {
    expect(decodePlaylists(null), isEmpty);
    expect(decodePlaylists('not json'), isEmpty);
  });
}
