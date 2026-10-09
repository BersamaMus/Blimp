import 'package:blimp/services/m3u.dart';
import 'package:blimp/services/media_library.dart';
import 'package:flutter_test/flutter_test.dart';

Song _song(int id, String title, String path, {String artist = 'Kendrick Lamar'}) => Song(
  id: id,
  title: title,
  uri: 'content://$id',
  path: path,
  artist: artist,
  duration: const Duration(minutes: 3, seconds: 20),
);

void main() {
  final library = [
    _song(1, 'Crown', '/storage/emulated/0/Music/Kendrick/Mr. Morale/Crown.mp3'),
    _song(2, 'Mirror', '/storage/emulated/0/Music/Kendrick/Mr. Morale/Mirror.mp3'),
    _song(3, 'Mirror', '/storage/emulated/0/Music/Other/Mirror.mp3', artist: 'Someone Else'),
    _song(4, 'Señorita', '/storage/emulated/0/Music/Shawn/Señorita.mp3', artist: 'Shawn Mendes'),
  ];

  test('round trips through its own export', () {
    final text = M3u.encode([library[1], library[0]]);
    expect(text, startsWith('#EXTM3U\n#EXTINF:200,Kendrick Lamar - Mirror\n'));
    final (:songs, :missing) = M3u.decode(text, library);
    expect(songs.map((s) => s.id), [2, 1]);
    expect(missing, 0);
  });

  test('finds songs from playlists made elsewhere', () {
    const text = '\uFEFF#EXTM3U\r\n'
        '#EXTINF:200,Kendrick Lamar - Crown\r\n'
        r'C:\Users\me\Music\Kendrick\Mr. Morale\Crown.mp3' '\r\n'
        // The right Mirror, by its folders, though two files share the name.
        '../Kendrick/Mr.%20Morale/Mirror.mp3\r\n'
        'file:///sdcard/Music/Shawn/Se%C3%B1orita.mp3\r\n'
        '#EXTINF:100,Shawn Mendes - Señorita\r\n'
        'D:/Elsewhere/renamed.mp3\r\n'
        'Nowhere/missing.mp3\r\n';
    final (:songs, :missing) = M3u.decode(text, library);
    expect(songs.map((s) => s.id), [1, 2, 4, 4]);
    expect(missing, 1);
  });

  test('a file name alone is trusted only when no other song has it', () {
    final generic = [
      _song(5, 'Intro', '/storage/emulated/0/Music/AlbumA/01 Intro.mp3', artist: 'X'),
      _song(6, 'Intro', '/storage/emulated/0/Music/AlbumB/01 Intro.mp3', artist: 'Y'),
      _song(7, 'Outro', '/storage/emulated/0/Music/AlbumB/02 Outro.mp3', artist: 'Y'),
    ];
    const text = '#EXTM3U\n'
        // Two songs have this name, and nothing else says which.
        'D:/Rips/01 Intro.mp3\n'
        // But the title given picks one.
        '#EXTINF:60,X - Intro\n'
        'D:/Rips/01 Intro.mp3\n'
        // Only one song has this name.
        'D:/Rips/02 Outro.mp3\n';
    final (:songs, :missing) = M3u.decode(text, generic);
    expect(songs.map((s) => s.id), [5, 7]);
    expect(missing, 1);
  });
}
