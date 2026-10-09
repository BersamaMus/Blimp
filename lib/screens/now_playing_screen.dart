import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:just_audio/just_audio.dart';

import '../services/desktop_library.dart';
import '../services/lyrics.dart';
import '../services/media_library.dart';
import '../services/music_controller.dart';
import '../theme.dart';
import '../widgets/lyrics_view.dart';
import '../widgets/marquee_text.dart';
import '../widgets/shelf.dart';
import '../widgets/song_artwork.dart';
import '../widgets/song_options.dart';
import '../widgets/visualizer_view.dart';
import '../widgets/volume_control.dart';
import 'app_shell.dart';
import 'artist_screen.dart';
import 'collection_screen.dart';

/// The player's route name, to tell whether it's already open.
const nowPlayingRoute = 'now-playing';

/// Runs [play], then opens the player once the song is queued: opened any
/// sooner, with nothing playing yet, the player would close itself.
Future<void> playAndOpen(BuildContext context, FutureOr<void> Function() play) async {
  await play();
  if (context.mounted) await openNowPlaying(context);
}

Future<void> openNowPlaying(BuildContext context) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder(
      settings: const RouteSettings(name: nowPlayingRoute),
      // Hides and pauses the screens underneath while the player covers
      // them; they're shown again while it's dragged down (see
      // _NowPlayingScreenState._setCovering).
      opaque: true,
      transitionDuration: const Duration(milliseconds: 350),
      reverseTransitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (_, _, _) => const NowPlayingScreen(),
      transitionsBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(animation),
        child: child,
      ),
    ),
  );
}

