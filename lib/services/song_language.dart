/// Guesses what language each song is sung in, so autoplay and radio can keep
/// to it. Files rarely say, so it's worked out offline from the tags:
///
/// - The writing system of the title, album and artist settles Korean,
///   Japanese, Chinese, Thai, Arabic, Hindi and other non-Latin languages.
/// - Common words tell apart languages that share the Latin alphabet
///   ("the", "yang", "que", "der"), with letters such as ñ or ğ as hints.
/// - An artist's usual language covers their songs with titles that say
///   nothing, such as a one-word English title from a K-pop group.
///
/// Languages are short codes (en, es, ko, ...). A few stand for a group that
/// can't be told apart from tags alone: "ms" is Malay and Indonesian,
/// "cyrl" any language written in Cyrillic, "arab" any in Arabic script.
library;

import 'listening_stats.dart';
import 'media_library.dart';

/// The languages of a library's songs, worked out once.
class SongLanguages {
  SongLanguages(Iterable<Song> songs) {
    final byArtist = <String, List<Song>>{};
    for (final song in songs) {
      if (_artistKey(song) case final artist?) byArtist.putIfAbsent(artist, () => []).add(song);
    }
    for (final MapEntry(key: artist, value: artistSongs) in byArtist.entries) {
      _artists[artist] = _usualLanguage(artistSongs);
    }
    for (final song in songs) {
      _songs[song.id] = _decide(song, _artists[_artistKey(song)]);
    }
  }

  final _songs = <int, String?>{};
  final _artists = <String, String?>{};

  /// [song]'s language; null if nothing about it gives one away. Songs
  /// outside the library (a file opened on its own) are worked out the
  /// first time they're asked about.
  String? of(Song song) => _songs.containsKey(song.id)
      ? _songs[song.id]
      : _songs[song.id] = _decide(song, switch (_artistKey(song)) {
          final artist? => _artists[artist] ?? _usualLanguage([song]),
          null => null,
        });

  /// The first artist credited, which says most about the language. Null
  /// for a song with no artist, or "Various Artists": songs grouped under
  /// those have nothing in common, so their usual language says nothing.
  static String? _artistKey(Song song) {
    final artist = song.artist;
    if (artist == null || artist.trim().isEmpty || _variousArtists.hasMatch(artist.trim())) return null;
    return splitArtists(artist).first.toLowerCase();
  }

  /// The language most of [songs] (all by one artist) are in, if most agree.
  static String? _usualLanguage(List<Song> songs) {
    final votes = <String, int>{};
    void vote(String? language, [int weight = 1]) {
      if (language != null) votes[language] = (votes[language] ?? 0) + weight;
    }

    // An artist's name in its own script ("아이유", "宇多田ヒカル") counts
    // for a lot; a name in Latin letters says nothing, so isn't read for words.
    vote(scriptOf(songs.first.artistName), 3);
    final albums = <String>{};
    for (final song in songs) {
      final guess = _ownGuess(song.title);
      vote(guess?.language);
      // Each album once, not once for every song on it.
      if (song.album case final album? when albums.add(album)) vote(_ownGuess(album)?.language);
    }
    if (votes.isEmpty) return null;
    // Chinese characters alone could be Chinese or Japanese; an artist who
    // also uses Japanese kana is Japanese.
    if (votes.remove(_han) case final han?) {
      final as = votes.containsKey('ja') ? 'ja' : 'zh';
      votes[as] = (votes[as] ?? 0) + han;
    }
    final total = votes.values.fold(0, (a, b) => a + b);
    final (language, count) =
        votes.entries.map((e) => (e.key, e.value)).reduce((a, b) => b.$2 > a.$2 ? b : a);
    return count * 2 > total ? language : null;
  }

  /// [song]'s language given its artist's usual one.
  static String? _decide(Song song, String? artistLanguage) {
    final own = _ownGuess(song.title) ?? switch (song.album) {
      final album? => _ownGuess(album),
      null => null,
    };
    // A title in its own script is certain; Chinese characters lean on the
    // artist to tell Japanese from Chinese.
    if (own case (language: final language, sure: true, strong: _)) {
      if (language == _han) return artistLanguage == 'ja' ? 'ja' : 'zh';
      return language;
    }
    // A title with plenty of telling words beats the artist's usual
    // language: a Spanish singer's English song is English.
    if (own case (language: final language, sure: false, strong: true)) return language;
    if (artistLanguage != null) return artistLanguage;
    if (own != null) return own.language;
    return _genreLanguage[song.genre];
  }

  /// [text]'s language, where it shows: [sure] for a non-Latin script,
  /// [strong] for Latin text with more than one telling word.
  static ({String language, bool sure, bool strong})? _ownGuess(String text) {
    if (scriptOf(text) case final script?) return (language: script, sure: true, strong: true);
    final (language, score) = latinLanguage(text);
    if (language == null) return null;
    return (language: language, sure: false, strong: score >= 2);
  }
}

