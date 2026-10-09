/// Text as search compares it: lowercase, without accents ("é" is "e"), with
/// apostrophes and periods dropped ("Don't" is "dont", "Mr." is "mr") and
/// other punctuation as spaces. "&" reads as "and".
String searchKey(String text) {
  final out = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    out.write(_folded[char] ?? char);
  }
  return out
      .toString()
      .replaceAll(_joining, '')
      .replaceAll('&', ' and ')
      .replaceAll(_separators, ' ')
      .trim();
}

/// [key] (from [searchKey]) without spaces, so "acdc" finds "AC/DC".
String compactKey(String key) => key.replaceAll(' ', '');

/// Marks that join a word rather than split it.
final _joining = RegExp(r"['’‘`´.]");

/// Anything that isn't a letter or digit, in any script.
final _separators = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Accented Latin letters as their plain ones.
const _folded = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a', 'ă': 'a', 'ą': 'a', //
  'æ': 'ae', 'ç': 'c', 'ć': 'c', 'č': 'c', 'ď': 'd', 'đ': 'd', 'ð': 'd',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ė': 'e', 'ę': 'e', 'ě': 'e', //
  'ğ': 'g', 'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i', 'ı': 'i', 'į': 'i', //
  'ł': 'l', 'ľ': 'l', 'ñ': 'n', 'ń': 'n', 'ň': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o', 'ő': 'o', 'œ': 'oe', //
  'ř': 'r', 'ś': 's', 'š': 's', 'ş': 's', 'ș': 's', 'ß': 'ss', 'ť': 't', 'ț': 't', 'þ': 'th',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u', 'ů': 'u', 'ű': 'u', 'ų': 'u', //
  'ý': 'y', 'ÿ': 'y', 'ź': 'z', 'ż': 'z', 'ž': 'z',
};
