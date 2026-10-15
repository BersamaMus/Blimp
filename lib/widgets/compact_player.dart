import 'package:flutter/material.dart';

import '../services/desktop_window.dart';
import '../services/music_controller.dart';
import '../theme.dart';
import 'marquee_text.dart';
import 'song_artwork.dart';

/// Around the desktop app: in the compact player, shows [CompactPlayer] in
/// the small window instead. The app stays as it was underneath, laid out
/// at the window's old size, so it comes back just as it was left.
class CompactWindow extends StatefulWidget {
  const CompactWindow({super.key, required this.child});

  final Widget child;

  @override
  State<CompactWindow> createState() => _CompactWindowState();
}

class _CompactWindowState extends State<CompactWindow> {
  /// The window's size before it went compact.
  Size _normal = const Size(1180, 800);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return ValueListenableBuilder(
      valueListenable: DesktopWindow.compact,
      builder: (context, compact, _) => LayoutBuilder(
        builder: (context, constraints) {
          if (!compact) _normal = constraints.biggest;
          return Stack(
            fit: StackFit.expand,
            children: [
              // The same widgets either way, so the app isn't rebuilt.
              Offstage(
                offstage: compact,
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: _normal.width,
                  maxWidth: _normal.width,
                  minHeight: _normal.height,
                  maxHeight: _normal.height,
                  child: MediaQuery(
                    data: media.copyWith(size: _normal),
                    child: TickerMode(enabled: !compact, child: widget.child),
                  ),
                ),
              ),
              // Its own overlay, for the buttons' tooltips: it's outside the
              // app's navigator.
              if (compact) Positioned.fill(child: Overlay.wrap(child: const CompactPlayer())),
            ],
          );
        },
      ),
    );
  }
}

/// The compact player: the song, its cover, and the buttons, in a small
/// window kept above others.
class CompactPlayer extends StatelessWidget {
  const CompactPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.playback, MusicAspect.library});
    final player = music.player;
    final song = music.currentSong;
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: AppColors.surfaceHigh,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final art = constraints.maxHeight - 3;
          return Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    if (song != null)
                      SongArtwork(songId: song.id, size: art, radius: 0)
                    else
                      SizedBox.square(dimension: art, child: const Icon(Icons.music_note_rounded)),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: MarqueeText(
                                    song?.title ?? 'Nothing playing',
                                    textAlign: TextAlign.start,
                                    style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  // Not 18: at that size Windows drew the icon well to the
                                  // right of its button, out of reach of the clicks it takes.
                                  iconSize: 20,
                                  tooltip: 'Back to full window',
                                  icon: const Icon(Icons.open_in_full_rounded),
                                  onPressed: () => DesktopWindow.setCompact(false),
                                ),
                              ],
                            ),
                            if (song != null)
                              MarqueeText(song.artistName, textAlign: TextAlign.start, style: textTheme.bodyMedium),
                            const Spacer(),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                IconButton(
                                  tooltip: 'Previous',
                                  icon: const Icon(Icons.skip_previous_rounded),
                                  onPressed: song == null ? null : music.skipToPrevious,
                                ),
                                StreamBuilder<bool>(
                                  stream: player.playingStream,
                                  initialData: player.playing,
                                  builder: (context, snapshot) {
                                    final playing = snapshot.data ?? false;
                                    return IconButton.filled(
                                      tooltip: playing ? 'Pause' : 'Play',
                                      icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                                      onPressed: song == null ? null : (playing ? player.pause : player.play),
                                    );
                                  },
                                ),
                                IconButton(
                                  tooltip: 'Next',
                                  icon: const Icon(Icons.skip_next_rounded),
                                  onPressed: player.hasNext ? player.seekToNext : null,
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _Progress(music: music),
            ],
          );
        },
      ),
    );
  }
}

/// How far through the song it is, as a thin line along the bottom.
class _Progress extends StatelessWidget {
  const _Progress({required this.music});

  final MusicController music;

  @override
  Widget build(BuildContext context) {
    final player = music.player;
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (context, snapshot) {
        final total = player.duration?.inMilliseconds ?? 0;
        final at = (snapshot.data ?? player.position).inMilliseconds;
        return LinearProgressIndicator(
          minHeight: 3,
          value: total <= 0 ? 0 : (at / total).clamp(0.0, 1.0),
          color: AppColors.accent,
          backgroundColor: AppColors.surface,
        );
      },
    );
  }
}