final _variousArtists = RegExp(r'^(various( artists)?|va)$', caseSensitive: false);

/// Stands for Chinese characters with no kana: Chinese or Japanese.
const _han = 'han';

/// Genres (as [normalizeGenre] names them) that give the language away, for
/// songs with nothing else to go by.
const _genreLanguage = {'K-Pop': 'ko'};

/// The language [text]'s non-Latin writing gives away, if it's mostly
/// written in one; null for Latin text or none.
String? scriptOf(String text) {
  // "봄날 (Spring Day)": a translation in brackets doesn't count.
  final outside = text.replaceAll(_brackets, ' ');
  if (outside.trim().isNotEmpty) text = outside;
  var latin = 0;
  var kana = 0;
  final counts = <String, int>{};
  for (final rune in text.runes) {
    if ((rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A) || (rune >= 0xC0 && rune <= 0x24F)) {
      latin++;
      continue;
    }
    if ((rune >= 0x3040 && rune <= 0x30FF) || (rune >= 0x31F0 && rune <= 0x31FF) || (rune >= 0xFF66 && rune <= 0xFF9F)) {
      kana++;
      continue;
    }
    if (_scriptOfRune(rune) case final script?) counts[script] = (counts[script] ?? 0) + 1;
  }
  // Any kana means Japanese, even beside Chinese characters.
  if (kana > 0) counts['ja'] = kana + (counts.remove(_han) ?? 0);
  if (counts.isEmpty) return null;
  final (script, count) = counts.entries.map((e) => (e.key, e.value)).reduce((a, b) => b.$2 > a.$2 ? b : a);
  // Each Korean, Japanese or Chinese character is a whole syllable or word,
  // so a few are worth a word of Latin letters.
  final dense = script == 'ko' || script == 'ja' || script == _han;
  return (dense ? count * 3 : count) >= latin ? script : null;
}

String? _scriptOfRune(int rune) {
  for (final (from, to, script) in _scripts) {
    if (rune < from) return null;
    if (rune <= to) return script;
  }
  return null;
}

/// Unicode blocks and the language (or group) each is written for, in order.
const _scripts = [
  (0x0370, 0x03FF, 'el'),
  (0x0400, 0x052F, 'cyrl'),
  (0x0530, 0x058F, 'hy'),
  (0x0590, 0x05FF, 'he'),
  (0x0600, 0x06FF, 'arab'),
  (0x0750, 0x077F, 'arab'),
  (0x0900, 0x097F, 'hi'),
  (0x0980, 0x09FF, 'bn'),
  (0x0A00, 0x0A7F, 'pa'),
  (0x0A80, 0x0AFF, 'gu'),
  (0x0B00, 0x0B7F, 'or'),
  (0x0B80, 0x0BFF, 'ta'),
  (0x0C00, 0x0C7F, 'te'),
  (0x0C80, 0x0CFF, 'kn'),
  (0x0D00, 0x0D7F, 'ml'),
  (0x0D80, 0x0DFF, 'si'),
  (0x0E00, 0x0E7F, 'th'),
  (0x0E80, 0x0EFF, 'lo'),
  (0x1000, 0x109F, 'my'),
  (0x10A0, 0x10FF, 'ka'),
  (0x1100, 0x11FF, 'ko'),
  (0x1200, 0x137F, 'am'),
  (0x1780, 0x17FF, 'km'),
  (0x3130, 0x318F, 'ko'),
  (0x3400, 0x4DBF, _han),
  (0x4E00, 0x9FFF, _han),
  (0xAC00, 0xD7AF, 'ko'),
  (0xF900, 0xFAFF, _han),
  (0xFB50, 0xFDFF, 'arab'),
  (0xFE70, 0xFEFF, 'arab'),
];

