import 'package:blimp/services/media_library.dart';
import 'package:blimp/services/music_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Album _album(String title, int songs, {String? releaseType}) => Album(
      title: title,
      artist: 'A',
      songs: [for (var i = 0; i < songs; i++) Song(id: i, title: 'Song $i', uri: 'content://$i')],
      releaseType: releaseType,
    );

void main() {
  test('the release type tag decides first', () {
    expect(_album('AM', 3, releaseType: 'album').kind, 'Album');
    expect(_album('Big', 12, releaseType: 'single').kind, 'Single');
    expect(_album('Four', 4, releaseType: 'ep').kind, 'EP');
  });

  test('then a title ending that says so', () {
    expect(_album('Blinding Lights - Single', 6).kind, 'Single');
    expect(_album('Something (EP)', 1).kind, 'EP');
    expect(_album('Rare [Single]', 9).kind, 'Single');
    expect(_album('The Single', 9).kind, 'Album', reason: 'a word in the title, not a label');
    expect(_album('Deep', 9).kind, 'Album', reason: '"ep" inside a word');
  });

  test('then how many songs are here', () {
    expect(_album('One', 1).kind, 'Single');
    expect(_album('Three', 3).kind, 'EP');
    expect(_album('Many', 5).kind, 'Album');
  });

  test('an untagged compilation is a compilation, however few of its songs are here', () {
    final album = Album(
      title: 'Cars (Original Motion Picture Soundtrack)',
      artist: 'Various artists',
      songs: [Song(id: 1, title: 'Real Gone', uri: 'content://1')],
      isCompilation: true,
    );
    expect(album.kind, 'Compilation');
  });
}
