import 'dart:math';

import 'listening_log.dart';
import 'media_library.dart';

/// The part of the day [time] falls in.
String dayMoment(DateTime time) => switch (time.hour) {
  >= 5 && < 12 => 'this morning',
  >= 12 && < 17 => 'this afternoon',
  >= 17 && < 22 => 'this evening',
  _ => 'tonight',
};

/// [count] songs for Home: some the listener tends to play around this time
/// of day, the rest at random so there's always something unexpected.
List<Song> quickPicksFor({
  required List<Song> songs,
  required List<ListenEvent> listens,
  required DateTime now,
  required int count,
  Random? random,
}) {
  final rng = random ?? Random();
  final byTime = <int, double>{};
  final total = <int, int>{};
  for (final listen in listens) {
    if (!listen.countsAsPlay) continue;
    total.update(listen.songId, (plays) => plays + 1, ifAbsent: () => 1);
    final near = _nearness(listen.endedAt.hour, now.hour);
    if (near > 0) byTime.update(listen.songId, (plays) => plays + near, ifAbsent: () => near);
  }

  // A song played only at this hour beats one played as often at all hours,
  // which isn't about the time of day at all.
  final weights = <Song, double>{
    for (final song in songs)
      if ((byTime[song.id] ?? 0) >= _fewestPlays) song: byTime[song.id]! * byTime[song.id]! / total[song.id]!,
  };

  final picks = <Song>[];
  final wanted = (count * _shareByTime).floor();
  while (picks.length < wanted && weights.isNotEmpty) {
    // By weight, so a favourite is likely but a set doesn't repeat each time.
    var left = rng.nextDouble() * weights.values.reduce((a, b) => a + b);
    final pick = weights.keys.firstWhere((song) => (left -= weights[song]!) <= 0, orElse: () => weights.keys.last);
    weights.remove(pick);
    picks.add(pick);
  }
  final chosen = picks.toSet();
  picks.addAll(([for (final s in songs) if (!chosen.contains(s)) s]..shuffle(rng)).take(count - picks.length));
  return picks..shuffle(rng);
}

/// How much of the set goes by the time of day.
const _shareByTime = 0.6;

/// Plays near this hour before a song counts as belonging to it.
const _fewestPlays = 2;

/// How much a play at [hour] counts for now, at [nowHour]: an evening habit
/// doesn't keep to the clock exactly.
double _nearness(int hour, int nowHour) {
  final apart = (hour - nowHour).abs();
  return switch (min(apart, 24 - apart)) {
    0 || 1 => 1,
    2 => 0.5,
    _ => 0,
  };
}
