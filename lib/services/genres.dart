/// Maps detailed genre tags (often micro-genres such as "Conscious Hip
/// Hop" or "Malaysian Pop") onto a few broad genres.
///
/// Tags name their main genre last ("Alternative *Rock*", "Dance *Pop*"),
/// so the end of the tag is checked first, then any keyword in it.
/// Tags that match nothing keep their own name.
library;

const _dance = 'Dance & Electronic';
const _hipHop = 'Hip-Hop';
const _rnb = 'R&B & Soul';
const _indie = 'Indie & Alternative';
const _folk = 'Folk & Acoustic';
const _country = 'Country & Americana';
const _soundtrack = 'Soundtracks & Musicals';
const _vgm = 'Video Game Music';
const _chill = 'Chill';

/// Whole tags that keyword matching would get wrong.
const _exact = {
  'bass trap': _dance,
  'krushfunk': _dance,
  'krushclub': _dance,
  'complextro': _dance,
  'indietronica': _dance,
  'electrofox': _dance,
  'speedrun': _vgm,
  'new romantic': 'Pop',
  'british dance band': 'Jazz',
  'adult standards': 'Jazz',
  'theme': _soundtrack,
  'vintage hollywood': _soundtrack,
  'celtic': _folk,
};

/// Checked anywhere in the tag before its ending, because they override the
/// head word: "Indie Game Soundtrack" and "Gaming EDM" are game music.
const _overrides = {
  'vgm': _vgm,
  'video game': _vgm,
  'game soundtrack': _vgm,
  'gaming': _vgm,
  'chiptune': _vgm,
  'k-pop': 'K-Pop',
};

/// Head words and phrases, matched against the end of the tag.
const _heads = {
  // Two-word phrases come first so they win over their last word.
  'hip hop': _hipHop,
  'big room': _dance,
  'big beat': _dance,
  'bass music': _dance,
  'hard bass': _dance,
  'big band': 'Jazz',
  'bossa nova': 'Latin',
  'nova mpb': 'Latin',
  'singer-songwriter': _folk,
  'lo-fi chill': _chill,
  'rap': _hipHop,
  'trap': _hipHop,
  'phonk': _hipHop,
  'plugg': _hipHop,
  'grime': _hipHop,
  'g funk': _hipHop,
  'hyphy': _hipHop,
  'bounce': _hipHop,
  'kreyol': _hipHop,
  'pop': 'Pop',
  'europop': 'Pop',
  'electropop': 'Pop',
  'schlager': 'Pop',
  'metal': 'Metal',
  'metalcore': 'Metal',
  'rock': 'Rock',
  'rockabilly': 'Rock',
  'punk': 'Rock',
  'post-punk': 'Rock',
  'shoegaze': _indie,
  'indie': _indie,
  'r&b': _rnb,
  'soul': _rnb,
  'funk': _rnb,
  'doo-wop': _rnb,
  'edm': _dance,
  'house': _dance,
  'dnb': _dance,
  'electro': _dance,
  'electronic': _dance,
  'eurobeat': _dance,
  'eurodance': _dance,
  'dance': _dance,
  'bassline': _dance,
  'breakbeat': _dance,
  'folk': _folk,
  'country': _country,
  'jazz': 'Jazz',
  'dixieland': 'Jazz',
  'blues': 'Blues',
  'reggaeton': 'Latin',
  'duranguense': 'Latin',
  'classical': 'Classical',
  'soundtrack': _soundtrack,
  'score': _soundtrack,
  'ambient': _chill,
};

/// Word endings for fused names such as "Brostep" and "Austindie".
const _suffixes = {
  'step': _dance,
  'indie': _indie,
  'folk': _folk,
  'house': _dance,
};

/// Tags that say nothing about the music.
const _meaningless = {'music', 'other', 'unknown', 'genre'};

/// Returns the broad genre for [tag], or null when there's no useful tag. A
/// tag listing several genres ("Rap/Hip Hop") uses the first that matches.
String? normalizeGenre(String? tag) {
  if (tag == null) return null;
  final parts = tag
      .split(RegExp(r'[/;,|]'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty && !_meaningless.contains(p.toLowerCase()));
  String? fallback;
  for (final part in parts) {
    final broad = _broadGenre(part.toLowerCase());
    if (broad != null) return broad;
    fallback ??= _titleCase(part);
  }
  return fallback;
}

String? _broadGenre(String tag) {
  final exact = _exact[tag];
  if (exact != null) return exact;

  for (final MapEntry(:key, :value) in _overrides.entries) {
    if (tag.contains(key)) return value;
  }

  final words = tag.split(RegExp(r'\s+'));
  // The last two words, then the last one: "Conscious Hip Hop" -> "hip hop".
  for (final count in [2, 1]) {
    if (words.length < count) continue;
    final head = words.sublist(words.length - count).join(' ');
    final match = _heads[head];
    if (match != null) return match;
  }

  final last = words.last;
  for (final MapEntry(:key, :value) in _suffixes.entries) {
    if (last.endsWith(key)) return value;
  }

  // Finally any known word elsewhere, including inside hyphenated ones:
  // "Phonk Brasileiro", "Uk Post-Punk Revival", "Neo-Rockabilly".
  for (final word in words.reversed) {
    for (final piece in [word, ...word.split('-').reversed]) {
      final match = _heads[piece];
      if (match != null) return match;
    }
  }
  return null;
}

/// "dance pop" -> "Dance Pop", keeping short all-caps tags like "EDM" intact.
String _titleCase(String tag) => tag
    .split(' ')
    .map((w) => w.isEmpty || w == w.toUpperCase() ? w : w[0].toUpperCase() + w.substring(1))
    .join(' ');
