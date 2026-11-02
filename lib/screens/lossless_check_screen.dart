import 'package:flutter/material.dart';

import '../services/lossless_check.dart';
import '../services/media_library.dart';
import '../services/music_controller.dart';
import '../theme.dart';
import '../widgets/shelf.dart';
import '../widgets/song_artwork.dart';
import '../widgets/song_options.dart';

/// Listens to the library's lossless files and lists those that sound as if
/// they were made from a lossy file, such as an MP3 saved as a FLAC. It stops
/// on leaving the page, and carries on from there next time.
class LosslessCheckScreen extends StatefulWidget {
  const LosslessCheckScreen({super.key});

  @override
  State<LosslessCheckScreen> createState() => _LosslessCheckScreenState();
}

class _LosslessCheckScreenState extends State<LosslessCheckScreen> {
  /// How many songs are checked between saves.
  static const _saveEvery = 20;

  /// Songs that look wrong, with what was found.
  final _found = <(Song, LosslessResult)>[];

  /// How many files were looked at, and how many in all.
  int _checked = 0, _total = 0;

  int _unreadable = 0;

  /// Still working out which files to check.
  bool _preparing = true;

  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    if (!mounted) return;
    final songs = MusicScope.read(context).songs;
    final lossless = <Song>[];
    for (final song in songs) {
      if (await LosslessCheck.isLossless(song)) lossless.add(song);
      if (!mounted) return;
    }
    final results = await LosslessResults.open();
    if (!mounted) return;
    setState(() {
      _preparing = false;
      _total = lossless.length;
    });
    var unsaved = 0;
    for (final song in lossless) {
      var result = results.of(song);
      if (result == null) {
        result = await LosslessCheck.check(song);
        results.put(song, result);
        if (++unsaved >= _saveEvery) {
          unsaved = 0;
          await results.save();
        }
      }
      if (!mounted) {
        await results.save();
        return;
      }
      final known = result;
      setState(() {
        _checked++;
        if (known.verdict == LosslessVerdict.unknown) _unreadable++;
        if (known.verdict != LosslessVerdict.genuine && known.verdict != LosslessVerdict.unknown) {
          _found
            ..add((song, known))
            ..sort((a, b) => b.$2.verdict.index.compareTo(a.$2.verdict.index));
        }
      });
    }
    await results.save();
    if (mounted) setState(() => _done = true);
  }

  String get _summary {
    if (!_done) return 'Checked $_checked of $_total files…';
    final files = _total == 1 ? '1 lossless file' : '$_total lossless files';
    final found = switch (_found.length) {
      0 => 'none look wrong',
      1 => '1 looks wrong',
      final n => '$n look wrong',
    };
    return "Checked $files: $found.${_unreadable > 0 ? " $_unreadable couldn't be judged, being too quiet or unreadable." : ''}";
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Check lossless files')),
      body: _done && _total == 0
          ? const MessageView(icon: Icons.graphic_eq_rounded, text: 'No lossless files in your library.')
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: _found.length + 1,
              itemBuilder: (context, i) {
                if (i > 0) return _SuspectTile(song: _found[i - 1].$1, result: _found[i - 1].$2);
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'MP3s and other lossy files lose their highest sounds above a fixed point, and saving one as '
                        'a FLAC can’t bring them back. Blimp listens for that sharp edge. It’s a strong sign, not '
                        'proof: some old recordings and masters stop early too.',
                        style: textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 12),
                      if (!_done) ...[
                        LinearProgressIndicator(value: _total == 0 ? null : _checked / _total),
                        const SizedBox(height: 8),
                      ],
                      if (!_preparing) Text(_summary, style: textTheme.labelLarge),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

/// A song that looks wrong, and why. Tap to play; its ⋮ menu has the usual
/// options.
class _SuspectTile extends StatelessWidget {
  const _SuspectTile({required this.song, required this.result});

  final Song song;
  final LosslessResult result;

  String get _reason {
    final khz = ((result.cutoffHz ?? 0) / 1000).toStringAsFixed(1);
    return switch (result.verdict) {
      LosslessVerdict.likelyLossy => 'Stops sharply at $khz kHz: probably made from an MP3 or similar',
      LosslessVerdict.possiblyLossy => 'Stops sharply at $khz kHz: maybe made from a high quality MP3',
      LosslessVerdict.upscaled => 'Stops at $khz kHz: probably CD quality saved as hi-res',
      _ => '',
    };
  }

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.read(context);
    return ListTile(
      leading: SongArtwork(songId: song.id, size: 48, radius: 10),
      onTap: () => music.playSongs([song]),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_reason, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        tooltip: 'More',
        icon: const Icon(Icons.more_vert_rounded, color: AppColors.textSecondary),
        onPressed: () => showSongOptions(context, song),
      ),
    );
  }
}
