import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/desktop_library.dart';
import '../services/media_library.dart';
import '../services/music_controller.dart';
import '../services/visualizer.dart';
import '../theme.dart';

const _bandCount = 48;

/// Bands for the Bars and Mirror styles, finer than [_bandCount] so they
/// show more detail.
const _fineBandCount = 96;
const _wavePoints = 96;

/// Draws the playing song as a visualizer in the style picked from the
/// dropdown underneath, coloured by the song's genre.
///
/// It needs the microphone permission Android requires for reading the
/// audio; until that's granted (or if the device refuses) it shows a message
/// instead, and nothing runs.
class VisualizerView extends StatefulWidget {
  const VisualizerView({super.key});

  @override
  State<VisualizerView> createState() => _VisualizerViewState();
}

class _VisualizerViewState extends State<VisualizerView> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _signal = _Signal();
  late final Ticker _ticker = createTicker(_onTick);
  Duration _lastTick = Duration.zero;

  PermissionStatus? _permission;
  bool _unavailable = false;
  StreamSubscription<int?>? _sessionSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<AudioFrame>? _framesSub;
  Float64List? _bandTargets;
  Float64List? _fineTargets;

  /// Whether music is playing and whether the volume is all the way down,
  /// for the note that the visualizer can't move without sound.
  bool _playing = false;
  bool _volumeOff = false;
  Float64List? _waveTargets;

  /// Windows: whether this version captures everything the PC plays rather
  /// than just Blimp, for a note saying so.
  bool _wholePc = false;

  MusicController? _musicOrNull;
  MusicController get _music => _musicOrNull!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermission();
  }


  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final first = _musicOrNull == null;
    _musicOrNull = MusicScope.read(context);
    if (first) _sync();
  }

  /// Whether there's a visualizer to draw: switched on, allowed, and the
  /// device shares its audio.
  bool get _showing =>
      _appVisible && (_musicOrNull?.visualizerEnabled ?? false) && (_permission?.isGranted ?? false) && !_unavailable;

  /// False while the app is in the background or the screen is off. Frames
  /// stop then anyway, but the audio capture wouldn't.
  bool _appVisible = true;

  /// Animates and reads the audio only while the visualizer is showing, so
  /// when it isn't, it costs nothing.
  void _sync() {
    if (_showing) {
      _startTicker();
      if (_playingSub == null) _startLive();
    } else {
      _stopTicker();
      _stopLive();
      // Start from silence when shown again.
      _signal.clear();
    }
  }

  void _onSwitch(bool on) {
    _music.setVisualizerEnabled(on);
    _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopTicker();
    _ticker.dispose();
    _stopLive();
    _signal.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _appVisible = true;
        // Back from system settings, the permission may have been granted.
        if (_permission?.isGranted != true) _checkPermission();
        _sync();
      case AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached:
        _appVisible = false;
        _sync();
      // Briefly covered, e.g. by the permission dialog: keep going.
      case AppLifecycleState.inactive:
        break;
    }
  }

  // Windows asks for no permission to read what Blimp plays.
  Future<void> _checkPermission() =>
      _onPermission(isDesktop ? Future.value(PermissionStatus.granted) : Permission.microphone.status);

  Future<void> _requestPermission() async {
    if (_permission?.isPermanentlyDenied ?? false) {
      await openAppSettings();
    } else {
      await _onPermission(Permission.microphone.request());
    }
  }

  Future<void> _onPermission(Future<PermissionStatus> status) async {
    final result = await status;
    if (!mounted) return;
    setState(() => _permission = result);
    _sync();
  }

  /// Runs the animation, in step with the screen.
  void _startTicker() {
    if (_running) return;
    // A restarted clock counts from zero again.
    _lastTick = Duration.zero;
    _wasIdle = false;
    _ticker.start();
  }

  void _stopTicker() => _ticker.stop();

  bool get _running => _ticker.isActive;

  /// Follows the player's audio session, which Android can replace between
  /// songs, and listens to whatever it outputs.
  void _startLive() {
    // The ticker stops once paused music has come to rest; playing again
    // wakes it.
    _playingSub = _music.player.playingStream.listen((playing) {
      if (playing && _showing) _startTicker();
      if (playing != _playing && mounted) setState(() => _playing = playing);
    });
    // Windows captures what Blimp plays, whatever its session; the in-app
    // volume stands in for Android's volume step.
    if (isDesktop) {
      _framesSub = audioFrames(0, volume: () => (_music.volume.value * 100).round()).listen(_onFrame, onError: _onError);
      return;
    }
    _sessionSub = _music.player.androidAudioSessionIdStream.listen((session) {
      _framesSub?.cancel();
      _framesSub = null;
      if (session == null) return;
      _framesSub = audioFrames(session).listen(_onFrame, onError: _onError);
    });
  }

  void _onFrame(AudioFrame frame) {
    _bandTargets = frame.bands;
    _fineTargets = frame.fineBands;
    _waveTargets = frame.wave;
    _signal.onCapture(frame.bands);
    final volumeOff = frame.volume == 0;
    if ((volumeOff != _volumeOff || frame.wholePc != _wholePc) && mounted) {
      setState(() {
        _volumeOff = volumeOff;
        _wholePc = frame.wholePc;
      });
    }
  }

  void _onError(Object _) {
    if (!mounted) return;
    setState(() => _unavailable = true);
    _sync();
  }

  void _stopLive() {
    _playingSub?.cancel();
    _sessionSub?.cancel();
    _framesSub?.cancel();
    _playingSub = null;
    _sessionSub = null;
    _framesSub = null;
    _bandTargets = null;
    _fineTargets = null;
    _waveTargets = null;
    // Not setState: this runs from dispose too, and _sync's callers rebuild.
    _playing = false;
    _volumeOff = false;
  }

  void _onTick(Duration elapsed) {
    final dt = ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _lastTick = elapsed;
    _signal
      ..update(dt, _bandTargets, _fineTargets, _waveTargets)
      ..time = elapsed.inMicroseconds / 1e6;

    final (low, high) = _colors();
    _signal.low = Color.lerp(_signal.low, low, min(1, 3 * dt))!;
    _signal.high = Color.lerp(_signal.high, high, min(1, 3 * dt))!;

    // Paused and come to rest: draw the empty frame once, then stop until
    // the music plays again. A running ticker alone makes Flutter redraw the
    // whole screen every frame.
    final idle = _signal.settled && !_music.player.playing;
    if (idle && _wasIdle) return _stopTicker();
    _wasIdle = idle;
    _signal.tick();
  }

  bool _wasIdle = false;

  /// The song whose artwork colours are loaded or loading, and the colours
  /// (null for artwork without any).
  int? _paletteSong;
  bool _paletteLoaded = false;
  (Color, Color)? _palette;

  /// The colours to ease towards: the artwork's when chosen and it has some,
  /// otherwise the genre's. While the artwork's load, the colours stay put.
  (Color, Color) _colors() {
    final song = _music.currentSong;
    final genreColors = visualizerColors(song?.genre);
    if (!_music.visualizerArtworkColors || song == null) return genreColors;
    if (_paletteSong != song.id) {
      _paletteSong = song.id;
      _paletteLoaded = false;
      MediaLibrary.getArtworkColors(song.id).then((colors) {
        if (_paletteSong != song.id) return;
        _palette = colors;
        _paletteLoaded = true;
      });
    }
    if (!_paletteLoaded) return (_signal.low, _signal.high);
    return _palette ?? genreColors;
  }

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.playback, MusicAspect.settings});
    final genre = music.currentSong?.genre;
    final style = music.visualizerStyle;
    _signal.style = style;
    final permission = _permission;
    final enabled = music.visualizerEnabled;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 12, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(enabled ? 'On' : 'Off', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(width: 8),
              Switch(value: enabled, onChanged: _onSwitch),
            ],
          ),
        ),
        if (!enabled)
          const Expanded(
            child: _Message(title: 'Visualizer is off', text: 'Switch it on to see your music move.'),
          )
        // Still checking the permission.
        else if (permission == null)
          const Spacer()
        else if (!permission.isGranted)
          Expanded(
            child: _Message(
              title: 'Allow access to show the visualizer',
              text: permission.isPermanentlyDenied
                  ? 'Android requires microphone access to read what is playing. Nothing is recorded. '
                      'Allow Microphone in the app settings.'
                  : 'Android requires microphone access to read what is playing. Nothing is recorded.',
              actionLabel: permission.isPermanentlyDenied ? 'Open settings' : 'Allow',
              onAction: _requestPermission,
            ),
          )
        else if (_unavailable)
          const Expanded(
            child: _Message(
              title: "Visualizer isn't available",
              text: "This device won't share the audio that's playing.",
            ),
          )
        else ...[
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: RepaintBoundary(
                      child: CustomPaint(size: Size.infinite, painter: _VisualizerPainter(_signal, style)),
                    ),
                  ),
                  Align(
                    alignment: Alignment.topCenter,
                    child: AnimatedOpacity(
                      opacity: _playing && _volumeOff ? 1 : 0,
                      duration: const Duration(milliseconds: 250),
                      child: const _VolumeOffNote(),
                    ),
                  ),
                  if (_wholePc) const Align(alignment: Alignment.bottomCenter, child: _WholePcNote()),
                ],
              ),
            ),
          ),
          _StylePicker(
            genre: genre,
            selected: style,
            onChanged: music.setVisualizerStyle,
            artworkColors: music.visualizerArtworkColors,
            onArtworkColors: music.setVisualizerArtworkColors,
          ),
        ],
      ],
    );
  }
}