class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> with SingleTickerProviderStateMixin {
  // Dragging the page down past a threshold dismisses it, like a sheet.
  late final AnimationController _settle = AnimationController(vsync: this, duration: const Duration(milliseconds: 200))
    ..addListener(() => setState(() => _dragOffset = _settleFrom * (1 - _settle.value)))
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) _setCovering(true);
    });
  double _dragOffset = 0;
  double _settleFrom = 0;

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  /// Whether the screens underneath are hidden. Covered, they're neither
  /// painted nor animated (a playing song's bars in a list behind would
  /// otherwise redraw the whole screen every frame); dragging the player
  /// down shows them again. The route does the same around its own
  /// open and close animations.
  void _setCovering(bool covering) {
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent || route.animation?.status != AnimationStatus.completed) return;
    if (route.overlayEntries.isNotEmpty) route.overlayEntries.first.opaque = covering;
  }

  void _onDragEnd(DragEndDetails details) {
    if (_dragOffset > 140 || (details.primaryVelocity ?? 0) > 700) {
      Navigator.pop(context);
    } else {
      _settleFrom = _dragOffset;
      _settle.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.playback});
    final song = music.currentSong;
    if (song == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.maybePop(context);
      });
      return const SizedBox.shrink();
    }

    return GestureDetector(
      onVerticalDragStart: (_) => _setCovering(false),
      onVerticalDragUpdate: (d) => setState(() => _dragOffset = (_dragOffset + d.delta.dy).clamp(0, double.infinity)),
      onVerticalDragEnd: _onDragEnd,
      child: Transform.translate(
        offset: Offset(0, _dragOffset),
        child: FutureBuilder<Color?>(
          future: MediaLibrary.getDominantColor(song.id),
          builder: (context, snapshot) => TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: backdropColor(snapshot.data)),
            duration: const Duration(milliseconds: 500),
            builder: (context, color, child) => DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [color!, Color.lerp(color, Colors.black, 0.75)!],
                ),
              ),
              child: child,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) => _PlayerBody(
                    song: song,
                    wide: DesktopFrame.showsTabs(context) &&
                        constraints.maxWidth > constraints.maxHeight * 1.2,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The player's page: one column on a phone, centred in a narrow window so
/// the controls aren't stretched across it. In a wide window the artwork
/// takes the left half, as tall as the window allows, beside the rest, and
/// Up next, the visualizer and lyrics open under their buttons rather than
/// in a sheet over the player.
class _PlayerBody extends StatefulWidget {
  const _PlayerBody({required this.song, required this.wide});

  final Song song;
  final bool wide;

  @override
  State<_PlayerBody> createState() => _PlayerBodyState();
}

class _PlayerBodyState extends State<_PlayerBody> {
  /// The tab open under the buttons in a wide window, if any.
  int? _panel;

  Widget _panelView(int panel) => switch (panel) {
    0 => const _UpNextList(),
    1 => const VisualizerView(),
    _ => FutureBuilder<Lyrics?>(
      key: ValueKey(widget.song.id),
      future: MediaLibrary.getLyrics(widget.song),
      builder: (context, snapshot) => switch (snapshot.data) {
        final lyrics? => LyricsView(lyrics: lyrics),
        // Moved on to a song without any.
        null when snapshot.connectionState == ConnectionState.done => const MessageView(
          icon: Icons.lyrics_outlined,
          text: 'No lyrics for this song.',
        ),
        null => const SizedBox.shrink(),
      },
    ),
  };

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final wide = widget.wide;
    // Only in a wide window; a narrow one opens the sheet instead.
    final panel = wide ? _panel : null;
    final music = MusicScope.of(context, const {MusicAspect.playback, MusicAspect.library, MusicAspect.settings});
    final player = music.player;
    final textTheme = Theme.of(context).textTheme;
    final album = music.albumOf(song);
    final artists = music.artistsOf(song);

    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.pop(context),
          ),
          const Spacer(),
          const _SpeedButton(),
          const _SleepTimerButton(),
          IconButton(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert),
            onPressed: () => showSongOptions(context, song, inPlayer: true),
          ),
        ],
      ),
    );

    // Artwork: swipe sideways to change song.
    final artwork = Center(
      child: Hero(
        tag: 'now-playing-art',
        child: _SwipeableArtwork(
          player: player,
          songId: song.id,
          child: Container(
            key: ValueKey(song.id),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.large),
              boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 16, offset: Offset(0, 8))],
            ),
            child: _DoubleTapSeek(
              player: player,
              seconds: music.seekSeconds,
              child: SongArtwork(songId: song.id, size: null, radius: AppRadius.large, large: true),
            ),
          ),
        ),
      ),
    );

    final details = [
      // Centered; names too long to fit scroll past like a news ticker.
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          children: [
            MarqueeText(song.title, style: textTheme.headlineSmall?.copyWith(fontSize: 22)),
            const SizedBox(height: 2),
            GestureDetector(
              onTap: artists.isEmpty ? null : () => openArtists(context, artists),
              child: MarqueeText(
                song.artistName,
                style: textTheme.titleMedium?.copyWith(color: AppColors.textSecondary, fontWeight: FontWeight.w400),
              ),
            ),
            if (album?.title ?? song.album case final albumTitle? when albumTitle.isNotEmpty)
              GestureDetector(
                onTap: album == null || album.isSingle ? null : () => openPage(CollectionScreen.album(album)),
                child: MarqueeText(
                  albumTitle,
                  style: textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary.withValues(alpha: 0.8)),
                ),
              ),
            const SizedBox(height: 10),
            _FormatLine(song: song),
          ],
        ),
      ),
      const SizedBox(height: 14),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _FavouritePill(song: song),
          if (album != null && !album.isSingle) ...[
            const SizedBox(width: 8),
            _ActionChip(
              icon: Icons.album_outlined,
              label: 'Album',
              onTap: () => openPage(CollectionScreen.album(album)),
            ),
          ],
        ],
      ),
      const SizedBox(height: 20),
      _SeekBar(player: player),
      const SizedBox(height: 14),
      _Controls(player: player),
      // Phones have volume keys; a desktop window has only this.
      if (isDesktop) ...[
        const SizedBox(height: 8),
        VolumeControl(music: MusicScope.read(context), sliderWidth: 220),
      ],
      SizedBox(height: wide ? 24 : 12),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        // Lyrics only when the song has some.
        child: FutureBuilder<Lyrics?>(
          key: ValueKey(song.id),
          future: MediaLibrary.getLyrics(song),
          builder: (context, snapshot) => Row(
            children: [
              for (final (i, (icon, label)) in [
                (Icons.queue_music_rounded, 'Up next'),
                (Icons.graphic_eq_rounded, 'Visualizer'),
                if (snapshot.data != null) (Icons.lyrics_outlined, 'Lyrics'),
              ].indexed) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: panel == i ? AppColors.accent : Colors.white,
                      backgroundColor: panel == i ? AppColors.accentFaint : const Color(0x14FFFFFF),
                      minimumSize: const Size(0, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    // Pressed again, the open one closes.
                    onPressed: wide
                        ? () => setState(() => _panel = _panel == i ? null : i)
                        : () => _showQueueSheet(context, i),
                    icon: Icon(icon, size: 20),
                    label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      const SizedBox(height: 4),
    ];

    if (wide) {
      return Column(
        children: [
          header,
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Padding(padding: const EdgeInsets.fromLTRB(48, 8, 24, 48), child: artwork),
                ),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Padding(
                        padding: EdgeInsets.only(right: 24, bottom: panel == null ? 48 : 16),
                        // An open tab takes the room under the buttons, which
                        // move up to make it.
                        child: panel == null
                            ? Column(mainAxisSize: MainAxisSize.min, children: details)
                            : Column(
                                children: [
                                  ...details,
                                  const SizedBox(height: 8),
                                  Expanded(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(AppRadius.large),
                                      child: ColoredBox(color: const Color(0x14FFFFFF), child: _panelView(panel)),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          children: [
            header,
            Expanded(
              child: Padding(padding: const EdgeInsets.fromLTRB(24, 16, 24, 8), child: artwork),
            ),
            ...details,
          ],
        ),
      ),
    );
  }
}

/// The artwork follows a sideways drag. Let go far enough (or flick) and it
/// slides off that side while the next or previous song's slides in from the
/// other; otherwise it springs back. With no song that way, it only gives a
/// little, like a rubber band. Songs changed some other way cross-fade.
class _SwipeableArtwork extends StatefulWidget {
  const _SwipeableArtwork({required this.player, required this.songId, required this.child});

  final AudioPlayer player;
  final int songId;
  final Widget child;

  @override
  State<_SwipeableArtwork> createState() => _SwipeableArtworkState();
}

class _SwipeableArtworkState extends State<_SwipeableArtwork> with SingleTickerProviderStateMixin {
  /// How far the artwork is moved sideways, in pixels.
  late final AnimationController _offset = AnimationController.unbounded(vsync: this);

  /// 1 while waiting for the next song after a swipe left, -1 for the
  /// previous after a swipe right, 0 otherwise.
  int _skipping = 0;
  double _width = 1;

  /// Whether the last song change came from a swipe, so it slides in
  /// rather than cross-fading.
  bool _slideIn = false;

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_SwipeableArtwork old) {
    super.didUpdateWidget(old);
    if (old.songId == widget.songId) return;
    _slideIn = _skipping != 0;
    if (_skipping != 0) {
      // In from the side opposite the one the old artwork left by.
      _offset.value = _skipping * _width;
      _offset.animateTo(0, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
      _skipping = 0;
    } else {
      _offset.value = 0;
    }
  }

  bool _canGo(int direction) => direction > 0 ? widget.player.hasNext : widget.player.hasPrevious;

  void _onDragUpdate(DragUpdateDetails details) {
    if (_skipping != 0) return;
    _offset.stop();
    var dx = _offset.value + details.delta.dx;
    // Swiping left (dx < 0) goes to the next song.
    if (!_canGo(dx < 0 ? 1 : -1)) dx = _offset.value + details.delta.dx * 0.3;
    _offset.value = dx;
  }

  void _onDragEnd(DragEndDetails details) {
    if (_skipping != 0) return;
    final velocity = details.primaryVelocity ?? 0;
    final dx = _offset.value;
    final direction = velocity.abs() > 300 ? -velocity.sign.toInt() : (dx.abs() > _width * 0.3 ? -dx.sign.toInt() : 0);
    if (direction == 0 || !_canGo(direction)) {
      _offset.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOutBack);
      return;
    }
    _skipping = direction;
    _offset
        .animateTo(-direction * _width, duration: const Duration(milliseconds: 180), curve: Curves.easeIn)
        .whenComplete(() {
          if (!mounted || _skipping != direction) return;
          direction > 0 ? widget.player.seekToNext() : widget.player.seekToPrevious();
          // If the song didn't change after all, bring the artwork back.
          Future.delayed(const Duration(milliseconds: 600), () {
            if (!mounted || _skipping != direction) return;
            _skipping = 0;
            _offset.value = direction * _width;
            _offset.animateTo(0, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
          });
        });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Off-screen for the artwork means its own width plus the margin.
        _width = constraints.maxWidth + 48;
        return GestureDetector(
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: _onDragEnd,
          child: AnimatedBuilder(
            animation: _offset,
            builder: (context, child) {
              final progress = (_offset.value.abs() / _width).clamp(0.0, 1.0);
              // Shrinks a little as it leaves. (Fading it would be nicer, but
              // Impeller can't fade the shadow under it.)
              return Transform.translate(
                offset: Offset(_offset.value, 0),
                child: Transform.scale(scale: 1 - progress * 0.12, child: child),
              );
            },
            child: AnimatedSwitcher(
              duration: _slideIn ? Duration.zero : const Duration(milliseconds: 250),
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}

/// The file's format, e.g. "MP3 · 320 kbps · 44.1 kHz", with a Hi-Res tag for
/// better-than-CD lossless files. Keeps its height while loading, so the
/// controls below don't jump.
class _FormatLine extends StatelessWidget {
  const _FormatLine({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: AppColors.textSecondary,
      letterSpacing: 0.4,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return SizedBox(
      height: 22,
      child: FutureBuilder<AudioFormat?>(
        future: MediaLibrary.getAudioFormat(song),
        builder: (context, snapshot) {
          final format = snapshot.data;
          final label = format?.label ?? '';
          return AnimatedOpacity(
            opacity: label.isEmpty ? 0 : 1,
            duration: const Duration(milliseconds: 200),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (format?.isHiRes ?? false) ...[const HiResBadge(fontSize: 10), const SizedBox(width: 8)],
                Flexible(
                  child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Double-tap the left or right half of [child] to jump back or forward,
/// showing a brief "10 seconds" bubble.
class _DoubleTapSeek extends StatefulWidget {
  const _DoubleTapSeek({required this.player, required this.seconds, required this.child});

  final AudioPlayer player;
  final int seconds;
  final Widget child;

  @override
  State<_DoubleTapSeek> createState() => _DoubleTapSeekState();
}

class _DoubleTapSeekState extends State<_DoubleTapSeek> {
  /// -1 after seeking back, 1 after seeking forward, 0 when hidden.
  int _direction = 0;
  Offset? _tapPosition;
  int _shownSeconds = 0;
  int _hideToken = 0;

  void _seek(double width) {
    final tap = _tapPosition;
    if (tap == null) return;
    final direction = tap.dx < width / 2 ? -1 : 1;
    final player = widget.player;
    final duration = player.duration ?? Duration.zero;
    var target = player.position + Duration(seconds: widget.seconds * direction);
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    player.seek(target);

    // Repeated double-taps on the same side add up.
    final token = ++_hideToken;
    setState(() {
      _shownSeconds = _direction == direction ? _shownSeconds + widget.seconds : widget.seconds;
      _direction = direction;
    });
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted && token == _hideToken) setState(() => _direction = 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        onDoubleTapDown: (details) => _tapPosition = details.localPosition,
        onDoubleTap: () => _seek(constraints.maxWidth),
        child: Stack(
          alignment: Alignment.center,
          children: [
            widget.child,
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _direction == 0 ? 0 : 1,
                  duration: const Duration(milliseconds: 150),
                  child: Align(
                    alignment: _direction < 0 ? const Alignment(-0.6, 0) : const Alignment(0.6, 0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(24)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_direction < 0 ? Icons.fast_rewind : Icons.fast_forward, size: 20),
                          const SizedBox(width: 6),
                          Text('$_shownSeconds seconds', style: const TextStyle(fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FavouritePill extends StatelessWidget {
  const _FavouritePill({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.favourites});
    final favourite = music.isFavourite(song);
    return _ActionChip(
      icon: favourite ? Icons.favorite : Icons.favorite_border,
      iconColor: favourite ? AppColors.favourite : null,
      label: favourite ? 'Favourited' : 'Favourite',
      onTap: () => music.toggleFavourite(song),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({required this.icon, required this.label, required this.onTap, this.iconColor});

  final IconData icon;
  final Color? iconColor;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0x1FFFFFFF),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: iconColor),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.player});

  final AudioPlayer player;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> with SingleTickerProviderStateMixin {
  /// Where the thumb is while being dragged, so it doesn't jump back.
  double? _dragValue;

  /// Where the song is. While it plays this moves every frame, at the
  /// screen's own refresh rate, rather than with the player's few updates a
  /// second; the player works out where it is between them. The ticker stops
  /// when paused, and Flutter mutes it while the player is out of sight.
  Duration _position = Duration.zero;
  late final Ticker _ticker = createTicker((_) => _refresh());
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _positionSub;

  @override
  void initState() {
    super.initState();
    _position = widget.player.position;
    _playingSub = widget.player.playingStream.listen((playing) {
      if (playing && !_ticker.isActive) _ticker.start();
      if (!playing && _ticker.isActive) _ticker.stop();
      _refresh();
    });
    // Seeks and song changes while paused.
    _positionSub = widget.player.positionStream.listen((_) {
      if (!_ticker.isActive) _refresh();
    });
  }

  void _refresh() {
    final position = widget.player.position;
    if (position != _position && mounted) setState(() => _position = position);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _playingSub?.cancel();
    _positionSub?.cancel();
    super.dispose();
  }

  /// The song whose waveform is showing, while the waveform seek bar is on;
  /// its [_levels] once loaded, and whether it couldn't be.
  int? _waveformSongId;
  Uint8List? _levels;
  bool _waveformFailed = false;

  /// Starts on [songId]'s waveform: straight away if it's been loaded
  /// lately, otherwise loading meanwhile. Only that song's result is taken,
  /// so a slow one for the song before never shows.
  void _loadWaveform(int? songId) {
    _waveformSongId = songId;
    _levels = songId == null ? null : MediaLibrary.cachedWaveform(songId);
    _waveformFailed = false;
    if (songId == null || _levels != null) return;
    MediaLibrary.getWaveform(songId).then((levels) {
      if (!mounted || _waveformSongId != songId) return;
      setState(() {
        _levels = levels;
        _waveformFailed = levels == null;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context).textTheme.bodySmall;
    final music = MusicScope.of(context, const {MusicAspect.playback, MusicAspect.settings});
    final songId = music.waveformSeekBar ? music.currentSong?.id : null;
    if (songId != _waveformSongId) _loadWaveform(songId);

    return Builder(
      builder: (context) {
        final duration = widget.player.duration ?? Duration.zero;
        final max = duration.inMilliseconds.toDouble();
        final position = _position.inMilliseconds.clamp(0, max).toDouble();
        final value = _dragValue ?? position;
        void onChanged(double v) => setState(() => _dragValue = v);
        void onChangeEnd(double v) {
          widget.player.seek(Duration(milliseconds: v.round()));
          setState(() => _dragValue = null);
        }

        final slider = Slider(
          value: max > 0 ? value.clamp(0, max) : 0,
          max: max > 0 ? max : 1,
          onChanged: max > 0 ? onChanged : null,
          onChangeEnd: onChangeEnd,
          // Read out as a time, not a percentage.
          semanticFormatterCallback: (v) =>
              '${formatDuration(Duration(milliseconds: v.round()))} of ${formatDuration(duration)}',
        );

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              // The same height either way, so switching style moves nothing.
              child: SizedBox(
                height: _Waveform.height,
                // The plain slider if the waveform can't be read; while it
                // loads, the waveform's loading ripple.
                child: _waveformSongId == null || _waveformFailed
                    ? slider
                    : seekSemantics(
                        position: Duration(milliseconds: value.round()),
                        duration: duration,
                        onSeek: widget.player.seek,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          child: _Waveform(
                            key: ValueKey(_levels == null ? null : _waveformSongId),
                            levels: _levels,
                            fraction: max > 0 ? value.clamp(0, max) / max : 0,
                            onChanged: (f) => max > 0 ? onChanged(f * max) : null,
                            onChangeEnd: (f) => max > 0 ? onChangeEnd(f * max) : null,
                          ),
                        ),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(formatDuration(Duration(milliseconds: value.round())), style: labelStyle),
                  _SeekBarStyleToggle(waveform: music.waveformSeekBar, onChanged: music.setWaveformSeekBar),
                  Text(formatDuration(duration), style: labelStyle),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.player});

  final AudioPlayer player;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        StreamBuilder<bool>(
          stream: MusicScope.read(context).shufflingStream,
          initialData: MusicScope.read(context).shuffling,
          builder: (context, snapshot) {
            final enabled = snapshot.data ?? false;
            return IconButton(
              tooltip: enabled ? 'Shuffle: on' : 'Shuffle: off',
              icon: const Icon(Icons.shuffle_rounded),
              color: enabled ? AppColors.accent : AppColors.textTertiary,
              onPressed: MusicScope.read(context).toggleShuffle,
            );
          },
        ),
        IconButton(
          iconSize: 42,
          tooltip: 'Previous',
          icon: const Icon(Icons.skip_previous_rounded),
          onPressed: MusicScope.read(context).skipToPrevious,
        ),
        StreamBuilder<PlayerState>(
          stream: player.playerStateStream,
          initialData: player.playerState,
          builder: (context, snapshot) {
            final state = snapshot.data;
            final playing = state?.playing ?? false;
            final buffering =
                state?.processingState == ProcessingState.loading ||
                state?.processingState == ProcessingState.buffering;
            return SizedBox.square(
              dimension: 76,
              child: Material(
                color: AppColors.accent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: playing ? player.pause : player.play,
                  child: buffering
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: AppColors.onAccent,
                            semanticsLabel: playing ? 'Loading, pause' : 'Loading, play',
                          ),
                        )
                      : Icon(
                          playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          size: 44,
                          color: AppColors.onAccent,
                          semanticLabel: playing ? 'Pause' : 'Play',
                        ),
                ),
              ),
            );
          },
        ),
        IconButton(
          iconSize: 42,
          tooltip: 'Next',
          icon: const Icon(Icons.skip_next_rounded),
          onPressed: player.hasNext ? player.seekToNext : null,
        ),
        StreamBuilder<LoopMode>(
          stream: player.loopModeStream,
          initialData: player.loopMode,
          builder: (context, snapshot) {
            final mode = snapshot.data ?? LoopMode.off;
            return IconButton(
              tooltip: switch (mode) {
                LoopMode.off => 'Repeat: off',
                LoopMode.all => 'Repeat: all',
                LoopMode.one => 'Repeat: this song',
              },
              icon: Icon(mode == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded),
              color: mode == LoopMode.off ? AppColors.textTertiary : AppColors.accent,
              onPressed: () => player.setLoopMode(switch (mode) {
                LoopMode.off => LoopMode.all,
                LoopMode.all => LoopMode.one,
                LoopMode.one => LoopMode.off,
              }),
            );
          },
        ),
      ],
    );
  }
}

/// "12:34" or "1:02:03".
String _formatCountdown(Duration d) {
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (d.inHours == 0) return '${d.inMinutes}:$seconds';
  return '${d.inHours}:${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:$seconds';
}

/// Time left until [MusicController.sleepAt], ticking each second; empty
/// when the timer waits for the song's end instead.
Widget _sleepCountdown(MusicController music, Widget Function(String left) builder) {
  final at = music.sleepAt;
  if (at == null) return builder('');
  return StreamBuilder(
    stream: Stream<void>.periodic(const Duration(seconds: 1)),
    builder: (_, _) {
      final left = at.difference(DateTime.now());
      return builder(_formatCountdown(left.isNegative ? Duration.zero : left));
    },
  );
}

/// The speed, lit, while songs play faster or slower than normal. The speed
/// is kept between sessions, so this is the reminder that it's still on.
class _SpeedButton extends StatelessWidget {
  const _SpeedButton();

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.settings});
    if (music.speed == 1) return const SizedBox.shrink();
    return Semantics(
      label: 'Playback speed ${formatSpeed(music.speed)}',
      button: true,
      excludeSemantics: true,
      child: TextButton.icon(
        onPressed: () => showSpeedPicker(context),
        icon: Icon(Icons.speed_rounded, color: AppColors.accent),
        label: Text(
          formatSpeed(music.speed),
          style: TextStyle(color: AppColors.accent, fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ),
    );
  }
}

/// The player's moon button: lit, with the time left, while the timer runs.
class _SleepTimerButton extends StatelessWidget {
  const _SleepTimerButton();

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.playback});
    final on = music.sleepTimerOn;
    final icon = Icon(on ? Icons.bedtime_rounded : Icons.bedtime_outlined, color: on ? AppColors.accent : null);
    if (!on) {
      return IconButton(tooltip: 'Sleep timer', icon: icon, onPressed: () => _showSleepTimerSheet(context));
    }
    return TextButton.icon(
      onPressed: () => _showSleepTimerSheet(context),
      icon: icon,
      label: _sleepCountdown(
        music,
        (left) => Text(
          music.sleepAtEndOfSong ? 'End of song' : left,
          style: TextStyle(color: AppColors.accent, fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ),
    );
  }
}

void _showSleepTimerSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _SleepTimerSheet(),
  );
}

class _SleepTimerSheet extends StatelessWidget {
  const _SleepTimerSheet();

  static const _minutes = [5, 10, 15, 30, 45, 60, 90];

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.playback});
    final textTheme = Theme.of(context).textTheme;

    void pick(VoidCallback set) {
      set();
      Navigator.pop(context);
    }

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text('Sleep timer', style: textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: music.sleepAtEndOfSong
                  ? Text('Pausing when this song ends', style: textTheme.bodyMedium)
                  : _sleepCountdown(
                      music,
                      (left) => Text(
                        left.isEmpty ? 'Pause the music after a while' : 'Pausing in $left',
                        style: textTheme.bodyMedium,
                      ),
                    ),
            ),
            if (music.sleepTimerOn)
              ListTile(
                leading: const Icon(Icons.timer_off_outlined, color: AppColors.danger),
                title: Text('Turn off timer', style: textTheme.bodyLarge?.copyWith(color: AppColors.danger)),
                onTap: () => pick(music.cancelSleepTimer),
              ),
            for (final minutes in _minutes)
              ListTile(
                leading: const Icon(Icons.timer_outlined, color: AppColors.textSecondary),
                title: Text(
                  minutes < 60
                      ? '$minutes minutes'
                      : minutes == 60
                      ? '1 hour'
                      : '${minutes ~/ 60} h ${minutes % 60} min',
                ),
                onTap: () => pick(() => music.setSleepTimer(Duration(minutes: minutes))),
              ),
            ListTile(
              leading: const Icon(Icons.music_off_outlined, color: AppColors.textSecondary),
              title: const Text('End of song'),
              trailing: music.sleepAtEndOfSong ? Icon(Icons.check_rounded, color: AppColors.accent) : null,
              onTap: () => pick(music.setSleepAtEndOfSong),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

void _showQueueSheet(BuildContext context, int initialTab) {
  showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
    builder: (_) => _PlayerSheet(initialTab: initialTab),
  );
}

/// Up next, the visualizer and, when the playing song has some, its lyrics,
/// as tabs under the sheet's controls. The Lyrics tab comes and goes as the
/// song changes; the tab in view stays put where it can.
class _PlayerSheet extends StatefulWidget {
  const _PlayerSheet({required this.initialTab});

  final int initialTab;

  @override
  State<_PlayerSheet> createState() => _PlayerSheetState();
}

class _PlayerSheetState extends State<_PlayerSheet> with TickerProviderStateMixin {
  TabController? _tabs;
  late int _index = widget.initialTab;

  /// Whether the Lyrics tab is showing; opened on it, it's there from the start.
  late bool _hadLyrics = widget.initialTab == 2;

  @override
  void dispose() {
    _tabs?.dispose();
    super.dispose();
  }

  TabController _controllerFor(int length) {
    final tabs = _tabs;
    if (tabs != null && tabs.length == length) return tabs;
    tabs?.dispose();
    return _tabs = TabController(length: length, initialIndex: _index.clamp(0, length - 1), vsync: this)
      ..addListener(() => _index = _tabs!.index);
  }

  @override
  Widget build(BuildContext context) {
    final song = MusicScope.of(context, const {MusicAspect.playback}).currentSong;
    return FutureBuilder<Lyrics?>(
      // Per song, so one song's lyrics never show for the next.
      key: ValueKey(song?.id),
      future: song == null ? null : MediaLibrary.getLyrics(song),
      builder: (context, snapshot) {
        final lyrics = snapshot.data;
        // While the next song's lyrics load, the tabs stay as they were.
        final loading = snapshot.connectionState == ConnectionState.waiting;
        if (!loading) _hadLyrics = lyrics != null;
        final tabs = _controllerFor(_hadLyrics ? 3 : 2);
        return Column(
          children: [
            const _SheetControls(),
            TabBar(
              controller: tabs,
              indicatorSize: TabBarIndicatorSize.label,
              labelStyle: const TextStyle(fontWeight: FontWeight.w700),
              tabs: [
                const Tab(text: 'Up next'),
                const Tab(text: 'Visualizer'),
                if (_hadLyrics) const Tab(text: 'Lyrics'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: tabs,
                children: [
                  const _UpNextList(),
                  const VisualizerView(),
                  if (_hadLyrics) lyrics == null ? const SizedBox.shrink() : LyricsView(lyrics: lyrics),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The song's title and artist with previous, play/pause, next and the seek
/// bar, under the Up next / Visualizer sheet's handle, since the sheet covers
/// the player.
class _SheetControls extends StatelessWidget {
  const _SheetControls();

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.playback, MusicAspect.library});
    final player = music.player;
    final song = music.currentSong;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          if (song != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 4),
              child: Column(
                children: [
                  MarqueeText(song.title, style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  HiResLine(
                    hiRes: music.isHiRes(song),
                    center: true,
                    line: MarqueeText(
                      song.artistName,
                      style: textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                iconSize: 34,
                tooltip: 'Previous',
                icon: const Icon(Icons.skip_previous_rounded),
                onPressed: MusicScope.read(context).skipToPrevious,
              ),
              const SizedBox(width: 20),
              StreamBuilder<bool>(
                stream: player.playingStream,
                builder: (context, snapshot) {
                  final playing = snapshot.data ?? player.playing;
                  return SizedBox.square(
                    dimension: 52,
                    child: Material(
                      color: AppColors.accent,
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: playing ? player.pause : player.play,
                        child: Icon(
                          playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          size: 32,
                          color: AppColors.onAccent,
                          semanticLabel: playing ? 'Pause' : 'Play',
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(width: 20),
              IconButton(
                iconSize: 34,
                tooltip: 'Next',
                icon: const Icon(Icons.skip_next_rounded),
                onPressed: player.hasNext ? player.seekToNext : null,
              ),
            ],
          ),
          _SeekBar(player: player),
        ],
      ),
    );
  }
}

/// The queue in play order, then autoplay's switch with its songs under it.
/// Only the user's own songs can be reordered, shuffled or not.
class _UpNextList extends StatelessWidget {
  const _UpNextList();

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.playback, MusicAspect.library, MusicAspect.settings});
    final player = music.player;
    final state = player.sequenceState;
    final queue = state.effectiveSequence;
    final current = state.currentSource;
    final textTheme = Theme.of(context).textTheme;

    // Sequence positions in play order, so taps and removals hit the right item.
    final order = state.shuffleModeEnabled ? state.shuffleIndices : [for (var i = 0; i < queue.length; i++) i];

    // Autoplay's songs at the end are listed under its switch.
    var split = queue.length;
    while (split > 0 && MusicController.isAutoplay(queue[split - 1])) {
      split--;
    }

    Widget tile(int i, {bool reorderable = true}) {
      final isCurrent = queue[i] == current;
      final song = music.songOf(queue[i]);
      // A song removed by a rescan while still queued.
      if (song == null) return SizedBox.shrink(key: ValueKey(queue[i]));
      return Dismissible(
        key: ValueKey(queue[i]),
        direction: isCurrent ? DismissDirection.none : DismissDirection.endToStart,
        background: Container(
          color: AppColors.danger,
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 24),
          child: const Icon(Icons.delete_outline),
        ),
        onDismissed: (_) => player.removeAudioSourceAt(order[i]),
        child: Material(
          color: isCurrent ? AppColors.accentFaint : Colors.transparent,
          child: ListTile(
            onTap: () => player.seek(Duration.zero, index: order[i]),
            leading: SongArtwork(songId: song.id, size: 48, radius: 10),
            title: Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodyLarge?.copyWith(color: isCurrent ? AppColors.accent : null),
            ),
            subtitle: HiResLine(
              hiRes: music.isHiRes(song),
              line: Text(song.artistName, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            trailing: !reorderable
                ? null
                : ReorderableDragStartListener(
                    index: i,
                    child: const Icon(Icons.drag_handle, color: AppColors.textSecondary),
                  ),
          ),
        ),
      );
    }

    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      itemCount: split,
      onReorderItem: music.moveInQueue,
      itemBuilder: (context, i) => tile(i),
      footer: Column(
        children: [
          _AutoplayHeader(
            enabled: music.autoplay,
            repeating: player.loopMode != LoopMode.off,
            onChanged: music.setAutoplay,
          ),
          for (var i = split; i < queue.length; i++) tile(i, reorderable: false),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// Autoplay's switch, between the queue and the songs autoplay added.
class _AutoplayHeader extends StatelessWidget {
  const _AutoplayHeader({required this.enabled, required this.repeating, required this.onChanged});

  final bool enabled;

  /// Repeat is on, so autoplay holds off: the queue never ends.
  final bool repeating;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: [
          Icon(Icons.all_inclusive_rounded, color: AppColors.accent),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Autoplay', style: textTheme.titleMedium),
                Text(switch ((enabled, repeating)) {
                  (false, _) => 'Playback stops when your queue ends',
                  (true, true) => 'Paused while repeat is on',
                  (true, false) => 'Similar songs play when your queue ends',
                }, style: textTheme.bodySmall),
              ],
            ),
          ),
          Switch(value: enabled, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// The waveform seek bar: the song's loudness as bars mirrored about a
/// centre line, played in the theme's colour and still to come in grey, with
/// a playhead. Tap or drag along it to seek; [fraction] is how far through
/// the song it is, 0..1, and the callbacks get the same.
///
/// While [levels] is null (the waveform is still loading) the bars lie flat
/// with a ripple running out from the middle; seeking still works.
class _Waveform extends StatefulWidget {
  const _Waveform({
    super.key,
    required this.levels,
    required this.fraction,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final Uint8List? levels;
  final double fraction;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  /// The same height as the slider it stands in for, so nothing moves.
  static const height = 48.0;

  @override
  State<_Waveform> createState() => _WaveformState();
}

class _WaveformState extends State<_Waveform> with SingleTickerProviderStateMixin {
  /// Runs the loading ripple; idle once the waveform's there.
  late final _ripple = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void initState() {
    super.initState();
    _syncRipple();
  }

  @override
  void didUpdateWidget(_Waveform old) {
    super.didUpdateWidget(old);
    _syncRipple();
  }

  void _syncRipple() {
    if (widget.levels == null && !_ripple.isAnimating) {
      _ripple.repeat();
    } else if (widget.levels != null && _ripple.isAnimating) {
      _ripple.stop();
    }
  }

  @override
  void dispose() {
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Inset like the slider's track, so the ends line up with the times.
        const inset = 14.0;
        final width = constraints.maxWidth - inset * 2;
        double at(Offset local) => ((local.dx - inset) / width).clamp(0.0, 1.0);
        var last = widget.fraction;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => widget.onChanged(last = at(d.localPosition)),
          onTapUp: (_) => widget.onChangeEnd(last),
          onHorizontalDragStart: (d) => widget.onChanged(last = at(d.localPosition)),
          onHorizontalDragUpdate: (d) => widget.onChanged(last = at(d.localPosition)),
          onHorizontalDragEnd: (_) => widget.onChangeEnd(last),
          child: SizedBox(
            height: _Waveform.height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: inset),
              child: CustomPaint(
                size: Size.infinite,
                painter: _WaveformPainter(widget.levels, widget.fraction, AppColors.accent, _ripple),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter(this.levels, this.fraction, this.accent, this.ripple) : super(repaint: ripple);

  /// Null while loading.
  final Uint8List? levels;
  final double fraction;
  final Color accent;
  final Animation<double> ripple;

  /// The heights of the loading ripple's bars, 0..1: flat, with waves
  /// running out from the middle and fading towards the ends.
  static List<double> _rippleLevels(int count, double phase) => [
    for (var i = 0; i < count; i++)
      if (((i + 0.5) / count - 0.5).abs() * 2 case final fromMiddle)
        0.08 + 0.5 * pow(1 - fromMiddle, 2) * max(0.0, sin(2 * pi * phase - fromMiddle * 9)),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final levels = this.levels;
    final count = levels?.length ?? MediaLibrary.waveformPoints;
    final step = size.width / count;
    final barWidth = step * 0.6;
    final centerY = size.height / 2;
    final played = size.width * fraction;
    final playedPaint = Paint()
      ..color = accent
      ..strokeWidth = barWidth
      ..strokeCap = StrokeCap.round;
    final restPaint = Paint()
      ..color = const Color(0x40FFFFFF)
      ..strokeWidth = barWidth
      ..strokeCap = StrokeCap.round;

    final heights = levels == null ? _rippleLevels(count, ripple.value) : _heights(levels);
    for (var i = 0; i < count; i++) {
      final x = (i + 0.5) * step;
      final half = max(1.5, heights[i] * (centerY - barWidth / 2));
      canvas.drawLine(Offset(x, centerY - half), Offset(x, centerY + half), x <= played ? playedPaint : restPaint);
    }

    // The playhead.
    canvas.drawLine(
      Offset(played, 2),
      Offset(played, size.height - 2),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.fraction != fraction || !identical(old.levels, levels) || old.accent != accent;

  /// Bar heights, 0..1, for a song's [levels]. Most songs are loud nearly
  /// all the way through, so heights are spread between the quieter passages
  /// (the tenth percentile) and the loudest, rather than from silence: the
  /// shape of the song shows.
  static List<double> _heights(Uint8List levels) {
    final quiet = (levels.toList()..sort())[levels.length ~/ 10] / 255;
    return [
      for (final level in levels) 0.15 + 0.85 * pow(((level / 255 - quiet) / (1 - quiet + 1e-6)).clamp(0.0, 1.0), 1.2),
    ];
  }
}

/// Switches the seek bar between the plain slider and the waveform: two
/// small icons in a pill, the one in use highlighted. The same setting as
/// in Settings > Playback.
class _SeekBarStyleToggle extends StatelessWidget {
  const _SeekBarStyleToggle({required this.waveform, required this.onChanged});

  final bool waveform;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget option(bool isWaveform, IconData icon, String tooltip) {
      final selected = isWaveform == waveform;
      return Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: selected ? null : () => onChanged(isWaveform),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: selected ? AppColors.accentSoft : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 16, color: selected ? AppColors.accent : AppColors.textTertiary),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: const Color(0x14FFFFFF), borderRadius: BorderRadius.circular(14)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          option(false, Icons.horizontal_rule_rounded, 'Slider'),
          option(true, Icons.graphic_eq_rounded, 'Waveform'),
        ],
      ),
    );
  }
}
