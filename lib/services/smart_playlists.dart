import 'dart:convert';
import 'dart:math';

import 'desktop_library.dart';
import 'media_library.dart';
import 'search_text.dart';

/// What a smart playlist's rule looks at in a song.
enum SmartField {
  title('Title', SmartValue.text),
  artist('Artist', SmartValue.text),
  album('Album', SmartValue.text),
  genre('Genre', SmartValue.genre),
  year('Year', SmartValue.number),
  rating('Rating', SmartValue.stars),
  plays('Plays', SmartValue.number),
  added('Added', SmartValue.days),
  lastPlayed('Last played', SmartValue.days),
  minutes('Length in minutes', SmartValue.number),
  favourite('Favourite', SmartValue.none);

  const SmartField(this.label, this.value);
  final String label;
  final SmartValue value;

  /// The comparisons that make sense for this field, the first the default.
  List<SmartOp> get ops => switch (value) {
    SmartValue.text => const [SmartOp.contains, SmartOp.isEqual, SmartOp.isNot],
    SmartValue.genre => const [SmartOp.isEqual, SmartOp.isNot],
    SmartValue.number || SmartValue.stars => const [SmartOp.atLeast, SmartOp.atMost],
    SmartValue.days => [
      SmartOp.withinDays,
      SmartOp.notWithinDays,
      if (this == SmartField.lastPlayed) SmartOp.never,
    ],
    SmartValue.none => const [SmartOp.isTrue, SmartOp.isFalse],
  };
}

/// What a rule's value is entered as.
enum SmartValue { text, genre, number, stars, days, none }

enum SmartOp {
  contains('contains'),
  isEqual('is'),
  isNot('is not'),
  atLeast('is at least'),
  atMost('is at most'),
  withinDays('in the last … days'),
  notWithinDays('not in the last … days'),
  never('never'),
  isTrue('yes'),
  isFalse('no');

  const SmartOp(this.label);
  final String label;

  /// Whether the rule needs a value beside it.
  bool get takesValue => this != never && this != isTrue && this != isFalse;
}

/// One condition songs are picked by, such as "Plays is at least 5".
class SmartRule {
  const SmartRule({required this.field, required this.op, this.value = ''});

  factory SmartRule.fromJson(Map<String, Object?> json) {
    final field = SmartField.values.asNameMap()[json['field']] ?? SmartField.title;
    final op = SmartOp.values.asNameMap()[json['op']];
    return SmartRule(
      field: field,
      op: op != null && field.ops.contains(op) ? op : field.ops.first,
      value: json['value'] as String? ?? '',
    );
  }

  /// A new rule on [field], with its first comparison.
  factory SmartRule.on(SmartField field) => SmartRule(field: field, op: field.ops.first);

  final SmartField field;
  final SmartOp op;
  final String value;

  SmartRule copyWith({SmartOp? op, String? value}) => SmartRule(field: field, op: op ?? this.op, value: value ?? this.value);

  Map<String, Object?> toJson() => {'field': field.name, 'op': op.name, 'value': value};

  /// Whether this rule says enough to go by: a number where one is needed.
  bool get isComplete => switch (field.value) {
    _ when !op.takesValue => true,
    SmartValue.text || SmartValue.genre => value.trim().isNotEmpty,
    _ => num.tryParse(value.trim()) != null,
  };
}

/// How a smart playlist orders the songs it picks.
enum SmartSort {
  random('Random, new each day'),
  mostPlayed('Most played'),
  leastPlayed('Least played'),
  recentlyAdded('Recently added'),
  recentlyPlayed('Recently played'),
  rating('Highest rated'),
  title('Title'),
  artist('Artist'),
  year('Newest first');

  const SmartSort(this.label);
  final String label;
}

/// A playlist that fills itself: the songs matching its rules, kept up to
/// date as the library and what's played change.
class SmartPlaylist {
  SmartPlaylist({
    required this.id,
    required this.name,
    required this.rules,
    this.matchAll = true,
    this.sort = SmartSort.random,
    this.limit,
  });

  factory SmartPlaylist.fromJson(Map<String, Object?> json) => SmartPlaylist(
    id: json['id'] as String,
    name: json['name'] as String,
    rules: [for (final rule in json['rules'] as List) SmartRule.fromJson(rule as Map<String, Object?>)],
    matchAll: json['all'] as bool? ?? true,
    sort: SmartSort.values.asNameMap()[json['sort']] ?? SmartSort.random,
    limit: json['limit'] as int?,
  );

  final String id;
  String name;
  List<SmartRule> rules;

  /// Songs must match every rule, or else any one of them.
  bool matchAll;
  SmartSort sort;

  /// At most this many songs; null for all that match.
  int? limit;

  static const limitOptions = [null, 25, 50, 100, 250, 500];

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'rules': [for (final rule in rules) rule.toJson()],
    'all': matchAll,
    'sort': sort.name,
    'limit': ?limit,
  };
}

String encodeSmartPlaylists(List<SmartPlaylist> playlists) => jsonEncode([for (final p in playlists) p.toJson()]);