/// Everything the painter reads each frame, updated without rebuilding
/// widgets: the bar levels, the waveform and its trails, beats, and the
/// sparks and rings they set off.
class _Signal extends ChangeNotifier {
  final bands = Float64List(_bandCount);
  final fineBands = Float64List(_fineBandCount);

  final wave = Float64List(_wavePoints);

  /// The last few waveforms, newest first, drawn as fading trails.
  final waveTrail = List.generate(_trailLength, (_) => Float64List(_wavePoints));
  double _sinceTrail = 0;

  double time = 0;

  /// Up to 1 on a beat, fading to 0 within about a third of a second. An
  /// ordinary beat only reaches about half; big ones go all the way.
  double beat = 0;

  /// 1 on a big beat (a drop, or a hit well above the song's usual ones),
  /// fading more slowly than [beat]. Ordinary beats leave it alone, so the
  /// big ones stand out from the steady kick.
  double impact = 0;

  /// How strong the song's recent beats have been, to judge each one by.
  double _beatAverage = 0.5;

  /// The Radial style's rotation, kicked forward on beats.
  double spin = 0;
  double _spinSpeed = _baseSpin;

  /// How far round the Pulse style's dots have orbited, and how fast they're
  /// going (radians a second): faster with the treble, kicked on beats.
  double orbit = 0;
  double orbitSpeed = _baseOrbit;

