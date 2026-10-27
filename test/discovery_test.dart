import 'dart:typed_data';

import 'package:blimp/services/artist_links.dart';
import 'package:blimp/services/catalog.dart';
import 'package:blimp/services/decades.dart';
import 'package:blimp/services/listening_log.dart';
import 'package:blimp/services/media_library.dart';
import 'package:blimp/services/song_dna.dart';
import 'package:blimp/services/visualizer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

var _nextId = 1;

Song _song(String artist, {String? album, int? year, bool compilation = false, String? title}) {
  final id = _nextId++;
  return Song(
    id: id,
    title: title ?? 'Song $id',
    uri: 'content://$id',
    artist: artist,
    album: album,
    year: year,
    compilation: compilation,
  );
}

void main() {
  group('Decades', () {
    test('groups songs by decade, leaving out unlikely years and small decades', () {
      final songs = [
        for (var i = 0; i < 5; i++) _song('A', year: 1983 + i),
        for (var i = 0; i < 6; i++) _song('B', year: 2010 + i),
        for (var i = 0; i < 2; i++) _song('C', year: 1995),
        for (var i = 0; i < 5; i++) _song('D', year: 2999),
      ];
      final decades = decadesOf(songs, now: DateTime(2026, 10, 28));
      expect(decades.map((d) => d.label), ['1980s', '2010s']);
      expect(decades.first.shortLabel, "'80s");
      expect(Decade(2000, const []).shortLabel, '2000s');
    });
  });

  group('Six degrees', () {
    test('finds the shortest chain of shared songs', () {
      final songs = [
        _song('Kendrick Lamar feat. SZA'),
        _song('SZA/Travis Scott'),
        _song('Travis Scott feat. Drake'),
        _song('Kendrick Lamar/Drake/Travis Scott/SZA', album: 'Big posse cut'),
        _song('Loner'),
      ];
      final graph = ArtistGraph(songs, buildAlbums(songs));
      final path = graph.path('Kendrick Lamar', 'Drake')!;
      expect(path.map((s) => s.artist), ['Drake']);

      final songs2 = songs.take(3).toList();
      final graph2 = ArtistGraph(songs2, buildAlbums(songs2));
      final chain = graph2.path('Kendrick Lamar', 'Drake')!;
      expect(chain.map((s) => s.artist), ['SZA', 'Travis Scott', 'Drake']);
      expect(chain.first.via, songs2.first);
      expect(chain.every((s) => s.together), isTrue);
      expect(graph2.path('Kendrick Lamar', 'Loner'), isNull);
      expect(graph2.distancesFrom('Kendrick Lamar')['Drake'], 3);
    });

    test('compilations link artists only when no shared song does', () {
      final songs = [
        _song('Daft Punk', album: 'Summer hits', compilation: true),
        _song('Robyn', album: 'Summer hits', compilation: true),
        _song('Robyn feat. Royksopp'),
      ];
      final graph = ArtistGraph(songs, buildAlbums(songs));
      final path = graph.path('Daft Punk', 'Royksopp')!;
      expect(path.map((s) => (s.artist, s.together)), [('Robyn', false), ('Royksopp', true)]);
      expect(graph.neighbours('Robyn').map((l) => l.artist), ['Royksopp', 'Daft Punk']);
    });

    test('unknown and various artists link no one', () {
      final songs = [
        Song(id: 900, title: 'x', uri: 'content://900', albumArtist: 'Various Artists', artist: 'Moby'),
        Song(id: 901, title: 'y', uri: 'content://901', albumArtist: 'Various Artists', artist: 'Bjork'),
      ];
      final graph = ArtistGraph(songs, const []);
      expect(graph.hasLinks('Moby'), isFalse);
    });
  });

  group('Song DNA', () {
    test('counts listens, plays, skips and rank', () {
      final log = ListeningLog.inMemory()
        ..append(ListenEvent(songId: 1, endedAt: DateTime(2026, 9, 1, 21), listenedMs: 20000))
        ..append(ListenEvent(songId: 1, endedAt: DateTime(2026, 9, 1, 21, 1), listenedMs: 20000, continued: true))
        ..append(ListenEvent(songId: 1, endedAt: DateTime(2026, 10, 2, 22), listenedMs: 5000))
        ..append(ListenEvent(songId: 2, endedAt: DateTime(2026, 10, 3), listenedMs: 60000))
        ..append(ListenEvent(songId: 2, endedAt: DateTime(2026, 10, 4), listenedMs: 60000));
      final dna = songDna(Song(id: 1, title: 't', uri: 'u'), log.events, DateTime(2026, 10, 28));
      expect(dna.listens, 2);
      expect(dna.plays, 1);
      expect(dna.skipRate, 0.5);
      expect(dna.listened, const Duration(seconds: 45));
      expect(dna.rank, 2);
      expect(dna.firstPlayed, DateTime(2026, 9, 1, 21, 1));
      expect(dna.peakHour, 21);
      expect(dna.playsByMonth.sublist(10), [1, 0]);
    });
  });

  group('Artwork colours', () {
    Uint8List pixels(List<Color> colors) => Uint8List.fromList([
          for (final c in colors) ...[
            (c.r * 255).round(),
            (c.g * 255).round(),
            (c.b * 255).round(),
            255,
          ],
        ]);

    test('picks two different hues, brightened', () {
      final colors = artworkColors(pixels([
        ...List.filled(60, const Color(0xFF8B1010)),
        ...List.filled(30, const Color(0xFF103080)),
        ...List.filled(10, Colors.black),
      ]))!;
      final (low, high) = colors;
      expect(HSVColor.fromColor(low).hue, closeTo(0, 15));
      expect(HSVColor.fromColor(high).hue, closeTo(223, 15));
      expect(HSVColor.fromColor(low).value, greaterThanOrEqualTo(0.89));
    });

    test('a black and white cover has none', () {
      expect(artworkColors(pixels([...List.filled(50, Colors.black), ...List.filled(50, Colors.white)])), isNull);
    });
  });
}
