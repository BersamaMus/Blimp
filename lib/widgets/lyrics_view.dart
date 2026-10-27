import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../screens/karaoke_screen.dart';
import '../services/lyrics.dart';
import '../services/music_controller.dart';
import '../theme.dart';

/// The playing song's lyrics. Timed ones follow along: the line being sung
/// is lit and kept in view, and tapping a line jumps there. Plain ones are
/// shown to read.
class LyricsView extends StatelessWidget {
  const LyricsView({super.key, required this.lyrics});

  final Lyrics lyrics;

  @override
  Widget build(BuildContext context) {
    if (lyrics.synced) return _SyncedLyrics(lyrics: lyrics);
    final style = Theme.of(context).textTheme.titleMedium?.copyWith(height: 1.6, color: Colors.white);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: SelectableText(
        [for (final line in lyrics.lines) line.text].join('\n'),
        style: style,
      ),
    );
  }
}

class _SyncedLyrics extends StatefulWidget {
  const _SyncedLyrics({required this.lyrics});

  final Lyrics lyrics;

  @override
  State<_SyncedLyrics> createState() => _SyncedLyricsState();
}

class _SyncedLyricsState extends State<_SyncedLyrics> {
  late final _keys = [for (final _ in widget.lyrics.lines) GlobalKey()];
  StreamSubscription<Duration>? _positionSub;
  int _current = -1;

  /// While the user scrolls, and for a few seconds after, the lyrics stay
  /// where they put them.
  DateTime _holdUntil = DateTime(0);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _positionSub ??= MusicScope.read(context).player.positionStream.listen(_onPosition);
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    super.dispose();
  }

  void _onPosition(Duration position) {
    final line = widget.lyrics.lineAt(position);
    if (line == _current || !mounted) return;
    setState(() => _current = line);
    if (DateTime.now().isAfter(_holdUntil)) _scrollTo(line);
  }

  void _scrollTo(int line) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _keys[line < 0 ? 0 : line].currentContext;
      if (target == null || !mounted) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0.35,
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.read(context);
    final style = Theme.of(context).textTheme.headlineSmall?.copyWith(fontSize: 22, height: 1.3, fontWeight: FontWeight.w700);
    final lyricsList = NotificationListener<UserScrollNotification>(
      onNotification: (notification) {
        if (notification.direction != ScrollDirection.idle) {
          _holdUntil = DateTime.now().add(const Duration(seconds: 4));
        }
        return false;
      },
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 160),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (i, line) in widget.lyrics.lines.indexed)
              InkWell(
                key: _keys[i],
                borderRadius: BorderRadius.circular(10),
                onTap: () => music.player.seek(line.time),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 200),
                    style: style!.copyWith(
                      color: i == _current
                          ? Colors.white
                          : i < _current
                              ? AppColors.textTertiary
                              : AppColors.textSecondary,
                    ),
                    // An instrumental gap, between timed lines.
                    child: Text(line.text.isEmpty ? '♪' : line.text),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return Stack(
      children: [
        Positioned.fill(child: lyricsList),
        Positioned(
          right: 16,
          bottom: 16,
          child: FilledButton.tonalIcon(
            onPressed: () => openKaraoke(context),
            icon: const Icon(Icons.mic_external_on_rounded),
            label: const Text('Karaoke'),
          ),
        ),
      ],
    );
  }
}