  /// Sparks and shockwave rings sent out on beats, for the Radial and Pulse
  /// styles.
  final particles = <_Particle>[];
  final rings = <_Ring>[];
  final _random = Random();

  Color low = AppColors.accent;
  Color high = const Color(0xFF6366F1);

  /// The style showing, so only its own moving parts are moved.
  VisualizerStyle style = VisualizerStyle.bars;

  /// The Starfield style's stars, and how fast they're flying (depth a
  /// second): a slow drift, faster with the music, a jump to warp on drops.
  late final stars = List.generate(_starCount, (_) => _Star(_random, z: _random.nextDouble()));
  double warp = _baseWarp;

  /// The Particles style's motes, each circling the centre.
  late final motes = List.generate(_moteCount, (_) => _Mote(_random));

  final _lastCapture = Float64List(_bandCount);
  double _fluxAverage = 0;
  double _sinceBeat = 1;

  static const _trailLength = 4;
  static const _baseSpin = 0.12;
  static const _baseOrbit = 0.5;
  static const _baseWarp = 0.08;
  static const _starCount = 240;
  static const _moteCount = 180;

  /// Kept light everywhere (no glow, few sparks, no orbit tails), so it runs
  /// at the screen's full frame rate on any phone or PC, which matters more
  /// to how smooth it looks than the extras.
  static const _maxParticles = 60;

  /// Whether everything has come to rest, so there's nothing new to draw.
  bool get settled {
    if (beat > 0.01 || impact > 0.01 || particles.isNotEmpty || rings.isNotEmpty) return false;
    for (final level in bands) {
      if (level > 0.005) return false;
    }
    for (final level in fineBands) {
      if (level > 0.005) return false;
    }
    for (final point in wave) {
      if (point.abs() > 0.005) return false;
    }
    return true;
  }

  /// Looks for a hit in each new capture: how much the spectrum rose since
  /// the last one (its "flux"), jumping well above its recent average. That
  /// catches kicks, snares and claps alike, even in a drop whose bass never
  /// lets up.
  void onCapture(Float64List captured) {
    var flux = 0.0;
    for (var i = 0; i < _bandCount && i < captured.length; i++) {
      flux += max(0.0, captured[i] - _lastCapture[i]);
      _lastCapture[i] = captured[i];
    }
    flux /= _bandCount;
    if (flux > _fluxAverage * 1.5 + 0.02 && _sinceBeat > 0.15) {
      _onBeat((flux - _fluxAverage) / (_fluxAverage + 0.05) * 0.5);
    }
    _fluxAverage += (flux - _fluxAverage) * 0.1;
  }

  /// A hit of [score]: how far the spectrum jumped above its recent level.
  void _onBeat(double score) {
    _sinceBeat = 0;
    // How much bigger than the song's recent beats this one is: 0 for an
    // ordinary beat, up to 1 for one about twice as strong.
    final big = ((score / (_beatAverage + 0.01) - 1.4) / 0.8).clamp(0.0, 1.0);
    _beatAverage += (score - _beatAverage) * 0.15;
    final strength = score.clamp(0.35, 1.0) * (0.55 + 0.45 * big);
    beat = max(beat, strength);
    impact = max(impact, big);
    _spinSpeed += strength * 1.4 + big * 1.5;
    rings.add(_Ring(min(1.0, strength + 0.3 * big)));
    // Sparks burst out from the circle's edge, more and faster on big beats.
    final count = ((4 + 8 * strength) * (1 + big)).round();
    for (var i = 0; i < count && particles.length < _maxParticles; i++) {
      final angle = _random.nextDouble() * 2 * pi;
      final speed = (0.35 + _random.nextDouble() * 0.9) * (0.6 + strength);
      final direction = Offset(cos(angle), sin(angle));
      particles.add(_Particle(
        position: direction * 0.42,
        velocity: direction * speed,
        life: 0.5 + _random.nextDouble() * 0.6,
        size: 2 + _random.nextDouble() * 3.5,
        hue: _random.nextDouble(),
      ));
    }
  }

  /// How fast bars ease toward each capture, per second: rising quickly
  /// enough that a hit still lands within a couple of captures (captures
  /// come ~20 times a second), falling more slowly so they glide down rather
  /// than flicker. Higher is snappier.
  static const _rise = 14.0;
  static const _fall = 4.0;
  static const _waveEase = 10.0;

  /// The share of the way to its target a value moves in [dt] at [rate],
  /// the same at any frame rate (60, 90 or 120Hz).
  static double _ease(double rate, double dt) => 1 - exp(-rate * dt);