/// The Latin-alphabet language [text]'s words point to and how many point
/// to it; null when none do, or two are level.
(String?, int) latinLanguage(String text) {
  // Brackets mostly hold credits and versions: "(feat. ...)", "[Live]".
  final outside = text.replaceAll(_brackets, ' ');
  final lower = (outside.trim().isEmpty ? text : outside).toLowerCase().replaceAll('’', "'");
  final scores = <String, int>{};
  void score(String language, [int by = 1]) => scores[language] = (scores[language] ?? 0) + by;

  // Words shared with another language, English included, are set aside:
  // alone they mislead ("Die Young" isn't German), so they only add to a
  // language the rest of the title already points to.
  final shared = <String>[];
  for (final match in _word.allMatches(lower)) {
    final word = match[0]!;
    if (_versionWords.contains(word)) continue;
    if (_sharedWords.contains(word)) {
      shared.add(word);
      continue;
    }
    for (final MapEntry(key: language, value: words) in _words.entries) {
      if (words.contains(word)) score(language);
    }
    // Malay and Indonesian join endings on: "cintanya", "lupakan".
    if (word.length > 5 && (word.endsWith('nya') || word.endsWith('kan'))) score('ms');
  }
  for (final rune in lower.runes) {
    if (_letterHints[rune] case final language?) score(language, 2);
    // Vietnamese stacks accents into letters no other language uses. (Not
    // đ on its own: Croatian and Serbian write it too.)
    if (rune >= 0x1EA0 && rune <= 0x1EF9 || rune == 0x1A1 || rune == 0x1B0) score('vi', 2);
  }
  final pointed = scores.keys.toSet();
  for (final word in shared) {
    for (final language in pointed) {
      if (_words[language]!.contains(word)) score(language);
    }
  }
  if (scores.isEmpty) return (null, 0);
  final ranked = scores.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  if (ranked.length > 1 && ranked[0].value == ranked[1].value) return (null, 0);
  return (ranked[0].key, ranked[0].value);
}

final _brackets = RegExp(r'\([^)]*\)|\[[^\]]*\]');
final _word = RegExp(r"[a-zÀ-ɏ]+(?:'[a-z]+)?");

/// Words on songs of every language: versions and credits.
const _versionWords = {
  'feat', 'ft', 'featuring', 'remix', 'mix', 'edit', 'version', 'live', 'remaster', 'remastered',
  'acoustic', 'instrumental', 'radio', 'extended', 'original', 'demo', 'mono', 'stereo', 'bonus',
  'intro', 'outro', 'interlude', 'prod', 'vs', 'x', 'op', 'no', 'pt', 'part', 'vol', 'ost', 'remixes',
};

/// Letters that point to one language.
const _letterHints = {
  0xF1: 'es', // ñ
  0xE3: 'pt', // ã
  0xF5: 'pt', // õ
  0xDF: 'de', // ß
  0x11F: 'tr', // ğ
  0x15F: 'tr', // ş
  0x131: 'tr', // ı
  0xE5: 'sv', // å
};

/// Words in more than one language's list, or that are also everyday
/// English ("die", "do", "solo"), which only back up other words.
final Set<String> _sharedWords = () {
  final seen = <String>{};
  final shared = <String>{..._alsoEnglish};
  for (final words in _words.values) {
    for (final word in words) {
      if (!seen.add(word)) shared.add(word);
    }
  }
  return shared;
}();

/// Words in another language's list that are English words too.
const _alsoEnglish = {'die', 'o', 'do', 'sin', 'solo', 'bin', 'den', 'is', 'van', 'ben', 'dan', 'ma', 'gel', 'var'};

