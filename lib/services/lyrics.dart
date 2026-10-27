/// One line of a song's lyrics, and when it's sung if they're timed.
class LyricLine {
  const LyricLine(this.text, [this.time, this.words]);

  final String text;
  final Duration? time;

  /// When each word is sung, from "enhanced" LRC; null if only the line is
  /// timed. Joined, their texts make [text].
  final List<LyricWord>? words;
}

/// A word (with the space after it) and when it's sung.
class LyricWord {
  const LyricWord(this.text, this.time);

  final String text;
  final Duration time;
}

/// A song's lyrics: timed lines that follow the song (from LRC), or plain
/// lines to read along.
class Lyrics {
  const Lyrics(this.lines, {required this.synced});

  final List<LyricLine> lines;
  final bool synced;

  /// The line being sung at [position], or -1 before the first one.
  int lineAt(Duration position) {
    if (!synced) return -1;
    var found = -1;
    for (final (i, line) in lines.indexed) {
      if (line.time! > position) break;
      found = i;
    }
    return found;
  }

  /// When line [index] ends: when the next one starts, or [songEnd] for the
  /// last (null if that isn't known).
  Duration? endOf(int index, {Duration? songEnd}) => index + 1 < lines.length ? lines[index + 1].time : songEnd;
}

/// `[01:23.45]`, `[1:23]` or `[01:23:45]`.
final _timeTag = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

/// Tags like `[ar: Artist]` or `[offset: +250]` at the head of an LRC file.
final _metaTag = RegExp(r'^\[([a-zA-Z#]+):(.*)\]$');

/// Word timings in "enhanced" LRC: `<01:23.45>`.
final _wordTag = RegExp(r'<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>');

/// The time in a `[01:23.45]` or `<01:23.45>` tag.
Duration _timeOf(RegExpMatch tag) {
  final fraction = tag.group(3) ?? '0';
  return Duration(
    minutes: int.parse(tag.group(1)!),
    seconds: int.parse(tag.group(2)!),
    // ".5" is half a second, ".45" 450 ms, ".450" 450 ms.
    milliseconds: (int.parse(fraction) * [100, 10, 1][fraction.length - 1]),
  );
}

/// The words of a line's [text] (what follows its time tags) with when each
/// is sung; null without word timings. Words before the first tag start
/// with the line, at [lineTime].
List<LyricWord>? _words(String text, Duration lineTime) {
  final tags = _wordTag.allMatches(text).toList();
  if (tags.isEmpty) return null;
  final words = <LyricWord>[];
  final before = text.substring(0, tags.first.start).trimLeft();
  if (before.trim().isNotEmpty) words.add(LyricWord(before, lineTime));
  for (final (i, tag) in tags.indexed) {
    final word = text.substring(tag.end, i + 1 < tags.length ? tags[i + 1].start : text.length);
    if (word.trim().isNotEmpty) {
      words.add(LyricWord(words.isEmpty ? word.trimLeft() : word, _timeOf(tag)));
    } else if (words.isNotEmpty) {
      // A tag that only ends a word, with the space before the next one (or
      // nothing, after the last). The space stays with the word before, so
      // the words still join up into the line.
      words.last = LyricWord(words.last.text + word, words.last.time);
    }
  }
  if (words.isEmpty) return null;
  // Trimmed at the end too, like the line's text.
  words.last = LyricWord(words.last.text.trimRight(), words.last.time);
  return words;
}

/// Reads lyrics as saved in a song's tags or a .lrc file. Timed LRC lines
/// become [Lyrics.synced]; anything else is shown as plain text. Null if
/// there's nothing to show.
Lyrics? parseLyrics(String raw) {
  final timed = <LyricLine>[];
  final plain = <String>[];
  var offset = Duration.zero;

  for (final rawLine in raw.split(RegExp(r'\r\n|\r|\n'))) {
    final line = rawLine.trim();
    final meta = _metaTag.firstMatch(line);
    if (meta != null && !_timeTag.hasMatch(line)) {
      // A positive offset shows lines that much sooner.
      if (meta.group(1)!.toLowerCase() == 'offset') {
        offset = Duration(milliseconds: int.tryParse(meta.group(2)!.trim().replaceFirst('+', '')) ?? 0);
      }
      continue;
    }
    final times = _timeTag.allMatches(line).toList();
    if (times.isEmpty) {
      plain.add(line);
      continue;
    }
    final rest = line.substring(times.last.end);
    final text = rest.replaceAll(_wordTag, '').trim();
    // Kept as plain text too, for when one timed line is too few to follow.
    plain.add(text);
    for (final tag in times) {
      final time = _timeOf(tag);
      // Word times belong to one place in the song, so a line sung at
      // several times (a chorus) keeps only its line times.
      timed.add(LyricLine(text, time, times.length == 1 ? _words(rest, time) : null));
    }
  }

  if (timed.length >= 2) {
    timed.sort((a, b) => a.time!.compareTo(b.time!));
    Duration shift(Duration time) => time - offset < Duration.zero ? Duration.zero : time - offset;
    return Lyrics(
      [
        for (final line in timed)
          LyricLine(line.text, shift(line.time!), switch (line.words) {
            final words? => [for (final word in words) LyricWord(word.text, shift(word.time))],
            null => null,
          }),
      ],
      synced: true,
    );
  }
  // Plain text, without blank lines at either end.
  while (plain.isNotEmpty && plain.first.isEmpty) {
    plain.removeAt(0);
  }
  while (plain.isNotEmpty && plain.last.isEmpty) {
    plain.removeLast();
  }
  if (plain.isEmpty) return null;
  return Lyrics([for (final line in plain) LyricLine(line)], synced: false);
}