  void update(double dt, Float64List? targets, Float64List? fineTargets, Float64List? waveTargets) {
    // Bars rise fast to a hit and ease back down, so beats stand apart
    // without the bars jittering between captures.
    final rise = _ease(_rise, dt), fall = _ease(_fall, dt);
    for (final (levels, targets) in [(bands, targets), (fineBands, fineTargets)]) {
      for (var i = 0; i < levels.length; i++) {
        final target = targets == null || i >= targets.length ? 0.0 : targets[i];
        final level = levels[i];
        levels[i] = level + (target - level) * (target > level ? rise : fall);
      }
    }

    final waveStep = _ease(_waveEase, dt);
    for (var i = 0; i < _wavePoints; i++) {
      final target = waveTargets == null || i >= waveTargets.length ? 0.0 : waveTargets[i];
      wave[i] += (target - wave[i]) * waveStep;
    }
    _sinceTrail += dt;
    if (_sinceTrail > 0.06) {
      _sinceTrail = 0;
      final oldest = waveTrail.removeLast()..setAll(0, wave);
      waveTrail.insert(0, oldest);
    }

    beat *= exp(-7 * dt);
    impact *= exp(-4 * dt);
    _sinceBeat += dt;
    _spinSpeed = _baseSpin + (_spinSpeed - _baseSpin) * exp(-2.5 * dt);
    spin += _spinSpeed * dt;
    final orbitTarget = _baseOrbit + 1.6 * average(26, _bandCount) + 2.5 * beat;
    orbitSpeed += (orbitTarget - orbitSpeed) * _ease(4, dt);
    orbit += orbitSpeed * dt;

    for (final p in particles) {
      p.position += p.velocity * dt;
      p.velocity *= exp(-1.6 * dt);
      p.age += dt;
    }
    particles.removeWhere((p) => p.age >= p.life);
    for (final ring in rings) {
      ring.age += dt;
    }
    rings.removeWhere((ring) => ring.age >= _Ring.lifetime);

    if (style == VisualizerStyle.starfield) {
      final warpTarget = _baseWarp + 0.7 * average(0, 12) + 0.9 * beat + 2.2 * impact;
      // Speeds up at once on a hit and slows down gently.
      warp += (warpTarget - warp) * _ease(warpTarget > warp ? 12 : 1.5, dt);
      for (final star in stars) {
        star.z -= warp * dt;
        if (star.z <= 0.02 || star.x.abs() > star.z * 1.6 || star.y.abs() > star.z * 1.6) star.respawn(_random);
      }
    } else if (style == VisualizerStyle.particles) {
      final speed = 0.06 + 0.5 * average(6, 26) + 1.4 * beat;
      for (final mote in motes) {
        mote.angle += mote.direction * speed * dt / sqrt(mote.radius);
      }
    }
  }

  /// Back to silence, for when the visualizer is shown again.
  void clear() {
    bands.fillRange(0, _bandCount, 0);
    fineBands.fillRange(0, _fineBandCount, 0);
    wave.fillRange(0, _wavePoints, 0);
    for (final trail in waveTrail) {
      trail.fillRange(0, _wavePoints, 0);
    }
    beat = 0;
    impact = 0;
    _beatAverage = 0.5;
    _lastCapture.fillRange(0, _bandCount, 0);
    _fluxAverage = 0;
    particles.clear();
    rings.clear();
    warp = _baseWarp;
  }

  void tick() => notifyListeners();

  /// How far big beats punch the whole drawing towards the viewer.
  double get zoom => 1 + 0.06 * impact;

  /// How much the Radial style's circle has swelled
  /// with the bass and beats.
  double get radialSwell => 1 + average(0, 6) * 0.18 + beat * 0.12 + impact * 0.18;

  double average(int from, int to) {
    var sum = 0.0;
    for (var i = from; i < to; i++) {
      sum += bands[i];
    }
    return sum / (to - from);
  }
}


/// A spark thrown out on a beat. Positions are in units of the style's
/// radius, from the view's centre.
class _Particle {
  _Particle({required this.position, required this.velocity, required this.life, required this.size, required this.hue});

  Offset position;
  Offset velocity;
  final double life;
  final double size;

  /// Where between the low and high colour it sits.
  final double hue;
  double age = 0;
}

/// A star in the Starfield style: where it is across the view (-1..1 at the
/// far end), and how far away, 1 being the furthest. It flies towards the
/// viewer and starts again at the far end once past.
class _Star {
  _Star(Random random, {required this.z}) : hue = random.nextDouble() {
    _place(random);
  }

  late double x, y;
  double z;

  /// Where between the low and high colour it sits, and which band lights it.
  final double hue;

  void respawn(Random random) {
    z = 1;
    _place(random);
  }

  void _place(Random random) {
    x = random.nextDouble() * 2 - 1;
    y = random.nextDouble() * 2 - 1;
  }
}

/// A mote in the Particles style, circling the centre at [radius] (0..1 of
/// the view). Inner motes follow the bass, outer ones the treble.
class _Mote {
  _Mote(Random random)
      // Spread evenly over the area, not bunched in the middle.
      : radius = 0.12 + 0.88 * sqrt(random.nextDouble()),
        angle = random.nextDouble() * 2 * pi,
        phase = random.nextDouble() * 2 * pi,
        direction = random.nextBool() ? 1 : -0.6;

  final double radius;
  double angle;

  /// Offsets its gentle wobble from its neighbours'.
  final double phase;

