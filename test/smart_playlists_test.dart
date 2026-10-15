import 'package:blimp/services/media_library.dart';
import 'package:blimp/services/smart_playlists.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final songs = [
    for (var i = 1; i <= 6; i++) Song(id: i, title: 'Song $i', uri: '$i', genre: i.isEven ? 'Jazz' : 'Rock'),
  ];
  // Songs 1 and 2 are rated; the rest aren't.
  final ratings = {1: 1, 2: 5};
  final facts = SmartFacts(
    plays: (s) => s.id,
    rating: (s) => ratings[s.id] ?? 0,
    lastPlayed: (_) => null,
    isFavourite: (s) => s.id == 3,
    historyRank: (s) => s.id,
  );
  List<int> ids(SmartPlaylist p) => [for (final s in pickSmartPlaylistSongs(p, songs, facts)) s.id];
  SmartPlaylist playlist(List<SmartRule> rules, {bool all = true, SmartSort sort = SmartSort.title}) =>
      SmartPlaylist(id: 'p', name: 'p', rules: rules, matchAll: all, sort: sort);

  test('rating rules leave unrated songs out', () {
    expect(ids(playlist([const SmartRule(field: SmartField.rating, op: SmartOp.atMost, value: '2')])), [1]);
    expect(ids(playlist([const SmartRule(field: SmartField.rating, op: SmartOp.atLeast, value: '4')])), [2]);
  });

  test('all rules or any rule', () {
    const jazz = SmartRule(field: SmartField.genre, op: SmartOp.isEqual, value: 'jazz');
    const played = SmartRule(field: SmartField.plays, op: SmartOp.atLeast, value: '5');
    expect(ids(playlist([jazz, played])), [6]);
    expect(ids(playlist([jazz, played], all: false)), [2, 4, 5, 6]);
  });

  test('no complete rule picks nothing, not everything', () {
    expect(ids(playlist([SmartRule.on(SmartField.plays)])), isEmpty);
  });

  test('random order is the same all day, whatever run it is', () {
    final p = playlist([const SmartRule(field: SmartField.title, op: SmartOp.contains, value: 'song')], sort: SmartSort.random);
    final day = DateTime(2026, 10, 16, 9);
    final order = pickSmartPlaylistSongs(p, songs, facts, now: day).map((s) => s.id).toList();
    expect(pickSmartPlaylistSongs(p, songs, facts, now: day.add(const Duration(hours: 10))).map((s) => s.id), order);
    // Fixed by the playlist and day alone (not Object.hash, which changes
    // between runs), so this exact order comes back every launch.
    expect(order, [5, 1, 6, 4, 2, 3]);
  });

  test('limit keeps the first songs in order', () {
    final p = playlist([const SmartRule(field: SmartField.plays, op: SmartOp.atLeast, value: '1')], sort: SmartSort.mostPlayed)
      ..limit = 2;
    expect(ids(p), [6, 5]);
  });
}
