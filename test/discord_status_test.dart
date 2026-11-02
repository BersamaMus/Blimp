import 'dart:io';

import 'package:blimp/services/discord_status.dart';
import 'package:blimp/services/media_library.dart';
import 'package:flutter_test/flutter_test.dart';

Song song({String title = 'Song', String? artist = 'Artist', String? album = 'Album', Duration? duration}) => Song(
  id: 1,
  title: title,
  uri: 'file:///song.mp3',
  artist: artist,
  album: album,
  duration: duration,
);

final start = DateTime.utc(2026, 11, 3, 12);

void main() {
  test('shows the song as something being listened to, with the logo', () {
    final activity = discordActivity(song(), start: start);
    expect(activity['type'], 2);
    expect(activity['details'], 'Song');
    expect(activity['state'], 'Artist');
    expect(activity['assets'], {'large_image': 'blimp', 'large_text': 'Album'});
  });

  test('the progress bar runs from the start to the end of the song', () {
    final activity = discordActivity(song(), start: start, length: const Duration(minutes: 3));
    expect(activity['timestamps'], {
      'start': start.millisecondsSinceEpoch,
      'end': start.add(const Duration(minutes: 3)).millisecondsSinceEpoch,
    });
  });

  test("falls back on the song's own length until the player knows it", () {
    final activity = discordActivity(song(duration: const Duration(minutes: 2)), start: start);
    expect((activity['timestamps']! as Map)['end'], start.add(const Duration(minutes: 2)).millisecondsSinceEpoch);
  });

  test('a song of unknown length has no end time', () {
    final activity = discordActivity(song(), start: start);
    expect(activity['timestamps'], {'start': start.millisecondsSinceEpoch});
  });

  test('a faster song ends sooner', () {
    final activity = discordActivity(song(), start: start, length: const Duration(minutes: 3), speed: 2);
    expect((activity['timestamps']! as Map)['end'], start.add(const Duration(seconds: 90)).millisecondsSinceEpoch);
  });

  test('a song partway through started that long ago', () {
    final now = start.add(const Duration(minutes: 1));
    expect(discordStart(const Duration(seconds: 30), now: now), now.subtract(const Duration(seconds: 30)));
    expect(discordStart(const Duration(seconds: 30), now: now, speed: 2), now.subtract(const Duration(seconds: 15)));
  });

  test('a song with no album leaves the logo without a caption', () {
    expect(discordActivity(song(album: null), start: start)['assets'], {'large_image': 'blimp'});
    expect(discordActivity(song(album: '  '), start: start)['assets'], {'large_image': 'blimp'});
  });

  test('text stays within what Discord accepts', () {
    expect((discordActivity(song(title: 'x' * 300), start: start)['details']! as String).runes.length, 128);
    expect((discordActivity(song(title: 'A'), start: start)['details']! as String).length, greaterThanOrEqualTo(2));
    expect((discordActivity(song(title: ''), start: start)['details']! as String).length, greaterThanOrEqualTo(2));
  });

  test("cutting a long title doesn't split an emoji in two", () {
    final details = discordActivity(song(title: '😀' * 200), start: start)['details']! as String;
    expect(details, '${'😀' * 127}…');
  });

  test('the title links to a search for the song on YouTube Music', () {
    final link = Uri.parse(discordActivity(song(), start: start)['details_url']! as String);
    expect(link.host, 'music.youtube.com');
    expect(link.path, '/search');
    expect(link.queryParameters['q'], 'Artist Song');
  });

  test('characters that mean something in an address still search properly', () {
    final link = Uri.parse(discordSongLink(song(title: 'Rock & Roll?', artist: 'AC/DC'))!);
    expect(link.queryParameters['q'], 'AC/DC Rock & Roll?');
  });

  test('a song too long for a link goes without one', () {
    final activity = discordActivity(song(title: 'x' * 300), start: start);
    expect(activity.containsKey('details_url'), isFalse);
    expect(activity['details'], isNotNull);
  });

  test('a found cover replaces the logo, which moves to its corner', () {
    final activity = discordActivity(song(), start: start, cover: 'https://example.com/cover.jpg');
    expect(activity['assets'], {
      'large_image': 'https://example.com/cover.jpg',
      'large_text': 'Album',
      'small_image': 'blimp',
    });
  });

  group('finding covers', () {
    const answer =
        '{"results":[{"kind":"song","trackName":"Song","artistName":"Artist","collectionName":"Album",'
        '"artworkUrl100":"https://example.com/100x100bb.jpg"}]}';
    const otherAlbum =
        '{"results":[{"kind":"song","trackName":"Song","artistName":"Artist","collectionName":"Greatest Hits",'
        '"artworkUrl100":"https://example.com/100x100bb.jpg"}]}';

    Song track(int id, {String title = 'Song', String? album = 'Album'}) =>
        Song(id: id, title: title, uri: 'file:///$id.mp3', artist: 'Artist', album: album);

    test('takes the large size of the cover from the matching song', () {
      expect(discordCover(answer, song()), 'https://example.com/600x600bb.jpg');
    });

    test("won't take the cover of another album", () {
      expect(discordCover(otherAlbum, song()), isNull);
    });

    test('takes any match for a song with no album', () {
      expect(discordCover(otherAlbum, song(album: null)), 'https://example.com/600x600bb.jpg');
    });

    const brainz =
        '{"recordings":[{"title":"Song","artist-credit":[{"name":"Artist"}],"releases":[{"status":"Official",'
        '"title":"Album","release-group":{"id":"abc","primary-type":"Album"}}]}]}';

    /// Answers as each service is told to, by the web address's host.
    DiscordCovers services({
      (int, String) apple = (200, '{"results":[]}'),
      (int, String) musicBrainz = (200, '{"recordings":[]}'),
      (int, String) archive = (404, ''),
    }) => DiscordCovers(
      (url) async => switch (url.host) {
        'itunes.apple.com' => apple,
        'musicbrainz.org' => musicBrainz,
        _ => archive,
      },
      pause: Duration.zero,
      musicBrainzPause: Duration.zero,
    );

    const front = '{"images":[{"front":false},{"front":true}]}';
    const archiveCover = 'https://coverartarchive.org/release-group/abc/front-500';

    test('goes to MusicBrainz for what iTunes lacks', () async {
      final covers = services(musicBrainz: (200, brainz), archive: (200, front));
      await covers.find(track(1));
      expect(covers.cover(track(1)), archiveCover);
    });

    test('goes to MusicBrainz when iTunes fails', () async {
      final covers = services(apple: (403, ''), musicBrainz: (200, brainz), archive: (200, front));
      await covers.find(track(1));
      expect(covers.cover(track(1)), archiveCover);
    });

    test('an album with no cover in the archive is not found', () async {
      final covers = services(musicBrainz: (200, brainz));
      await covers.find(track(1));
      expect(covers.cover(track(1)), isNull);
      expect(covers.wants(track(1)), isFalse);
    });

    test('an archive with only back covers is no use', () async {
      final covers = services(musicBrainz: (200, brainz), archive: (200, '{"images":[{"front":false}]}'));
      await covers.find(track(1));
      expect(covers.cover(track(1)), isNull);
    });

    test('searches once for each album', () async {
      var searches = 0;
      final covers = DiscordCovers((_) async {
        searches++;
        return (200, answer);
      }, pause: Duration.zero, musicBrainzPause: Duration.zero);
      await covers.find(track(1));
      expect(covers.cover(track(2)), 'https://example.com/600x600bb.jpg');
      expect(covers.wants(track(2)), isFalse);
      expect(searches, 1);
    });

    test('songs not found are not searched again', () async {
      final covers = services();
      await covers.find(track(1));
      expect(covers.cover(track(1)), isNull);
      expect(covers.wants(track(1)), isFalse);
      // Another song of the album may still be found.
      expect(covers.wants(track(2)), isTrue);
    });

    test('a failed search is tried again, but not straight away', () async {
      var now = start;
      final covers = DiscordCovers(
        (_) async => (403, ''),
        pause: Duration.zero,
        musicBrainzPause: Duration.zero,
        clock: () => now,
      );
      await covers.find(track(1));
      expect(covers.wants(track(1)), isFalse);
      now = now.add(const Duration(minutes: 6));
      expect(covers.wants(track(1)), isTrue);
    });

    test('no connection counts as a failed search', () async {
      final covers = DiscordCovers(
        (_) async => throw const SocketException('offline'),
        pause: Duration.zero,
        musicBrainzPause: Duration.zero,
      );
      await covers.find(track(1));
      expect(covers.busy, isFalse);
      expect(covers.wants(track(1)), isFalse);
    });

    test('an answer of the wrong shape counts as a failed search', () async {
      final covers = DiscordCovers(
        (_) async => (200, '{"results":[{"kind":"song","trackName":"Song","artworkUrl100":7}],"images":7}'),
        pause: Duration.zero,
        musicBrainzPause: Duration.zero,
      );
      await covers.find(track(1));
      expect(covers.busy, isFalse);
      expect(covers.wants(track(1)), isFalse);
    });
  });
}