  /// Which way it goes round, and how fast compared with the others.
  final double direction;

  int get band => ((radius - 0.12) / 0.88 * (_bandCount - 1)).round();
}

/// A shockwave ring sent out on a beat.
class _Ring {
  _Ring(this.strength);

  static const lifetime = 0.8;

  final double strength;
  double age = 0;
}

/// A centred note in place of the visualizer, with an optional button.
class _Message extends StatelessWidget {
  const _Message({required this.title, required this.text, this.actionLabel, this.onAction});

  final String title;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.graphic_eq_rounded, size: 40, color: AppColors.textTertiary),
            const SizedBox(height: 12),
            Text(title, textAlign: TextAlign.center, style: textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(text, textAlign: TextAlign.center, style: textTheme.bodySmall),
            if (actionLabel != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shown over the visualizer while music plays with the volume all the way
/// down, since there's then nothing for it to show.
class _VolumeOffNote extends StatelessWidget {
  const _VolumeOffNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: const ShapeDecoration(color: AppColors.surfaceHigh, shape: StadiumBorder()),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.volume_off_rounded, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Volume is off. Turn it up to see the visualizer move.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// Under the visualizer on older Windows, which can't share just one app's
/// audio: says other apps' sound moves it too.
class _WholePcNote extends StatelessWidget {
  const _WholePcNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: const ShapeDecoration(color: AppColors.surfaceHigh, shape: StadiumBorder()),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.info_outline_rounded, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              "This version of Windows can't share just Blimp's audio, so sound from other apps moves the "
              'visualizer too. Windows 11 shows Blimp alone.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// "Style" dropdown at the bottom of the tab, above what sets the colours:
/// the song's genre, or its artwork, picked with the button beside it.
class _StylePicker extends StatelessWidget {
  const _StylePicker({
    required this.genre,
    required this.selected,
    required this.onChanged,
    required this.artworkColors,
    required this.onArtworkColors,
  });

  final String? genre;
  final VisualizerStyle selected;
  final ValueChanged<VisualizerStyle> onChanged;
  final bool artworkColors;
  final ValueChanged<bool> onArtworkColors;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Style', style: textTheme.titleSmall),
                  Text(
                    artworkColors ? 'Colours from the artwork' : genre ?? 'No genre',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: artworkColors ? 'Colour by genre' : 'Colour by artwork',
              isSelected: artworkColors,
              icon: const Icon(Icons.palette_outlined),
              selectedIcon: const Icon(Icons.palette_rounded, color: AppColors.accent),
              onPressed: () => onArtworkColors(!artworkColors),
            ),
            const SizedBox(width: 4),
            DropdownButtonHideUnderline(
              child: Container(
                padding: const EdgeInsets.only(left: 14, right: 6),
                decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(12)),
                child: DropdownButton<VisualizerStyle>(
                  value: selected,
                  borderRadius: BorderRadius.circular(12),
                  dropdownColor: AppColors.surfaceHigh,
                  icon: const Icon(Icons.expand_more_rounded),
                  onChanged: (style) => onChanged(style!),
                  items: [
                    for (final style in VisualizerStyle.values)
                      DropdownMenuItem(
                        value: style,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(style.icon, size: 20, color: AppColors.accent),
                            const SizedBox(width: 10),
                            Text(style.label),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VisualizerPainter extends CustomPainter {
  _VisualizerPainter(this.signal, this.style) : super(repaint: signal);

  final _Signal signal;
  final VisualizerStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // Stars and motes fly right to the edges; kept off what's around.
    if (style == VisualizerStyle.starfield || style == VisualizerStyle.particles) canvas.clipRect(Offset.zero & size);
    _paintBackdrop(canvas, size);

    // Big beats punch the whole drawing towards the viewer for a moment;
    // not the bar styles, which stay put and follow the levels alone, nor
    // Starfield, which leaps to warp instead.
    final zoom = switch (style) {
      VisualizerStyle.bars || VisualizerStyle.mirror || VisualizerStyle.starfield => 1.0,
      _ => signal.zoom,
    };
    final center = size.center(Offset.zero);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(zoom);
    canvas.translate(-center.dx, -center.dy);

    _paintStyle(canvas, size);
    canvas.restore();
  }

  void _paintStyle(Canvas canvas, Size size) {
    switch (style) {
      case VisualizerStyle.bars:
        _paintBars(canvas, size);
      case VisualizerStyle.mirror:
        _paintMirror(canvas, size);
      case VisualizerStyle.wave:
        _paintWave(canvas, size);
      case VisualizerStyle.radial:
        _paintRadial(canvas, size);
      case VisualizerStyle.pulse:
        _paintPulse(canvas, size);
      case VisualizerStyle.particles:
        _paintMotes(canvas, size);
      case VisualizerStyle.starfield:
        _paintStarfield(canvas, size);
    }
  }

  /// Stars flying out of the middle towards the viewer, lit by the
  /// spectrum: a drift in quiet parts, streaks at warp speed on a drop.
  void _paintStarfield(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final scale = max(size.width, size.height) * 0.35;
    // How far back each streak reaches: a dot at a drift, a long line at warp.
    final trail = 0.012 + signal.warp * 0.05;
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (final star in signal.stars) {
      final near = 1 - star.z;
      final level = signal.bands[(star.hue * (_bandCount - 1)).round()];
      final head = center + Offset(star.x, star.y) / star.z * scale;
      final tail = center + Offset(star.x, star.y) / (star.z + trail) * scale;
      paint
        ..strokeWidth = 0.6 + near * near * 3.2 * (0.7 + 0.6 * level)
        ..color = Color.lerp(_colorAt(star.hue), Colors.white, 0.25 + 0.5 * level)!
            .withValues(alpha: (near * 1.4).clamp(0.0, 1.0) * (0.55 + 0.45 * level));
      canvas.drawLine(tail, head, paint);
    }
  }

  /// Motes circling the centre in a slow swirl, the inner ones lit by the
  /// bass and the outer by the treble, swelling out on beats.
  void _paintMotes(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final extent = _roundSize(size) / 2 * 0.95;
    final bass = signal.average(0, 6);
    final swell = 1 + 0.1 * signal.beat + 0.18 * signal.impact;
    _paintRings(canvas, center, extent * 0.9);

    // A faint glow at the core, breathing with the bass.
    final core = extent * (0.2 + 0.25 * bass) * swell;
    canvas.drawCircle(
      center,
      core,
      Paint()
        ..shader = RadialGradient(colors: [signal.high.withValues(alpha: 0.35 + 0.3 * bass), signal.high.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: center, radius: core)),
    );

    final paint = Paint();
    final glow = Paint();
    final time = signal.time;
    for (final mote in signal.motes) {
      final level = signal.bands[mote.band];
      final radius = mote.radius * extent * (1 + 0.3 * level) * swell + 4 * sin(time * 1.7 + mote.phase);
      final position = center + Offset(cos(mote.angle), sin(mote.angle)) * radius;
      final color = _colorAt(mote.radius);
      if (level > 0.45) {
        glow.color = color.withValues(alpha: 0.18 * level);
        canvas.drawCircle(position, 4 + 9 * level, glow);
      }
      paint.color = Color.lerp(color, Colors.white, 0.3 * level)!.withValues(alpha: 0.3 + 0.7 * level);
      canvas.drawCircle(position, 1.2 + 3.8 * level, paint);
    }
    _paintParticles(canvas, center, extent * 0.9);
  }

  Color _colorAt(double x, [double alpha = 1]) => Color.lerp(signal.low, signal.high, x)!.withValues(alpha: alpha);

  /// A soft pool of colour behind everything that glows with how loud the
  /// music is.
  void _paintBackdrop(Canvas canvas, Size size) {
    final energy = signal.average(0, _bandCount);
    final center = style == VisualizerStyle.bars ? Offset(size.width / 2, size.height * 0.9) : size.center(Offset.zero);
    final radius = max(size.width, size.height) * 0.55;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(colors: [
          signal.low.withValues(alpha: (0.06 + 0.12 * energy).clamp(0.0, 1.0)),
          signal.low.withValues(alpha: 0),
        ]).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
  }

  /// Bass on the left, treble on the right, rising from the bottom.
  void _paintBars(Canvas canvas, Size size) {
    const gap = 1.5;
    final width = (size.width - gap * (_fineBandCount - 1)) / _fineBandCount;
    final bottom = size.height * 0.9;
    final maxHeight = size.height * 0.8;
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [signal.low, signal.high],
      ).createShader(Rect.fromLTWH(0, bottom - maxHeight, size.width, maxHeight));
    final reflection = Paint()..color = signal.low.withValues(alpha: 0.18);
    final radius = Radius.circular(min(width / 2, 4));
    for (var i = 0; i < _fineBandCount; i++) {
      final left = i * (width + gap);
      final height = max(4.0, signal.fineBands[i] * maxHeight);
      canvas.drawRRect(
        RRect.fromLTRBAndCorners(left, bottom - height, left + width, bottom, topLeft: radius, topRight: radius),
        paint,
      );
      canvas.drawRect(Rect.fromLTWH(left, bottom + 4, width, height * 0.08), reflection);
    }
  }

  /// Bass in the middle spreading out to treble at both edges, mirrored
  /// above and below a centre line.
  void _paintMirror(Canvas canvas, Size size) {
    const half = _fineBandCount ~/ 2;
    const gap = 1.5;
    final width = (size.width - gap * (half * 2 - 1)) / (half * 2);
    final centerY = size.height / 2;
    final maxHeight = size.height * 0.4;
    final paint = Paint();
    final radius = Radius.circular(min(width / 2, 4));
    for (var i = 0; i < half; i++) {
      final level = max(signal.fineBands[i * 2], signal.fineBands[i * 2 + 1]);
      final height = max(3.0, level * maxHeight);
      paint.color = _colorAt(i / (half - 1));
      for (final column in [half - 1 - i, half + i]) {
        final left = column * (width + gap);
        canvas.drawRRect(RRect.fromLTRBR(left, centerY - height, left + width, centerY + height, radius), paint);
      }
    }
  }

  /// The waveform as a glowing line that thickens on beats, trailed by its
  /// last few shapes.
  void _paintWave(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final amplitude = size.height * 0.38 * (1 + 0.15 * signal.beat + 0.3 * signal.impact);
    Path path(Float64List wave, double scale) {
      final path = Path();
      for (var i = 0; i < _wavePoints; i++) {
        final x = i / (_wavePoints - 1) * size.width;
        // Taper the ends so the line meets the edges at the centre.
        final taper = sin(i / (_wavePoints - 1) * pi);
        final y = centerY + (wave[i] * 1.6).clamp(-1.0, 1.0) * amplitude * taper * scale;
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      return path;
    }

    final trails = signal.waveTrail.length;
    for (var t = trails - 1; t >= 0; t--) {
      canvas.drawPath(
        path(signal.waveTrail[t], 1 - 0.08 * (t + 1)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = _colorAt(t / trails, 0.35 * (1 - t / trails)),
      );
    }

    canvas.drawPath(
      path(signal.wave, 1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 + 3 * signal.beat + 4 * signal.impact
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(colors: [signal.low, signal.high]).createShader(Offset.zero & size),
    );
  }

  /// Spokes around a slowly turning circle that swells with the bass; beats
  /// kick the spin and send out rings and sparks.
  void _paintRadial(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final extent = _roundSize(size) / 2;
    final bass = signal.average(0, 6);
    final radius = _radialRadius(size) * signal.radialSwell;
    final maxLength = extent * 0.5;
    const spokes = _bandCount * 2;
    final spokeWidth = 2 * pi * radius / spokes * 0.55;

    _paintRings(canvas, center, extent);
    canvas.drawCircle(
      center,
      radius * 0.92,
      Paint()
        ..shader = RadialGradient(colors: [
          signal.high.withValues(alpha: 0.15 + 0.2 * bass),
          signal.low.withValues(alpha: 0.08 + 0.2 * bass),
        ]).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    canvas.drawCircle(
      center,
      radius * 0.92,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 + 2 * signal.beat
        ..color = signal.low.withValues(alpha: 0.8),
    );

    final paint = Paint()
      ..strokeWidth = spokeWidth
      ..strokeCap = StrokeCap.round;
    for (var s = 0; s < spokes; s++) {
      final band = s < _bandCount ? s : spokes - 1 - s;
      final angle = -pi / 2 + signal.spin + s / spokes * 2 * pi;
      final direction = Offset(cos(angle), sin(angle));
      final length = 3 + signal.bands[band] * maxLength;
      paint.color = _colorAt(band / (_bandCount - 1));
      canvas.drawLine(center + direction * radius, center + direction * (radius + length), paint);
    }
    _paintParticles(canvas, center, extent);
  }

  /// A liquid core whose edge ripples with the spectrum and wobbles on
  /// beats, a ring breathing with the mids, and dots on three tilted orbits
  /// that pass behind and in front of the core, speeding up with the
  /// treble. Shockwaves and sparks on beats.
  void _paintPulse(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final extent = _roundSize(size) * 0.26;
    // The orbits reach furthest, nearly upright: kept to what fits the
    // height, while the rest grows with a wide view.
    final orbitExtent = min(size.width, size.height) * 0.26;
    final bass = signal.average(0, 6);
    final mid = signal.average(6, 26);
    final punch = 1 + 0.18 * signal.beat + 0.2 * signal.impact;

    _paintRings(canvas, center, extent * 1.8);
    // A soft halo; a gradient looks the same as blurring a circle at a
    // fraction of the cost.
    final halo = extent * (0.7 + bass * 0.7) * punch + extent * 0.3;
    canvas.drawCircle(
      center,
      halo,
      Paint()
        ..shader = RadialGradient(
          colors: [signal.low.withValues(alpha: 0.35), signal.low.withValues(alpha: 0.35), signal.low.withValues(alpha: 0)],
          stops: const [0, 0.6, 1],
        ).createShader(Rect.fromCircle(center: center, radius: halo)),
    );
    // The far half of each orbit first, so the core hides what's behind it.
    _paintOrbits(canvas, center, orbitExtent, front: false);
    canvas.drawCircle(
      center,
      extent * (1.0 + mid * 0.3) * punch,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 + 3 * signal.beat
        ..color = signal.high.withValues(alpha: 0.25 + mid * 0.5),
    );
    _paintBlob(canvas, center, extent * (0.55 + bass * 0.3) * punch);
    _paintOrbits(canvas, center, orbitExtent, front: true);
    _paintParticles(canvas, center, extent * 1.8);
  }

  static const _blobPoints = 64;

  /// The Pulse style's core: a circle of [radius] whose edge is pushed out
  /// by the spectrum (bass at the bottom, up both sides to treble at the
  /// top), drifts in slow ripples, and wobbles on beats.
  void _paintBlob(Canvas canvas, Offset center, double radius) {
    final time = signal.time, beat = signal.beat;
    const half = _blobPoints ~/ 2;
    final points = List.generate(_blobPoints, (j) {
      final angle = pi / 2 + j / _blobPoints * 2 * pi;
      // Neighbouring bands averaged, so the edge swells rather than spikes.
      final band = ((j <= half ? j : _blobPoints - j) / half * (_bandCount - 1)).round();
      final level = signal.average(max(0, band - 1), min(_bandCount, band + 2));
      final ripple = 0.035 * sin(3 * angle + time * 1.3) + 0.025 * sin(5 * angle - time * 1.9);
      final wobble = 0.14 * beat * sin(4 * angle + time * 22);
      return center + Offset(cos(angle), sin(angle)) * radius * (1 + 0.22 * level + ripple + wobble);
    });

    // A smooth curve through the points: from each midpoint to the next,
    // bending towards the point between them.
    Offset midpoint(int i) => (points[i % _blobPoints] + points[(i + 1) % _blobPoints]) / 2;
    final start = midpoint(0);
    final path = Path()..moveTo(start.dx, start.dy);
    for (var i = 1; i <= _blobPoints; i++) {
      final point = points[i % _blobPoints], next = midpoint(i);
      path.quadraticBezierTo(point.dx, point.dy, next.dx, next.dy);
    }
    path.close();

    final bounds = Rect.fromCircle(center: center, radius: radius * 1.3);
    canvas.drawPath(
      path,
      Paint()..shader = RadialGradient(colors: [signal.high, signal.low]).createShader(bounds),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Color.lerp(signal.high, Colors.white, 0.4)!.withValues(alpha: 0.6),
    );
  }

  /// The Pulse style's orbits: how far out (times the extent), how flat the
  /// tilt makes them look, which way each leans, how fast (and which way)
  /// each goes compared with the others, and how many dots each carries.
  static const _orbits = [
    (radius: 1.35, squash: 0.32, lean: -0.35, speed: 1.0, dots: 12),
    (radius: 1.6, squash: 0.5, lean: 0.6, speed: -0.7, dots: 10),
    (radius: 1.85, squash: 0.22, lean: 1.75, speed: 0.45, dots: 14),
  ];

  /// The near ([front]) or far half of the orbiting dots. Near dots are
  /// larger and brighter, far ones smaller and dimmer; each dot is lit by a
  /// treble band.
  void _paintOrbits(Canvas canvas, Offset center, double extent, {required bool front}) {
    final paint = Paint();
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final (o, orbit) in _orbits.indexed) {
      final lean = Offset(cos(orbit.lean), sin(orbit.lean));
      final radius = extent * orbit.radius * (1 + 0.08 * signal.beat + 0.25 * signal.impact);

      // A faint track showing the orbit's tilt: whole behind the core, then
      // its near half again in front of it.
      track.color = _colorAt(o / (_orbits.length - 1), front ? 0.22 : 0.12);
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(orbit.lean);
      final oval = Rect.fromCenter(center: Offset.zero, width: radius * 2, height: radius * 2 * orbit.squash);
      front ? canvas.drawArc(oval, 0, pi, false, track) : canvas.drawOval(oval, track);
      canvas.restore();

      for (var i = 0; i < orbit.dots; i++) {
        final angle = signal.orbit * orbit.speed + i / orbit.dots * 2 * pi + o;
        // The orbit's lower half is the near side, passing in front.
        final depth = sin(angle);
        if ((depth >= 0) != front) continue;
        final level = signal.bands[26 + (i * 7 + o * 5) % (_bandCount - 26)];
        final color = _colorAt(i.isEven ? 1 : 0.5);
        final near = (depth + 1) / 2;
        final x = cos(angle) * radius, y = depth * radius * orbit.squash;
        paint.color = Color.lerp(color, Colors.white, 0.35 * near * level)!
            .withValues(alpha: (0.35 + 0.65 * near) * (0.65 + 0.35 * level));
        canvas.drawCircle(
          center + Offset(x * lean.dx - y * lean.dy, x * lean.dy + y * lean.dx),
          (2.4 + level * 3.5) * (0.55 + 0.7 * near),
          paint,
        );
      }
    }
  }

  /// Shockwaves from recent beats, growing and fading.
  void _paintRings(Canvas canvas, Offset center, double extent) {
    final paint = Paint()..style = PaintingStyle.stroke;
    for (final ring in signal.rings) {
      final t = ring.age / _Ring.lifetime;
      paint
        ..strokeWidth = 2 + 5 * (1 - t) * ring.strength
        ..color = _colorAt(t, (1 - t) * 0.9 * ring.strength);
      canvas.drawCircle(center, extent * (0.45 + 0.75 * Curves.easeOut.transform(t)), paint);
    }
  }

  /// Sparks from recent beats, flying out and fading.
  void _paintParticles(Canvas canvas, Offset center, double extent) {
    final paint = Paint();
    for (final p in signal.particles) {
      final fade = 1 - p.age / p.life;
      paint.color = Color.lerp(_colorAt(p.hue), Colors.white, 0.3)!.withValues(alpha: fade);
      canvas.drawCircle(center + p.position * extent, p.size * (0.5 + 0.5 * fade), paint);
    }
  }

  @override
  bool shouldRepaint(_VisualizerPainter old) => old.style != style || old.signal != signal;
}

/// The Radial style's circle at rest, before [_Signal.radialSwell].
double _radialRadius(Size size) => _roundSize(size) / 2 * 0.4;

/// The size the round styles (Radial and Pulse) are drawn to: the view's
/// shorter side, or a little more in a wide view, such as the panel under a
/// desktop player's buttons, where Bars and Wave spread across the width.
/// Loud peaks may then just reach past the top and bottom.
double _roundSize(Size size) {
  final short = min(size.width, size.height);
  return size.width > size.height ? short * min(size.width / size.height, 1.3) : short;
}