/// The saved smart playlists, or none if [saved] is missing or unreadable.
List<SmartPlaylist> decodeSmartPlaylists(String? saved) {
  if (saved == null) return [];
  try {
    return [for (final p in jsonDecode(saved) as List) SmartPlaylist.fromJson(p as Map<String, Object?>)];
  } on Object {
    return [];
  }
}

/// What a smart playlist knows of each song beyond its tags.
class SmartFacts {
  const SmartFacts({
    required this.plays,
    required this.rating,
    required this.lastPlayed,
    required this.isFavourite,
    required this.historyRank,
  });

  final int Function(Song song) plays;
  final int Function(Song song) rating;
  final DateTime? Function(Song song) lastPlayed;
  final bool Function(Song song) isFavourite;

  /// 0 for the song played last; larger for longer ago, or never.
  final int Function(Song song) historyRank;
}

/// The songs of [library] that [playlist] picks, in its order. A playlist
/// with no complete rules picks nothing, rather than the whole library.
List<Song> pickSmartPlaylistSongs(SmartPlaylist playlist, List<Song> library, SmartFacts facts, {DateTime? now}) {
  now ??= DateTime.now();
  final rules = [
    for (final rule in playlist.rules)
      if (rule.isComplete) (rule: rule, number: num.tryParse(rule.value.trim()), text: searchKey(rule.value.trim())),
  ];
  if (rules.isEmpty) return const [];
  bool matches(Song song) =>
      playlist.matchAll ? rules.every((r) => _matches(r, song, facts, now!)) : rules.any((r) => _matches(r, song, facts, now!));
  final picked = library.where(matches).toList();

  int byTitle(Song a, Song b) => a.searchFields.first.compareTo(b.searchFields.first);
  int then(int c, Song a, Song b) => c != 0 ? c : byTitle(a, b);
  final epoch = DateTime(0);
  switch (playlist.sort) {
    case SmartSort.random:
      // The same order all day, so the list doesn't jump about as it's
      // looked at; a new one tomorrow.
      final day = now.year * 10000 + now.month * 100 + now.day;
      picked
        ..sort(byTitle)
        // Object.hash differs from one run to the next; this doesn't.
        ..shuffle(Random(DesktopLibrary.stableId('${playlist.id}|$day')));
    case SmartSort.mostPlayed:
      picked.sort((a, b) => then(facts.plays(b).compareTo(facts.plays(a)), a, b));
    case SmartSort.leastPlayed:
      picked.sort((a, b) => then(facts.plays(a).compareTo(facts.plays(b)), a, b));
    case SmartSort.recentlyAdded:
      picked.sort((a, b) => then((b.dateAdded ?? epoch).compareTo(a.dateAdded ?? epoch), a, b));
    case SmartSort.recentlyPlayed:
      picked.sort((a, b) => then(facts.historyRank(a).compareTo(facts.historyRank(b)), a, b));
    case SmartSort.rating:
      picked.sort((a, b) => then(facts.rating(b).compareTo(facts.rating(a)), a, b));
    case SmartSort.title:
      picked.sort(byTitle);
    case SmartSort.artist:
      picked.sort((a, b) => then(searchKey(a.artistName).compareTo(searchKey(b.artistName)), a, b));
    case SmartSort.year:
      picked.sort((a, b) => then((b.year ?? 0).compareTo(a.year ?? 0), a, b));
  }
  final limit = playlist.limit;
  return limit == null || picked.length <= limit ? picked : picked.sublist(0, limit);
}

/// [rule] with its value already read as a number and as search text.
typedef _ReadRule = ({SmartRule rule, num? number, String text});

bool _matches(_ReadRule read, Song song, SmartFacts facts, DateTime now) {
  final rule = read.rule;
  final number = read.number;
  bool compare(num? actual) {
    if (actual == null || number == null) return false;
    return rule.op == SmartOp.atLeast ? actual >= number : actual <= number;
  }
  bool text(String? actual) {
    final have = searchKey(actual ?? '');
    final want = read.text;
    return switch (rule.op) {
      SmartOp.contains => have.contains(want),
      SmartOp.isEqual => have == want,
      SmartOp.isNot => have != want,
      _ => false,
    };
  }

  bool days(DateTime? when) {
    if (rule.op == SmartOp.never) return when == null;
    if (number == null) return false;
    final within = when != null && now.difference(when) <= Duration(hours: (number * 24).round());
    return rule.op == SmartOp.withinDays ? within : !within;
  }

  return switch (rule.field) {
    SmartField.title => text(song.title),
    SmartField.artist => text(song.artist),
    SmartField.album => text(song.album),
    SmartField.genre => text(song.genre),
    SmartField.year => compare(song.year),
    // Unrated isn't low-rated: rating rules leave unrated songs out.
    SmartField.rating => compare(switch (facts.rating(song)) {
      0 => null,
      final stars => stars,
    }),
    SmartField.plays => compare(facts.plays(song)),
    SmartField.added => days(song.dateAdded),
    SmartField.lastPlayed => days(facts.lastPlayed(song)),
    SmartField.minutes => compare(switch (song.duration) {
      final d? when d > Duration.zero => d.inSeconds / 60,
      _ => null,
    }),
    SmartField.favourite => facts.isFavourite(song) == (rule.op == SmartOp.isTrue),
  };
}