/// Short, common words that give a language away. Some belong to two
/// languages ("la", "amor"); those count only alongside others (see
/// [_sharedWords]).
const _words = {
  'en': {
    'the', 'you', 'your', "you're", 'i', "i'm", "i'll", "i've", 'my', 'love', 'and', 'of', 'to', 'it', "it's",
    "don't", "can't", "won't", 'we', 'be', 'with', 'for', 'this', 'that', 'what', 'when', 'baby', 'heart',
    'night', 'never', 'just', 'like', 'girl', 'boy', 'time', 'are', 'go', 'get', 'got', 'little', 'one',
    'out', 'down', 'feel', 'say', 'way', 'want', 'know', 'let', 'make', 'back', 'world', 'life', 'day',
    'dream', 'light', 'home', 'away', 'without', 'tonight', 'forever', 'alone', 'together', 'again', 'more',
    'better', 'all', 'up', 'from', 'by', 'at', 'over', 'how', 'where', 'who', 'why', 'every', 'still',
    'somebody', 'nothing', 'something', 'everything', 'always', 'stay', 'take', 'come', 'gonna', 'wanna',
  },
  'es': {
    'el', 'los', 'las', 'y', 'que', 'mi', 'tu', 'te', 'amor', 'corazón', 'corazon', 'por', 'para', 'con', 'una',
    'yo', 'del', 'quiero', 'vida', 'sin', 'cuando', 'como', 'eres', 'más', 'todo', 'nada', 'noche', 'bésame',
    'contigo', 'solo', 'siempre', 'nunca', 'ella', 'porque', 'pero', 'ti', 'soy', 'estoy', 'muy', 'bien',
    'mujer', 'hoy', 'tú', 'qué', 'adiós', 'mundo', 'la', 'lo', 'se', 'es', 'otra', 'vez', 'amigo', 'mío',
    'cielo', 'baila', 'bailar', 'dime', 'ojos', 'nosotros', 'quién', 'dónde',
  },
  'pt': {
    'o', 'os', 'não', 'você', 'eu', 'meu', 'minha', 'coração', 'amor', 'saudade', 'do', 'da', 'dos', 'das',
    'em', 'um', 'uma', 'com', 'mais', 'sem', 'vida', 'tudo', 'nada', 'quero', 'seu', 'sua', 'ao', 'é', 'ela',
    'ele', 'nós', 'noite', 'beijo', 'mundo', 'que', 'se', 'pra', 'pro', 'gente', 'também', 'então',
  },
  'fr': {
    'le', 'la', 'les', 'je', 'tu', 'et', 'est', 'une', 'un', 'des', 'du', 'au', 'pas', 'pour', 'dans', 'mon',
    'ma', 'mes', 'moi', 'toi', "c'est", "j'ai", "l'amour", 'amour', 'ne', 'qui', 'avec', 'sur', 'nous', 'vous',
    'il', 'elle', 'coeur', 'cœur', 'vie', 'tout', 'rien', 'jamais', 'toujours', 'nuit', 'que', 'ce', 'oui',
  },
  'de': {
    'der', 'die', 'das', 'und', 'ich', 'du', 'nicht', 'ist', 'mit', 'ein', 'eine', 'mein', 'dich', 'mich',
    'liebe', 'für', 'auf', 'wir', 'zu', 'sie', 'es', 'den', 'dem', 'nacht', 'herz', 'wenn', 'auch', 'nur',
    'noch', 'kein', 'immer', 'alles', 'bist', 'bin', 'nie', 'schön',
  },
  'it': {
    'il', 'lo', 'gli', 'che', 'di', 'e', 'non', 'sono', 'ti', 'mi', 'amo', 'amore', 'cuore', 'per', 'con',
    'una', 'un', 'nel', 'della', 'del', 'ho', 'sei', 'io', 'più', 'notte', 'tutto', 'sempre', 'vita', 'mio',
    'mia', 'ancora', 'bella', 'perché', 'come', 'questo', 'senza',
  },
  'ms': {
    'aku', 'kau', 'kamu', 'engkau', 'dia', 'kita', 'kami', 'mereka', 'yang', 'dan', 'di', 'ke', 'dari', 'ini',
    'itu', 'untuk', 'cinta', 'hati', 'sayang', 'rindu', 'tak', 'tidak', 'takkan', 'bukan', 'ada', 'akan',
    'dengan', 'pada', 'jangan', 'lagi', 'sudah', 'hanya', 'mu', 'ku', 'kekasih', 'selamanya', 'cintaku',
    'hatiku', 'sayangku', 'kasih', 'bila', 'apa', 'mana', 'saja', 'jiwa', 'mimpi', 'malam', 'hari', 'bersama',
    'terakhir', 'sampai', 'satu', 'lagu', 'raya', 'selamat', 'tanpa', 'pergi', 'kembali', 'seribu', 'tiada',
    'dalam', 'biar', 'kerana', 'karena', 'menunggu', 'semua', 'cerita', 'janji', 'sendiri', 'rasa', 'bulan',
    'bintang', 'aidilfitri', 'kisah', 'pulang', 'senyum', 'abadi', 'gadis', 'sepi', 'luka',
  },
  'tl': {
    'ang', 'ng', 'mga', 'sa', 'ko', 'ka', 'mo', 'ikaw', 'ako', 'mahal', 'kong', 'na', 'at', 'puso', 'hindi',
    'lang', 'akin', 'iyo', 'kita', 'natin', 'tayo', 'ba', 'kay', 'ay', 'paano', 'sana', 'pag-ibig', 'kailan',
  },
  'nl': {
    'het', 'een', 'ik', 'je', 'jij', 'niet', 'van', 'en', 'is', 'mijn', 'dat', 'zijn', 'wat', 'voor', 'op',
    'met', 'liefde', 'hart', 'nooit', 'alleen', 'mij', 'jou',
  },
  'sv': {
    'och', 'jag', 'du', 'att', 'det', 'en', 'är', 'inte', 'med', 'min', 'mig', 'dig', 'för', 'på', 'kärlek',
  },
  'tr': {
    'bir', 've', 'ben', 'sen', 'seni', 'beni', 'aşk', 'bu', 'ne', 'gibi', 'için', 'değil', 'kadar', 'yok',
    'var', 'gel', 'benim', 'senin', 'aşkım', 'gönül', 'yar',
  },
  // Only words the letter check above misses: those spelled without
  // Vietnamese's stacked accents.
  'vi': {
    'anh', 'em', 'yêu', 'không', 'đi', 'đâu', 'đó', 'đêm', 'tình', 'mình', 'và', 'là', 'cho', 'xa', 'ơi',
  },
};
