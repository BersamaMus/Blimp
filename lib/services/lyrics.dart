/// One line of a song's lyrics, and when it's sung if they're timed.
class LyricLine {
  const LyricLine(this.text, [this.time]);

  final String text;
  final Duration? time;
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
}

/// `[01:23.45]`, `[1:23]` or `[01:23:45]`.
final _timeTag = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

/// Tags like `[ar: Artist]` or `[offset: +250]` at the head of an LRC file.
final _metaTag = RegExp(r'^\[([a-zA-Z#]+):(.*)\]$');

/// Word timings in "enhanced" LRC: `<01:23.45>`.
final _wordTag = RegExp(r'<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>');

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
    final text = line.substring(times.last.end).replaceAll(_wordTag, '').trim();
    // Kept as plain text too, for when one timed line is too few to follow.
    plain.add(text);
    for (final time in times) {
      final fraction = time.group(3) ?? '0';
      timed.add(LyricLine(
        text,
        Duration(
          minutes: int.parse(time.group(1)!),
          seconds: int.parse(time.group(2)!),
          // ".5" is half a second, ".45" 450 ms, ".450" 450 ms.
          milliseconds: (int.parse(fraction) * [100, 10, 1][fraction.length - 1]),
        ),
      ));
    }
  }

  if (timed.length >= 2) {
    timed.sort((a, b) => a.time!.compareTo(b.time!));
    return Lyrics(
      [
        for (final line in timed)
          LyricLine(line.text, line.time! - offset < Duration.zero ? Duration.zero : line.time! - offset),
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
