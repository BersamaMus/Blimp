import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'artist_links.dart';
import 'backup.dart';
import 'catalog.dart';
import 'decades.dart';
import 'desktop_library.dart';
import 'folders.dart';
import 'home_widgets.dart';
import 'listening_log.dart';
import 'listening_stats.dart';
import 'lyrics_index.dart';
import 'media_library.dart';
import 'milestones.dart';
import 'playlists.dart';
import 'queue_order.dart';
import 'resume_points.dart';
import 'search_text.dart';
import 'smart_playlists.dart';
import 'song_dna.dart';
import 'time_machine.dart';
import 'visualizer.dart';

enum LibraryStatus { loading, permissionDenied, ready }

/// What a scan of the device found, compared with the library before it.
class ScanResult {
  const ScanResult.failed() : ok = false, added = 0, removed = 0, total = 0;
  const ScanResult({required this.added, required this.removed, required this.total}) : ok = true;

  /// False if the music couldn't be read, or access wasn't given.
  final bool ok;
  final int added;
  final int removed;

  /// Songs in the library now.
  final int total;
}

/// The parts of [MusicController] a widget can depend on, so a change to one
/// (say, the current song) doesn't rebuild screens that only show another.
enum MusicAspect { library, playback, history, favourites, playlists, searches, settings, stats }

class Album {
  Album({
    required this.title,
    required this.artist,
    required this.songs,
    this.year,
    this.releaseType,
    this.isCompilation = false,
  });

  final String title;

  /// Who it's credited to: its album artist, "Various artists" for a
  /// compilation without one, or the artist most of its songs are by.
  final String artist;
  final int? year;

  /// A compilation of various artists' songs, as tagged.
  final bool isCompilation;

  /// Title and artist as search compares them, computed once.
  late final List<String> searchFields = [searchKey(title), searchKey(artist)];

  /// Sorted by track number.
  final List<Song> songs;

  Song get cover => songs.first;

  /// Only one of its songs is in the library, as with a single; there's no
  /// album page worth opening.
  bool get isSingle => songs.length < 2;

  /// "album", "ep" or "single" as tagged in the files, once read (see
  /// [MusicController]); null if they don't say.
  String? releaseType;

  /// "Album", "EP", "Single" or "Compilation": as tagged, or as the title says, as with
  /// iTunes' "Title - Single"; failing both, guessed from how many of its
  /// songs are here, which reads a full album with few songs here as short.
  String get kind => switch (releaseType) {
        'album' => 'Album',
        'ep' => 'EP',
        'single' => 'Single',
        // A few songs of a compilation here make it no single.
        _ => kindFromTitle(title) ?? (isCompilation ? 'Compilation' : switch (songs.length) {
            1 || 2 => 'Single',
            3 || 4 => 'EP',
            _ => 'Album',
          }),
      };

  static final _kindSuffix = RegExp(r'(?:\s+[-–—]\s*|\s*[(\[])(single|ep)[)\]]?\s*$', caseSensitive: false);

  /// "Single" or "EP" for titles ending "- Single", "(EP)" and the like.
  static String? kindFromTitle(String title) => switch (_kindSuffix.firstMatch(title)?.group(1)?.toLowerCase()) {
        'single' => 'Single',
        'ep' => 'EP',
        _ => null,
      };
}

class Artist {
  Artist({required this.name, required this.songs, required this.albums});

  final String name;
  final List<Song> songs;
  final List<Album> albums;

  Song get cover => songs.first;

  /// The name as search compares it, computed once.
  late final List<String> searchFields = [searchKey(name)];
}

/// Owns the audio player and everything derived from the device's music
/// library, plus the user's favourites, play history and recent searches.
class MusicController extends ChangeNotifier with WidgetsBindingObserver {
  MusicController() {
    _sequenceSub = player.sequenceStateStream.listen(_onSequenceState);
    _playerStateSub = player.playerStateStream.listen((_) {
      _updateListening();
      _updateResume();
      _updateQueuePosition();
      _updateFading();
      _updateHomeWidgets();
    });
    // A pause from outside the app (the notification, headphones) arrives
    // before the place it paused at, so that's noted when it comes.
    _playbackEventSub = player.playbackEventStream.listen((_) {
      if (player.playing) return;
      _updateResume();
      _saveQueuePosition();
    }, onError: (Object _, StackTrace _) {});
    _seekSub = player.positionDiscontinuityStream.listen((discontinuity) {
      switch (discontinuity.reason) {
        case PositionDiscontinuityReason.seek:
          _seekFrom = discontinuity.previousEvent.currentIndex;
          _seekAt = DateTime.now();
          // Moved while paused: kept, as the timer only runs while playing.
          if (!player.playing) _saveQueuePosition();
        case PositionDiscontinuityReason.autoAdvance:
          // Followed on from the song before: fades in, if fading.
          _fadeInIndex = discontinuity.event.currentIndex;
          // Skips from outside the app (the notification, headphones, the
          // widgets) change song without a seek here, so they arrive as the
          // song ending. A song only really ends while playing.
          if (player.playing || _settingQueue) return;
          // Not straight away: the first such skip since launch starts the
          // playback service, which drops a play sent while it starts.
          Future.delayed(const Duration(milliseconds: 300), () {
            if (!player.playing && !_settingQueue) player.play();
          });
      }
    });
    _indexSub = player.currentIndexStream.listen(_playIfSkipped);
    WidgetsBinding.instance.addObserver(this);
  }

  late final StreamSubscription<PositionDiscontinuity> _seekSub;
  late final StreamSubscription<int?> _indexSub;

  /// Where and when the player last seeked from, to tell a skip apart from
  /// other changes of song.
  int? _seekFrom;
  DateTime? _seekAt;

  /// Skipping to another song plays it, even if the last was paused, as in
  /// other players. A skip in the app (its buttons, or the queue) is a seek
  /// followed by a change of song: seeking within a song, or a queue loading
  /// in, stays paused. Skips from outside the app are caught in
  /// [_seekSub]'s listener.
  void _playIfSkipped(int? index) {
    final at = _seekAt;
    if (index == null || at == null || index == _seekFrom) return;
    _seekAt = null;
    if (_settingQueue || player.playing) return;
    if (DateTime.now().difference(at) < const Duration(seconds: 2)) player.play();
  }

  // Stored under the old "liked" key so favourites saved before the rename survive.
  static const _favouritesKey = 'liked_song_ids';
  static const _historyKey = 'history_song_ids';
  static const _playCountsKey = 'play_counts';
  static const _resumeKey = 'resume_points';
  static const _searchesKey = 'recent_searches';
  static const _seekSecondsKey = 'seek_seconds';
  static const _skipSilenceKey = 'skip_silence';
  static const _waveformSeekBarKey = 'waveform_seek_bar';
  static const _browseFoldersKey = 'library_browse_folders';
  static const _equalizerEnabledKey = 'equalizer_enabled';
  static const _equalizerGainsKey = 'equalizer_gains';
  static const _historyPausedKey = 'history_paused';
  static const _searchHistoryPausedKey = 'search_history_paused';
  static const _visualizerStyleKey = 'visualizer_style';
  static const _visualizerEnabledKey = 'visualizer_enabled';
  static const _autoplayKey = 'autoplay';
  static const _queueKey = 'queue_song_ids';
  static const _queueIndexKey = 'queue_index';
  static const _unshuffledKey = 'queue_unshuffled_ids';
  static const _queuePositionKey = 'queue_position';
  static const _playlistsKey = 'playlists';
  static const _smartPlaylistsKey = 'smart_playlists';
  static const _ratingsKey = 'song_ratings';
  static const _hiddenFoldersKey = 'hidden_folders';
  static const _minSongSecondsKey = 'min_song_seconds';
  static const _speedKey = 'playback_speed';
  static const _normalizeKey = 'normalize_volume';
  static const _fadeKey = 'fade_seconds';
  static const _volumeKey = 'volume';
  static const _historyLimit = 100;

  static const seekSecondsOptions = [5, 10, 15, 20, 30, 60];

  /// Only Android supports audio effects; elsewhere the pipeline is left out.
  final AndroidEqualizer? equalizer = Platform.isAndroid ? AndroidEqualizer() : null;

  /// Turns quiet songs up, for volume normalisation; the player's volume
  /// can only turn them down.
  final AndroidLoudnessEnhancer? _booster = Platform.isAndroid ? AndroidLoudnessEnhancer() : null;

  late final player = AudioPlayer(
    audioPipeline: equalizer == null ? null : AudioPipeline(androidAudioEffects: [equalizer!, _booster!]),
  );
  late final StreamSubscription<SequenceState> _sequenceSub;
  late final StreamSubscription<PlayerState> _playerStateSub;
  late final StreamSubscription<PlaybackEvent> _playbackEventSub;
  SharedPreferences? _prefs;

  LibraryStatus status = LibraryStatus.loading;
  List<Song> songs = const [];
  List<Album> albums = const [];
  List<Artist> artists = const [];

  /// The genres the library's songs are tagged with, biggest first.
  List<String> genres = const [];
  Map<String, List<Song>> _songsByGenre = const {};
  Map<int, Song> _songsById = const {};
  Map<String, Artist> _artistsByName = const {};
  Map<int, Album> _albumsBySongId = const {};
  List<Song> _quickPicks = const [];

  /// The folders the library's songs are in, for browsing by folder; null
  /// if Android didn't say where any of the files are.
  Folder? rootFolder;
  Map<String, Folder> _foldersByPath = const {};

  /// Newest first; computed once per scan.
  List<Song> recentlyAdded = const [];

  /// Most recent first.
  List<int> _favouriteIds = [];
  List<int> _historyIds = [];
  Map<int, int> _playCounts = {};
  List<String> _recentSearches = [];
  int? _lastRecordedId;

  Future<void> init() async {
    // As music: other apps and calls pause or duck playback, and it resumes
    // after; unplugging headphones pauses it. Phones only.
    if (!isDesktop) await (await AudioSession.instance).configure(const AudioSessionConfiguration.music());
    final prefs = _prefs = await SharedPreferences.getInstance();
    _favouriteIds = _readIds(prefs, _favouritesKey);
    _historyIds = _readIds(prefs, _historyKey);
    _resume = ResumePoints.decode(prefs.getStringList(_resumeKey));
    _playCounts = {
      for (final entry in prefs.getStringList(_playCountsKey) ?? const <String>[])
        if (entry.split(':') case [final id, final count])
          if ((int.tryParse(id), int.tryParse(count)) case (final int i, final int c)) i: c,
    };
    _recentSearches = prefs.getStringList(_searchesKey) ?? [];
    _playlists = decodePlaylists(prefs.getString(_playlistsKey));
    _smartPlaylists = decodeSmartPlaylists(prefs.getString(_smartPlaylistsKey));
    _ratings = {
      for (final entry in prefs.getStringList(_ratingsKey) ?? const <String>[])
        if (entry.split(':') case [final id, final rating])
          if ((int.tryParse(id), int.tryParse(rating)) case (final int i, final int r) when r >= 1 && r <= 5) i: r,
    };
    _readSettings(prefs);
    try {
      try {
        _lyrics = await LyricsIndex.open();
      } on Object {
        // No folder to keep it in: lyrics just aren't searched.
      }
      _log = await ListeningLog.open();
      await load();
    } finally {
      // Whatever happened, nothing waiting on startup waits forever.
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  final _ready = Completer<void>();

  /// Done once the app has started up and first looked for music.
  Future<void> get ready => _ready.future;

  static List<int> _readIds(SharedPreferences prefs, String key) =>
      (prefs.getStringList(key) ?? const []).map(int.tryParse).whereType<int>().toList();

  void _saveIds(String key, List<int> ids) =>
      _prefs?.setStringList(key, ids.map((id) => '$id').toList());

  @override
  void dispose() {
    _commitListen(continuing: false);
    _listenTimer?.cancel();
    _playbackEventSub.cancel();
    _resumeTimer?.cancel();
    _queuePositionTimer?.cancel();
    _sleepTimer?.cancel();
    _sleepPositionSub?.cancel();
    _fadeTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _playerStateSub.cancel();
    _sequenceSub.cancel();
    _seekSub.cancel();
    _indexSub.cancel();
    volume.dispose();
    _shufflingChanges.close();
    player.dispose();
    super.dispose();
  }

  final _changed = <MusicAspect>{};

  /// What changed since [MusicScope] last rebuilt; it clears the set.
  Set<MusicAspect> takeChanges() {
    final changed = {..._changed};
    _changed.clear();
    return changed;
  }

  void _notify(Set<MusicAspect> aspects) {
    _changed.addAll(aspects);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Library

  Future<bool> _requestPermission() async {
    if (await _hasPermission()) return true;
    try {
      // Android 13+ uses READ_MEDIA_AUDIO; older versions use storage.
      final audio = await Permission.audio.request();
      if (audio.isGranted) return true;
      final storage = await Permission.storage.request();
      return storage.isGranted;
    } on PlatformException {
      // No screen to ask on: started in the background, e.g. by Android
      // Auto. The app asks when it's next opened.
      return false;
    }
  }

  /// Whether access was granted outside the app, e.g. in system settings.
  static Future<bool> _hasPermission() async =>
      !Platform.isAndroid || await Permission.audio.isGranted || await Permission.storage.isGranted;

  /// Scans the device for music. A scan already under way is joined rather
  /// than started again.
  Future<ScanResult> load() => _loading ??= _load().whenComplete(() => _loading = null);

  Future<ScanResult>? _loading;

  Future<ScanResult> _load() async {
    status = LibraryStatus.loading;
    _notify({MusicAspect.library});

    if (!await _requestPermission()) {
      status = LibraryStatus.permissionDenied;
      _notify({MusicAspect.library});
      return const ScanResult.failed();
    }

    final before = _songsById.keys.toSet();
    var ok = true;
    try {
      _scanned = await MediaLibrary.getSongs();
    } on Exception {
      // Couldn't read the library: show what was there before (nothing, at
      // first), rather than loading forever. Rescanning tries again.
      ok = false;
    }
    _scannedById = {for (final s in _scanned) s.id: s};
    status = LibraryStatus.ready;
    // Files may have changed since: lyrics search looks at them afresh.
    _lyricStamps.clear();
    _applyFilters();
    await _restoreQueue();
    unawaited(_loadReleaseTypes());
    if (!ok) return const ScanResult.failed();
    final after = _songsById.keys.toSet();
    return ScanResult(
      added: after.difference(before).length,
      removed: before.difference(after).length,
      total: after.length,
    );
  }

  /// Release types tagged in songs' files, by song id; see [Album.releaseType].
  final Map<int, String> _releaseTypes = {};

  /// Albums whose files have been asked for their release type, by cover song.
  final Set<int> _releaseTypesAsked = {};

  /// Reads the release type from one song of each album not asked yet, in
  /// batches, so labels sharpen as it goes rather than all at the end. The
  /// answers are kept on the device, so after the first time this is quick.
  Future<void> _loadReleaseTypes() async {
    final pending = [for (final a in albums) if (_releaseTypesAsked.add(a.cover.id)) a];
    for (var i = 0; i < pending.length; i += 50) {
      final batch = pending.skip(i).take(50).toList();
      final types = await MediaLibrary.getReleaseTypes([for (final a in batch) a.cover.id]);
      if (types == null) {
        // Couldn't ask: the next scan tries these again.
        _releaseTypesAsked.removeAll([for (final a in batch) a.cover.id]);
        continue;
      }
      if (types.isEmpty) continue;
      _releaseTypes.addAll(types);
      // The albums may have been rebuilt meanwhile (a folder hidden, say).
      for (final album in albums) {
        album.releaseType ??= album.songs.map((s) => _releaseTypes[s.id]).nonNulls.firstOrNull;
      }
      _notify({MusicAspect.library});
    }
    await _loadHiRes();
  }

  /// Songs found to be hi-res, by id, and those checked so far.
  final Set<int> _hiResIds = {};
  final Set<int> _hiResAsked = {};

  /// Whether [song] is hi-res, once checked (see [_loadHiRes]).
  bool isHiRes(Song song) => _hiResIds.contains(song.id);

  /// Whether every song of [album] here is hi-res.
  bool isAlbumHiRes(Album album) => album.songs.isNotEmpty && album.songs.every(isHiRes);

  /// Checks songs not checked yet for hi-res, in batches so badges appear
  /// as it goes. Lossy files are passed over at once; the answers are kept
  /// on the device, so after the first time this is quick.
  Future<void> _loadHiRes() async {
    final pending = [for (final s in _scanned) if (_hiResAsked.add(s.id)) s];
    for (var i = 0; i < pending.length; i += 100) {
      final found = await MediaLibrary.getHiRes(pending.skip(i).take(100).toList());
      if (found.isEmpty) continue;
      _hiResIds.addAll(found);
      _notify({MusicAspect.library});
    }
  }

  /// Every song the last scan found, before [hiddenFolders] and
  /// [minSongSeconds] leave some out.
  List<Song> _scanned = const [];

  /// [_scanned] by id. The queue looks songs up here rather than in the
  /// library, so a song keeps playing (and showing) when its folder is hidden.
  Map<int, Song> _scannedById = const {};

  /// Rebuilds the library from the last scan with the current filters.
  void _applyFilters() {
    final minDuration = Duration(seconds: minSongSeconds);
    bool hidden(String? folder) =>
        folder != null && hiddenFolders.any((h) => folder == h || folder.startsWith('$h/'));
    _index([
      for (final s in _scanned)
        // A duration of 0 means Android doesn't know it, not that it's short.
        if (!hidden(s.folder) && (s.duration == null || s.duration == Duration.zero || s.duration! >= minDuration)) s,
    ]);
    // Favourites, history and playlists are looked up by id in the new library.
    _invalidateHistory();
    _favouriteSongs = null;
    _playlistSongs.clear();
    _lyricSearch = null;
    _notify({MusicAspect.library, MusicAspect.history, MusicAspect.favourites, MusicAspect.playlists});
    // Songs brought back (a folder unhidden, say) may not have been read.
    unawaited(_indexLyrics());
  }

  void _index(List<Song> all) {
    songs = all;
    _songsById = {for (final s in all) s.id: s};

    _credits = ArtistCredits(all);
    albums = buildAlbums(all, releaseTypes: _releaseTypes, credits: _credits);
    artists = buildArtists(all, albums, credits: _credits);
    _artistsByName = {for (final a in artists) a.name: a};

    _albumsBySongId = {
      for (final album in albums)
        for (final s in album.songs) s.id: album,
    };

    final byGenre = <String, List<Song>>{};
    for (final s in all) {
      if (s.genre case final genre?) byGenre.putIfAbsent(genre, () => []).add(s);
    }
    _songsByGenre = byGenre;
    genres = byGenre.keys.toList()
      ..sort((a, b) {
        final bySize = byGenre[b]!.length.compareTo(byGenre[a]!.length);
        return bySize != 0 ? bySize : a.compareTo(b);
      });

    final epoch = DateTime(0);
    recentlyAdded = [...all]..sort((a, b) => (b.dateAdded ?? epoch).compareTo(a.dateAdded ?? epoch));

    final tree = buildFolderTree(all);
    rootFolder = tree?.root;
    _foldersByPath = tree?.byPath ?? const {};

    decades = decadesOf(all, now: DateTime.now());
    _artistGraph = null;
    _forgetListenFacts();

    _shuffleQuickPicks();
  }

  /// How artist credits split into artists, given who's in the library.
  ArtistCredits _credits = ArtistCredits(const []);

  /// The decades the library's songs come from, for Decade radio.
  List<Decade> decades = const [];

  /// Who has worked with whom, for Six degrees; worked out when first asked.
  ArtistGraph get artistGraph => _artistGraph ??= ArtistGraph(songs, albums, credits: _credits);
  ArtistGraph? _artistGraph;

  /// Plays [decade]'s songs in a random order; autoplay carries on after.
  Future<void> playDecade(Decade decade) => playSongs([
        for (final song in decade.songs)
          if (!isUnwanted(song)) song,
      ], shuffle: true);

  /// The artists credited in [credit] ("A/B", "A feat. B") that are in the
  /// library, in the order credited.
  List<Artist> artistsCredited(String? credit) =>
      [for (final name in _credits.split(credit ?? Song.unknownArtist)) ?_artistsByName[name]];

  /// The artists credited on [song].
  List<Artist> artistsOf(Song song) => artistsCredited(song.artistName);

  /// The folder at [path], if it holds any of the library's songs.
  Folder? folderAt(String? path) => _foldersByPath[path];

  /// The library's song with [id], if there is one.
  Song? songWithId(int? id) => _songsById[id];

  Album? albumOf(Song song) => _albumsBySongId[song.id];

  Artist? artistNamed(String? name) => _artistsByName[name];

  List<Song> songsInGenre(String genre) => _songsByGenre[genre] ?? const [];

  /// A random selection from the library, picked fresh on each launch.
  List<Song> get quickPicks => _quickPicks;

  static const _quickPickCount = 20;

  void _shuffleQuickPicks() =>
      _quickPicks = ([for (final s in songs) if (!isUnwanted(s)) s]..shuffle()).take(_quickPickCount).toList();

  /// Picks a new random set, for the refresh button on Home.
  void reshuffleQuickPicks() {
    _shuffleQuickPicks();
    _notify({MusicAspect.library});
  }

  /// Plays all of Quick picks ("Play all"); autoplay carries on with similar
  /// songs after the last pick. Tapping one pick starts its radio instead.
  Future<void> playQuickPicks() => playSongs(_quickPicks);

  List<Song>? _recentlyPlayed;
  List<Song>? _mostPlayed;
  Map<int, int>? _historyRanks;

  void _invalidateHistory() {
    _recentlyPlayed = null;
    _mostPlayed = null;
    _historyRanks = null;
  }

  List<Song> get recentlyPlayed =>
      _recentlyPlayed ??= _historyIds.map((id) => _songsById[id]).whereType<Song>().toList();

  /// Played songs ranked by play count, like a personal chart.
  List<Song> get mostPlayed => _mostPlayed ??= [
        for (final MapEntry(key: id, value: count) in _playCounts.entries)
          if (count > 0) ?_songsById[id],
      ]..sort((a, b) => _playCounts[b.id]!.compareTo(_playCounts[a.id]!));

  int playCount(Song song) => _playCounts[song.id] ?? 0;

  /// How recently anything in [group] was played (0 = just now), for
  /// "Recent activity" sorting. Unplayed groups rank last.
  int lastPlayedRank(Iterable<Song> group) {
    final ranks = _historyRanks ??= {for (final (i, id) in _historyIds.indexed) id: i};
    var best = _historyLimit + 1;
    for (final s in group) {
      final rank = ranks[s.id];
      if (rank != null && rank < best) best = rank;
    }
    return best;
  }

  // ---------------------------------------------------------------------------
  // Settings

  int seekSeconds = 10;
  bool skipSilence = false;
  bool historyPaused = false;
  bool searchHistoryPaused = false;
  bool equalizerEnabled = false;

  /// The style picked in the Visualizer tab, kept for every song.
  VisualizerStyle visualizerStyle = VisualizerStyle.bars;

  /// Whether the Visualizer tab draws anything; off saves battery.
  bool visualizerEnabled = true;

  /// Whether similar songs keep playing once the queue runs out.
  bool autoplay = true;

  /// Whether the player's seek bar shows the song's waveform instead of a
  /// plain slider.
  bool waveformSeekBar = false;

  /// Whether Library browses the device's folders rather than songs by their
  /// tags (albums, artists, genres).
  bool browseFolders = false;

  /// Saved equalizer gains in decibels, by band index.
  List<double> _equalizerGains = [];

  /// Folders whose songs (and their subfolders' songs) are left out of the
  /// library, by full path.
  List<String> hiddenFolders = [];

  /// Songs shorter than this are left out of the library, such as voice
  /// notes and stray clips; 0 keeps everything. On unless turned off: very
  /// few songs are this short.
  int minSongSeconds = defaultMinSongSeconds;

  static const defaultMinSongSeconds = 10;

  static const minSongSecondsOptions = [0, 10, 30, 60];

  /// How fast songs play, 1 being normal; the pitch stays the same.
  double speed = 1;

  static const speedOptions = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  void setSpeed(double value) {
    speed = value;
    player.setSpeed(value);
    _prefs?.setDouble(_speedKey, value);
    _notify({MusicAspect.settings});
  }

  void hideFolder(String path) {
    if (hiddenFolders.contains(path)) return;
    hiddenFolders = [...hiddenFolders, path]..sort();
    _prefs?.setStringList(_hiddenFoldersKey, hiddenFolders);
    _notify({MusicAspect.settings});
    _applyFilters();
  }

  void unhideFolder(String path) {
    hiddenFolders = [...hiddenFolders]..remove(path);
    _prefs?.setStringList(_hiddenFoldersKey, hiddenFolders);
    _notify({MusicAspect.settings});
    _applyFilters();
  }

  void setMinSongSeconds(int seconds) {
    minSongSeconds = seconds;
    _prefs?.setInt(_minSongSecondsKey, seconds);
    _notify({MusicAspect.settings});
    _applyFilters();
  }

  /// Whether songs were found but [hiddenFolders] and [minSongSeconds]
  /// leave none of them in the library.
  bool get allSongsHidden => songs.isEmpty && _scanned.isNotEmpty;

  /// Turns off both filters, bringing every song back.
  void showAllSongs() {
    hiddenFolders = [];
    minSongSeconds = 0;
    _prefs?.remove(_hiddenFoldersKey);
    // Saved as off, so the default doesn't come back on the next launch.
    _prefs?.setInt(_minSongSecondsKey, 0);
    _notify({MusicAspect.settings});
    _applyFilters();
  }

  void _readSettings(SharedPreferences prefs) {
    seekSeconds = prefs.getInt(_seekSecondsKey) ?? 10;
    skipSilence = prefs.getBool(_skipSilenceKey) ?? false;
    historyPaused = prefs.getBool(_historyPausedKey) ?? false;
    searchHistoryPaused = prefs.getBool(_searchHistoryPausedKey) ?? false;
    equalizerEnabled = prefs.getBool(_equalizerEnabledKey) ?? false;
    visualizerStyle = VisualizerStyle.values.asNameMap()[prefs.getString(_visualizerStyleKey)] ?? VisualizerStyle.bars;
    visualizerEnabled = prefs.getBool(_visualizerEnabledKey) ?? true;
    autoplay = prefs.getBool(_autoplayKey) ?? true;
    waveformSeekBar = prefs.getBool(_waveformSeekBarKey) ?? false;
    browseFolders = prefs.getBool(_browseFoldersKey) ?? false;
    hiddenFolders = prefs.getStringList(_hiddenFoldersKey) ?? [];
    minSongSeconds = prefs.getInt(_minSongSecondsKey) ?? defaultMinSongSeconds;
    speed = prefs.getDouble(_speedKey) ?? 1;
    normalizeVolume = prefs.getBool(_normalizeKey) ?? false;
    fadeSeconds = prefs.getInt(_fadeKey) ?? 0;
    volume.value = prefs.getDouble(_volumeKey) ?? 1;
    if (volume.value != 1) _applyVolume();
    _equalizerGains = (prefs.getStringList(_equalizerGainsKey) ?? const [])
        .map(double.tryParse)
        .map((g) => g ?? 0)
        .toList();

    player.setSkipSilenceEnabled(skipSilence);
    player.setSpeed(speed);
    _booster?.setEnabled(normalizeVolume);
    final eq = equalizer;
    if (eq != null) {
      eq.setEnabled(equalizerEnabled);
      // Bands only exist once the player has loaded audio; apply saved gains then.
      eq.parameters.then((params) {
        for (final band in params.bands) {
          if (band.index < _equalizerGains.length) band.setGain(_equalizerGains[band.index]);
        }
      });
    }
  }

  void setSeekSeconds(int seconds) {
    seekSeconds = seconds;
    _prefs?.setInt(_seekSecondsKey, seconds);
    _notify({MusicAspect.settings});
  }

  void setWaveformSeekBar(bool enabled) {
    waveformSeekBar = enabled;
    _prefs?.setBool(_waveformSeekBarKey, enabled);
    _notify({MusicAspect.settings});
  }

  void setBrowseFolders(bool enabled) {
    browseFolders = enabled;
    _prefs?.setBool(_browseFoldersKey, enabled);
    _notify({MusicAspect.settings});
  }

  void setSkipSilence(bool enabled) {
    skipSilence = enabled;
    player.setSkipSilenceEnabled(enabled);
    _prefs?.setBool(_skipSilenceKey, enabled);
    _notify({MusicAspect.settings});
  }

  /// Off also drops the autoplay songs still to come; on queues some now if
  /// the queue is close to running out.
  Future<void> setAutoplay(bool enabled) async {
    autoplay = enabled;
    _prefs?.setBool(_autoplayKey, enabled);
    _notify({MusicAspect.settings});
    if (enabled) return _topUpQueue();
    // Only songs still to come; one already playing keeps playing.
    final length = player.sequence.length;
    final from = max(autoplayStart, (player.currentIndex ?? -1) + 1);
    if (from < length) await player.removeAudioSourceRange(from, length);
  }

  void setVisualizerStyle(VisualizerStyle style) {
    visualizerStyle = style;
    _prefs?.setString(_visualizerStyleKey, style.name);
    _notify({MusicAspect.settings});
  }

  void setVisualizerEnabled(bool enabled) {
    visualizerEnabled = enabled;
    _prefs?.setBool(_visualizerEnabledKey, enabled);
    _notify({MusicAspect.settings});
  }

  void setEqualizerEnabled(bool enabled) {
    equalizerEnabled = enabled;
    equalizer?.setEnabled(enabled);
    _prefs?.setBool(_equalizerEnabledKey, enabled);
    _notify({MusicAspect.settings});
  }

  /// Sets every band's gain at once, e.g. from a preset, and saves them.
  Future<void> setEqualizerGains(List<double> gains) async {
    final params = await equalizer?.parameters;
    if (params == null) return;
    for (final band in params.bands) {
      if (band.index < gains.length) await band.setGain(gains[band.index]);
    }
    saveEqualizerGains(params);
  }

  /// Persists the bands' current gains, after a slider is released.
  void saveEqualizerGains(AndroidEqualizerParameters params) {
    _equalizerGains = [for (final band in params.bands) band.gain];
    _prefs?.setStringList(_equalizerGainsKey, [for (final g in _equalizerGains) '$g']);
    _notify({MusicAspect.settings});
  }

  void setHistoryPaused(bool paused) {
    historyPaused = paused;
    _prefs?.setBool(_historyPausedKey, paused);
    _notify({MusicAspect.settings});
  }

  /// Forgets what was played, which also resets History, the charts and
  /// listening stats.
  void clearHistory() {
    _log?.clear();
    _listenWatch.reset();
    _forgetListenFacts();
    _changed.add(MusicAspect.stats);
    _historyIds.clear();
    _playCounts.clear();
    _saveIds(_historyKey, _historyIds);
    _invalidateHistory();
    _prefs?.remove(_playCountsKey);
    _notify({MusicAspect.history});
  }

  void setSearchHistoryPaused(bool paused) {
    searchHistoryPaused = paused;
    _prefs?.setBool(_searchHistoryPausedKey, paused);
    _notify({MusicAspect.settings});
  }

  void clearSearchHistory() {
    _recentSearches.clear();
    _prefs?.remove(_searchesKey);
    _notify({MusicAspect.searches});
  }

  int get librarySizeBytes => songs.fold(0, (sum, s) => sum + s.size);

  // ---------------------------------------------------------------------------
  // Listening stats

  ListeningLog? _log;

  /// Time spent actually playing the current song, since the last saved piece.
  final _listenWatch = Stopwatch();
  Song? _listeningTo;

  /// Whether the next piece continues a listen already partly saved.
  bool _listenContinues = false;
  Timer? _listenTimer;
  final _statsCache = <(StatsRange, int), ListeningStats>{};

  /// Starts or stops the stopwatch as playback starts, pauses or changes song.
  void _updateListening() {
    final song = currentSong;
    final state = player.playerState;
    final playing = song != null && state.playing && state.processingState == ProcessingState.ready;
    if (song != _listeningTo) {
      _commitListen(continuing: false);
      _listeningTo = song;
    }
    if (playing && !_listenWatch.isRunning) {
      _listenWatch.start();
      // Save progress regularly so a closed app loses at most 30 seconds.
      _listenTimer ??= Timer.periodic(const Duration(seconds: 30), (_) => _commitListen(continuing: true));
    } else if (!playing && _listenWatch.isRunning) {
      _listenWatch.stop();
      _listenTimer?.cancel();
      _listenTimer = null;
      // Save on pause, so stats are exact the moment playback stops.
      _commitListen(continuing: true);
    }
  }

  // Carrying on where long listens were left (see [ResumePoints]).

  ResumePoints _resume = ResumePoints();

  /// Where [song] was left off, if it's partway through.
  Duration? resumeAt(Song song) => _resume.of(song);

  /// How far through [song] is, 0..1, if it's partway through.
  double? resumeProgress(Song song) => _resume.progressOf(song);

  /// The resumable song in the player, and its position as last seen while
  /// it played or paused (null until then: a song just switched to can
  /// still report the last one's position, or 0:00 on its way to its place).
  Song? _resumeSong;
  Duration? _resumePosition;

  /// Whether the song's saved place has been gone back to, and whether
  /// that's waiting to happen.
  bool _resumeApplied = false;
  bool _resumePending = false;
  Timer? _resumeTimer;

  /// Follows the song in the player: notes its place every few seconds while
  /// it plays, and saves it on pausing or moving to another song.
  void _updateResume() {
    final song = currentSong;
    if (song?.id != _resumeSong?.id) {
      _saveResume();
      _resumeSong = song != null && ResumePoints.isResumable(song) ? song : null;
      _resumePosition = null;
      _resumeApplied = false;
    }
    final ready = _resumeSong != null && player.processingState == ProcessingState.ready;
    if (ready) _applyResume();
    if (ready && player.playing) {
      _resumeTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
        if (!_resumeApplied) return;
        _resumePosition = player.position;
        _saveResume(quiet: true);
      });
    } else {
      _resumeTimer?.cancel();
      _resumeTimer = null;
      // Paused where it is (not mid-skip, where it isn't settled yet).
      if (ready && _resumeApplied) _resumePosition = player.position;
      _saveResume();
    }
  }

  /// Saves [_resumeSong]'s place, if it's known. Unless [quiet], rows
  /// showing its progress are told.
  void _saveResume({bool quiet = false}) {
    final song = _resumeSong, position = _resumePosition;
    if (song == null || position == null || !_resume.save(song, position)) return;
    _prefs?.setStringList(_resumeKey, _resume.encode());
    if (!quiet) _notify({MusicAspect.playback});
  }

  /// Goes back to where the song now in the player was left, once, unless
  /// it's already been moved past the start (a restored queue, a seek). Not
  /// straight away: a skip to the song sends it to its start, and that can
  /// land after the player says it's ready.
  void _applyResume() {
    final song = _resumeSong;
    if (song == null || _resumeApplied || _resumePending) return;
    _resumePending = true;
    Future.delayed(const Duration(milliseconds: 300), () {
      _resumePending = false;
      if (_resumeSong?.id != song.id) return;
      _resumeApplied = true;
      final at = _resume.of(song);
      if (at != null && player.position < const Duration(seconds: 3)) player.seek(at);
    });
  }

  // Backups (see [Backup]).

  /// What a backup carries: the user's songs, playlists and history, and
  /// their settings. Not the queue, which is only where they were.
  static const _songKeys = {
    _favouritesKey: SongIds.list,
    _historyKey: SongIds.list,
    _playCountsKey: SongIds.keyed,
    _resumeKey: SongIds.keyed,
    _playlistsKey: SongIds.playlists,
    _ratingsKey: SongIds.keyed,
  };
  static const _backedUpSettings = [
    _searchesKey,
    _seekSecondsKey,
    _skipSilenceKey,
    _waveformSeekBarKey,
    _browseFoldersKey,
    _equalizerEnabledKey,
    _equalizerGainsKey,
    _historyPausedKey,
    _searchHistoryPausedKey,
    _visualizerStyleKey,
    _visualizerEnabledKey,
    _autoplayKey,
    _hiddenFoldersKey,
    _minSongSecondsKey,
    _speedKey,
    _normalizeKey,
    _fadeKey,
    _smartPlaylistsKey,
  ];

  /// A backup of everything the user has made and set, as a file's text.
  String createBackup() {
    final prefs = _prefs!;
    return Backup.create(
      saved: {
        for (final key in [..._songKeys.keys, ..._backedUpSettings]) key: ?prefs.get(key),
      },
      songKeys: _songKeys,
      listens: _log?.events ?? const [],
      // Hidden songs too: a backup is of everything.
      songsById: _scannedById,
      now: DateTime.now(),
    );
  }

  /// Replaces everything a backup carries with [text]'s. The app should be
  /// restarted after, so every screen loads it afresh. Throws
  /// [FormatException] if [text] isn't a backup.
  Future<RestoredBackup> restoreBackup(String text) async {
    final restored = Backup.restore(text, songKeys: _songKeys, library: _scanned);
    await closePlayer();
    final prefs = _prefs!;
    for (final key in [..._songKeys.keys, ..._backedUpSettings]) {
      await switch (restored.saved[key]) {
        final bool v => prefs.setBool(key, v),
        final int v => prefs.setInt(key, v),
        final double v => prefs.setDouble(key, v),
        final String v => prefs.setString(key, v),
        final List<Object?> v => prefs.setStringList(key, [for (final item in v) '$item']),
        _ => prefs.remove(key),
      };
    }
    await prefs.remove(_queueKey);
    await prefs.remove(_queuePositionKey);
    await _log?.replaceWith(restored.listens);
    return restored;
  }

  /// Saves the time listened since the last piece. With [continuing], the
  /// same song keeps playing and its next piece joins this listen.
  void _commitListen({required bool continuing}) {
    final song = _listeningTo, log = _log;
    final ms = _listenWatch.elapsedMilliseconds;
    _listenWatch.reset();
    final save = song != null && log != null && ms >= 1000 && !historyPaused;
    if (save) {
      log.append(ListenEvent(songId: song.id, endedAt: DateTime.now(), listenedMs: ms, continued: _listenContinues));
      _forgetListenFacts();
      _notify({MusicAspect.stats});
    }
    // The next piece continues this listen only if part of it is saved; an
    // empty save (e.g. while the next song loads) must not link two songs.
    _listenContinues = continuing && song != null && (save || _listenContinues);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The app may be closed from the background without warning.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _commitListen(continuing: true);
      _saveQueuePosition();
    }
    // Back from system settings, where access may have been granted.
    if (state == AppLifecycleState.resumed && status == LibraryStatus.permissionDenied) {
      _hasPermission().then((granted) {
        if (granted && status == LibraryStatus.permissionDenied) load();
      });
    }
  }

  /// Stats for a day, week, month or all time; [offset] steps back to
  /// earlier periods. Includes the song playing right now.
  ListeningStats statsFor(StatsRange range, {int offset = 0}) {
    final now = DateTime.now();
    final pending = _pendingListen(now);
    if (pending == null) {
      final cached = _statsCache[(range, offset)];
      if (cached != null) return cached;
    }
    final stats = computeStats(
      events: [...?_log?.events, ?pending],
      songsById: _songsById,
      period: StatsPeriod(range, now: now, offset: offset),
      now: now,
      creditsOf: _credits.split,
    );
    if (pending == null) _statsCache[(range, offset)] = stats;
    return stats;
  }

  /// Every listen, with the one in progress, oldest first.
  List<ListenEvent> get _listens => [...?_log?.events, ?_pendingListen(DateTime.now())];

  // Worked out from the listening history when first asked, and again after
  // it changes (see [_forgetListenFacts]).
  Streak? _streak;
  List<ListeningBadge>? _badges;
  DateTime? _streakDay;
  (DateTime, List<TimeTrip>)? _timeTrips;

  /// Works out [fact] from every listen with the one in progress. The answer
  /// is kept only while nothing is playing, as the song playing grows by the
  /// second and may soon count as a play, and only for today, as a streak
  /// ends at midnight without anything being played.
  T _withPending<T extends Object>(T? cached, void Function(T) keep, T Function(List<ListenEvent>, DateTime) fact) {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    final pending = _pendingListen(now);
    if (day != _streakDay) {
      _streakDay = day;
      _streak = null;
      _badges = null;
    } else if (cached != null && pending == null) {
      return cached;
    }
    final answer = fact([...?_log?.events, ?pending], now);
    if (pending == null) keep(answer);
    return answer;
  }

  /// Days in a row with music played.
  Streak get streak => _withPending(_streak, (s) => _streak = s, listeningStreak);

  /// Every badge, earned or not.
  List<ListeningBadge> get badges => _withPending(
        _badges,
        (b) => _badges = b,
        (events, _) => computeBadges(
          events: events,
          songsById: _songsById,
          albums: albums,
          librarySize: songs.length,
          creditsOf: _credits.split,
        ),
      );

  /// Weeks in the past worth going back to, for Home's Time machine. They
  /// only change with the date, as they're at least a month back.
  List<TimeTrip> get timeTrips {
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day);
    if (_timeTrips case (final cachedDay, final trips) when cachedDay == day) return trips;
    final trips = findTimeTrips(events: _log?.events ?? const [], songsById: _songsById, now: day);
    _timeTrips = (day, trips);
    return trips;
  }

  /// The years with something played, newest first, each with a Top songs
  /// playlist.
  List<int> get chartYears => _yearCharts.keys.toList();

  /// [year]'s most played songs, most first.
  List<Song> topSongsOf(int year) => _yearCharts[year]?.songs ?? const [];

  /// How many times [song] was played in [year], if it's in that year's chart.
  int playsIn(int year, Song song) => _yearCharts[year]?.plays[song.id] ?? 0;

  // Only saved listens count, as these are kept until the next one is saved:
  // the song playing joins its year's chart when it ends.
  Map<int, ({List<Song> songs, Map<int, int> plays})> get _yearCharts => _yearChartsCache ??= {
        for (final MapEntry(key: year, value: chart)
            in topSongsByYear(_log?.events ?? const [], _songsById).entries)
          year: (songs: [for (final s in chart) s.song], plays: {for (final s in chart) s.song.id: s.plays}),
      };
  Map<int, ({List<Song> songs, Map<int, int> plays})>? _yearChartsCache;

  /// What the listening history says about [song].
  SongDna songDnaOf(Song song) => songDna(song, _listens, DateTime.now());

  /// After the listening history changes.
  void _forgetListenFacts() {
    _statsCache.clear();
    _lastPlayed = null;
    _streak = null;
    _badges = null;
    _timeTrips = null;
    _yearChartsCache = null;
  }

  /// The not-yet-saved part of the current listen, if any.
  ListenEvent? _pendingListen(DateTime now) {
    final song = _listeningTo, ms = _listenWatch.elapsedMilliseconds;
    if (song == null || ms < 1000 || historyPaused) return null;
    final event = ListenEvent(songId: song.id, endedAt: now, listenedMs: ms, continued: _listenContinues);
    event.countsAsPlay = _log?.wouldCountAsPlay(event) ?? false;
    return event;
  }

  // ---------------------------------------------------------------------------
  // Favourites and search history

  List<Song>? _favouriteSongs;
  Set<int>? _favouriteSet;

  List<Song> get favouriteSongs =>
      _favouriteSongs ??= _favouriteIds.map((id) => _songsById[id]).whereType<Song>().toList();

  bool isFavourite(Song song) => (_favouriteSet ??= _favouriteIds.toSet()).contains(song.id);

  void toggleFavourite(Song song) {
    if (!_favouriteIds.remove(song.id)) _favouriteIds.insert(0, song.id);
    _favouriteSongs = null;
    _favouriteSet = null;
    _saveIds(_favouritesKey, _favouriteIds);
    _notify({MusicAspect.favourites});
  }

  // ---------------------------------------------------------------------------
  // Ratings

  /// Stars out of five, by song id; unrated songs aren't in it.
  Map<int, int> _ratings = {};

  /// The song's stars, 1 to 5; 0 if it isn't rated.
  int rating(Song song) => _ratings[song.id] ?? 0;

  /// Rates [song] 1 to 5 stars; 0 takes its rating away. Told with the
  /// favourites, which also say what the user thinks of a song.
  void setRating(Song song, int stars) {
    if (stars <= 0) {
      _ratings.remove(song.id);
    } else {
      _ratings[song.id] = stars.clamp(1, 5);
    }
    _prefs?.setStringList(_ratingsKey, [for (final MapEntry(:key, :value) in _ratings.entries) '$key:$value']);
    _notify({MusicAspect.favourites});
  }

  /// Rated one star: never picked for the user (Quick picks, autoplay,
  /// radio), though it still plays when chosen.
  bool isUnwanted(Song song) => _ratings[song.id] == 1;

  /// When each song was last listened to, from the listening log.
  Map<int, DateTime>? _lastPlayed;

  /// When [song] was last listened to; null if never (or not since history
  /// was cleared).
  DateTime? lastPlayed(Song song) => (_lastPlayed ??= {
    for (final event in _log?.events ?? const <ListenEvent>[]) event.songId: event.endedAt,
  })[song.id];

  /// Before [gone]'s file is thrown away as a copy of [kept]: moves what the
  /// user has said about it over to [kept], so it stays a favourite, in its
  /// playlists, rated, and counted.
  void mergeSongInto(Song gone, Song kept) {
    if (_favouriteIds.contains(gone.id)) {
      final at = _favouriteIds.indexOf(gone.id);
      _favouriteIds.remove(gone.id);
      if (!_favouriteIds.contains(kept.id)) _favouriteIds.insert(at, kept.id);
      _favouriteSongs = null;
      _favouriteSet = null;
      _saveIds(_favouritesKey, _favouriteIds);
    }
    for (final playlist in _playlists) {
      final at = playlist.songIds.indexOf(gone.id);
      if (at < 0) continue;
      playlist.songIds.removeAt(at);
      if (!playlist.songIds.contains(kept.id)) playlist.songIds.insert(at, kept.id);
      _playlistSongs.remove(playlist.id);
    }
    _prefs?.setString(_playlistsKey, encodePlaylists(_playlists));
    if (_ratings.remove(gone.id) case final stars? when !_ratings.containsKey(kept.id)) _ratings[kept.id] = stars;
    _prefs?.setStringList(_ratingsKey, [for (final MapEntry(:key, :value) in _ratings.entries) '$key:$value']);
    if (_playCounts.remove(gone.id) case final plays?) {
      _playCounts[kept.id] = (_playCounts[kept.id] ?? 0) + plays;
      _prefs?.setStringList(_playCountsKey, [for (final MapEntry(:key, :value) in _playCounts.entries) '$key:$value']);
      _invalidateHistory();
    }
    _notify({MusicAspect.favourites, MusicAspect.playlists, MusicAspect.history});
  }

  // ---------------------------------------------------------------------------
  // Smart playlists

  /// Newest first.
  List<SmartPlaylist> _smartPlaylists = [];

  List<SmartPlaylist> get smartPlaylists => List.unmodifiable(_smartPlaylists);

  SmartPlaylist? smartPlaylistWithId(String id) => _smartPlaylists.where((p) => p.id == id).firstOrNull;

  late final _smartFacts = SmartFacts(
    plays: playCount,
    rating: rating,
    lastPlayed: lastPlayed,
    isFavourite: isFavourite,
    historyRank: (song) => lastPlayedRank([song]),
  );

  /// The library's songs that [playlist] picks, in its order; also the
  /// editor's preview of one not saved yet.
  List<Song> smartPlaylistSongs(SmartPlaylist playlist) => pickSmartPlaylistSongs(playlist, songs, _smartFacts);

  void _saveSmartPlaylists() {
    _prefs?.setString(_smartPlaylistsKey, encodeSmartPlaylists(_smartPlaylists));
    _notify({MusicAspect.playlists});
  }

  /// Adds [playlist], or saves the changes to it if it's already here.
  void saveSmartPlaylist(SmartPlaylist playlist) {
    final at = _smartPlaylists.indexWhere((p) => p.id == playlist.id);
    if (at < 0) {
      _smartPlaylists.insert(0, playlist);
    } else {
      _smartPlaylists[at] = playlist;
    }
    _saveSmartPlaylists();
  }

  void deleteSmartPlaylist(SmartPlaylist playlist) {
    _smartPlaylists.removeWhere((p) => p.id == playlist.id);
    _saveSmartPlaylists();
  }

  /// Puts a deleted [playlist] back where it was, to undo [deleteSmartPlaylist].
  void restoreSmartPlaylist(SmartPlaylist playlist, int index) {
    _smartPlaylists.insert(index.clamp(0, _smartPlaylists.length), playlist);
    _saveSmartPlaylists();
  }

  // ---------------------------------------------------------------------------
  // Lyrics search: every song's lyrics, read in the background (see
  // [LyricsIndex]).

  LyricsIndex? _lyrics;

  /// A stamp for each song's files as of the last scan, by id (see
  /// [MediaLibrary.lyricsStamps]); songs are read again when it changes.
  final Map<int, String> _lyricStamps = {};

  /// Whether songs' lyrics are being read.
  bool get indexingLyrics => _indexingLyrics;
  bool _indexingLyrics = false;

  /// Asked to look again while reading: songs may have come in meanwhile.
  bool _indexLyricsAgain = false;

  /// Reads the lyrics of songs not read yet, or changed since, a batch at a
  /// time, saving as it goes. Quick after the first time: only new and
  /// changed files are read. Asked again while already reading, it looks
  /// again once it's done.
  Future<void> _indexLyrics() async {
    final index = _lyrics;
    if (index == null) return;
    if (_indexingLyrics) {
      _indexLyricsAgain = true;
      return;
    }
    _indexingLyrics = true;
    _notify({MusicAspect.searches});
    try {
      do {
        _indexLyricsAgain = false;
        await _indexLyricsOnce(index);
      } while (_indexLyricsAgain);
    } on Object {
      // Couldn't read or save: the next scan tries the rest again.
    } finally {
      _indexingLyrics = false;
      _notify({MusicAspect.searches});
    }
  }

  Future<void> _indexLyricsOnce(LyricsIndex index) async {
    final library = songs;
    final unstamped = [for (final s in library) if (!_lyricStamps.containsKey(s.id)) s];
    if (unstamped.isNotEmpty) _lyricStamps.addAll(await MediaLibrary.lyricsStamps(unstamped));
    final pending = [
      for (final s in library)
        if (_lyricStamps[s.id] case final stamp? when !index.has(s, stamp)) (s, stamp),
    ];
    // Songs no longer found (deleted, say) are forgotten. Hidden ones are
    // kept, for when their folder is shown again.
    var changed = _scannedById.isNotEmpty && index.keepOnly(_scannedById.keys.toSet());
    for (var i = 0; i < pending.length; i += 50) {
      final batch = pending.skip(i).take(50).toList();
      final texts = await MediaLibrary.readLyrics([for (final (song, _) in batch) song]);
      if (texts == null) continue;
      final parsed = await LyricsIndex.parse(texts);
      for (final (song, stamp) in batch) {
        // Left out: its file couldn't be opened, so it's tried again later.
        if (parsed[song.id] case final lyrics?) index.put(song, stamp, lyrics);
      }
      changed = true;
      _lyricSearch = null;
      // Results show up as they're read.
      _notify({MusicAspect.searches});
      // Saved every so often rather than after each batch: the file grows
      // to a few megabytes.
      if ((i ~/ 50) % 10 == 9) await index.save();
    }
    if (changed) await index.save();
  }

  /// The last lyrics search, kept so the screen rebuilding doesn't search
  /// again; cleared when the library or what's been read changes.
  (String, List<LyricMatch>)? _lyricSearch;

  /// Songs whose lyrics have [query] in them (see [searchLyrics]).
  List<LyricMatch> searchLyricsFor(String query) {
    final index = _lyrics;
    if (index == null) return const [];
    if (_lyricSearch case (final last, final found) when last == query) return found;
    final found = searchLyrics(query, [
      for (final song in songs)
        if (index.of(song) case final lyrics?) (song, lyrics),
    ]);
    _lyricSearch = (query, found);
    return found;
  }

  // ---------------------------------------------------------------------------
  // Volume: normalisation, fading between songs, and the sleep timer's fade

  /// Whether songs are turned up or down to play about as loud as each other.
  bool normalizeVolume = false;

  /// How long songs fade out at their end and in at their start when one
  /// follows another; 0 for none. (Only one song can play at a time, so they
  /// fade rather than overlap.)
  int fadeSeconds = 0;

  static const fadeSecondsOptions = [0, 2, 4, 6, 8, 10];

  /// The parts of the player's volume, multiplied together.
  double _gainVolume = 1, _fadeVolume = 1, _sleepVolume = 1;
  double? _volumeSent;

  /// The app's own volume, 0 to 1, under the system's: the desktop mini
  /// player's slider. Phones leave it at 1 and use their volume buttons.
  final volume = ValueNotifier<double>(1);

  /// Sets [volume]; [save] false while a slider is still being dragged.
  void setVolume(double value, {bool save = true}) {
    volume.value = value.clamp(0.0, 1.0);
    if (save) _prefs?.setDouble(_volumeKey, volume.value);
    _applyVolume();
  }

  void _applyVolume() {
    // Squared, so the slider's steps sound about even: loudness isn't linear.
    final user = volume.value * volume.value;
    final level = (user * _gainVolume * _fadeVolume * _sleepVolume).clamp(0.0, 1.0);
    if (_volumeSent != null && (level - _volumeSent!).abs() < 0.005) return;
    _volumeSent = level;
    player.setVolume(level);
  }

  void _setSleepVolume(double volume) {
    _sleepVolume = volume;
    _applyVolume();
  }

  void setNormalizeVolume(bool enabled) {
    normalizeVolume = enabled;
    _prefs?.setBool(_normalizeKey, enabled);
    _booster?.setEnabled(enabled);
    _gainSongId = null;
    _updateGain();
    _notify({MusicAspect.settings});
  }

  void setFadeSeconds(int seconds) {
    fadeSeconds = seconds;
    _prefs?.setInt(_fadeKey, seconds);
    _updateFading();
    _notify({MusicAspect.settings});
  }

  /// The song [_gainVolume] and the booster are set for.
  int? _gainSongId;

  /// The most a song is turned up by, so a very quiet one isn't distorted.
  static const _maxBoostDb = 6.0;

  /// The most a song is turned down by.
  static const _maxCutDb = 12.0;

  /// Sets the volume for the song now playing, once its gain is known (at
  /// once, after the first time). Until then it plays as it is.
  void _updateGain() {
    final song = currentSong;
    if (song?.id == _gainSongId) return;
    _gainSongId = song?.id;
    _gainVolume = 1;
    _booster?.setTargetGain(0);
    _applyVolume();
    if (song == null || !normalizeVolume) return;
    MediaLibrary.getGain(song).then((gain) {
      if (gain == null || _gainSongId != song.id || !normalizeVolume) return;
      final db = gain.clamp(-_maxCutDb, _maxBoostDb);
      // Down with the player's volume; up with the booster.
      _gainVolume = db < 0 ? pow(10, db / 20).toDouble() : 1;
      _booster?.setTargetGain(db > 0 ? db : 0);
      _applyVolume();
    });
  }

  Timer? _fadeTimer;

  /// The queue item that started by following the one before, so fades in.
  int? _fadeInIndex;

  /// Runs [_fade] while music plays with fading on.
  void _updateFading() {
    final run = fadeSeconds > 0 && player.playing;
    if (run && _fadeTimer == null) {
      _fadeTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => _fade());
    } else if (!run && _fadeTimer != null) {
      _fadeTimer!.cancel();
      _fadeTimer = null;
    }
    if (fadeSeconds == 0 && _fadeVolume != 1) {
      _fadeVolume = 1;
      _applyVolume();
    }
  }

  /// Fades the song out over its last [fadeSeconds] when another follows,
  /// and in over its first when it followed one. Short songs fade over at
  /// most a third of their length.
  void _fade() {
    final duration = player.duration;
    if (duration == null || duration <= Duration.zero) return;
    final position = player.position;
    final fade = Duration(seconds: fadeSeconds) < duration ~/ 3 ? Duration(seconds: fadeSeconds) : duration ~/ 3;
    final ms = fade.inMilliseconds;
    if (ms <= 0) return;

    var volume = 1.0;
    final follows = player.hasNext && player.loopMode != LoopMode.one;
    if (follows) volume = min(volume, (duration - position).inMilliseconds / ms);
    if (_fadeInIndex == player.currentIndex) {
      if (position < fade) {
        volume = min(volume, position.inMilliseconds / ms);
      } else {
        _fadeInIndex = null;
      }
    }
    _fadeVolume = volume.clamp(0.0, 1.0);
    _applyVolume();
  }

  // ---------------------------------------------------------------------------
  // Sleep timer

  /// When the sleep timer pauses the music; null when it's off or set to
  /// [sleepAtEndOfSong].
  DateTime? sleepAt;

  /// Whether the sleep timer pauses the music when the playing song ends.
  bool sleepAtEndOfSong = false;

  bool get sleepTimerOn => sleepAt != null || sleepAtEndOfSong;

  /// The last stretch of a timed sleep, over which the music fades out.
  static const _sleepFade = Duration(seconds: 12);

  Timer? _sleepTimer;
  StreamSubscription<Duration>? _sleepPositionSub;
  int? _sleepSongIndex;

  void setSleepTimer(Duration after) {
    cancelSleepTimer();
    sleepAt = DateTime.now().add(after);
    _sleepTimer = Timer(after > _sleepFade ? after - _sleepFade : Duration.zero, _fadeToSleep);
    _notify({MusicAspect.playback});
  }

  /// Pauses when the playing song finishes, before the next one starts.
  void setSleepAtEndOfSong() {
    cancelSleepTimer();
    sleepAtEndOfSong = true;
    _sleepSongIndex = player.currentIndex;
    var nearEnd = false;
    _sleepPositionSub = player.positionStream.listen((position) {
      final left = (player.duration ?? Duration.zero) - position;
      if (player.currentIndex != _sleepSongIndex) {
        // Played on into the next song between position updates: stop at
        // its start. Skipped to it instead: wait for that song to end.
        if (nearEnd) return unawaited(_sleep(restart: true));
        _sleepSongIndex = player.currentIndex;
      } else if (player.duration != null && left < const Duration(milliseconds: 400)) {
        unawaited(_sleep());
      }
      nearEnd = player.duration != null && left < const Duration(seconds: 2);
    });
    _notify({MusicAspect.playback});
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepPositionSub?.cancel();
    _sleepPositionSub = null;
    final wasOn = sleepTimerOn;
    sleepAt = null;
    sleepAtEndOfSong = false;
    // Cancelled partway through the fade.
    _setSleepVolume(1);
    if (wasOn) _notify({MusicAspect.playback});
  }

  /// Turns the volume down bit by bit over [_sleepFade], then pauses.
  void _fadeToSleep() {
    const steps = 24;
    var step = 0;
    _sleepTimer = Timer.periodic(_sleepFade ~/ steps, (timer) {
      step++;
      _setSleepVolume(1 - step / steps);
      if (step >= steps) _sleep();
    });
  }

  /// Pauses for the sleep timer and switches it off. [restart] goes back to
  /// the start of the playing song, for when play is pressed again.
  ///
  /// At the end of a song it just pauses, in its last moment: lining up the
  /// next song instead would count as a skip, which plays (see
  /// [_playIfSkipped]).
  Future<void> _sleep({bool restart = false}) async {
    _sleepTimer?.cancel();
    _sleepPositionSub?.cancel();
    await player.pause();
    // Only once paused, so the volume doesn't come back up while playing.
    cancelSleepTimer();
    if (restart) await player.seek(Duration.zero);
  }

  // ---------------------------------------------------------------------------
  // Playlists

  /// Newest first.
  List<Playlist> _playlists = [];
  final _playlistSongs = <String, List<Song>>{};

  List<Playlist> get playlists => List.unmodifiable(_playlists);

  Playlist? playlistWithId(String id) => _playlists.where((p) => p.id == id).firstOrNull;

  /// The playlist's songs that are in the library, in its order.
  List<Song> playlistSongs(Playlist playlist) => _playlistSongs[playlist.id] ??=
      playlist.songIds.map((id) => _songsById[id]).whereType<Song>().toList();

  void _savePlaylists(Playlist? changed) {
    if (changed != null) _playlistSongs.remove(changed.id);
    _prefs?.setString(_playlistsKey, encodePlaylists(_playlists));
    _notify({MusicAspect.playlists});
  }

  /// A new playlist of [songs], each once (an imported M3U may list one
  /// twice), as [addToPlaylist] keeps them.
  Playlist createPlaylist(String name, [List<Song> songs = const []]) {
    final playlist = Playlist(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim(),
      songIds: {for (final s in songs) s.id}.toList(),
      created: DateTime.now(),
    );
    _playlists.insert(0, playlist);
    _savePlaylists(playlist);
    return playlist;
  }

  void renamePlaylist(Playlist playlist, String name) {
    playlist.name = name.trim();
    _savePlaylists(playlist);
  }

  void deletePlaylist(Playlist playlist) {
    _playlists.remove(playlist);
    _savePlaylists(playlist);
  }

  /// Puts a deleted [playlist] back where it was, to undo [deletePlaylist].
  void restorePlaylist(Playlist playlist, int index) {
    _playlists.insert(index.clamp(0, _playlists.length), playlist);
    _savePlaylists(playlist);
  }

  /// Adds those of [songs] not already in [playlist] to its end, returning
  /// how many were added.
  int addToPlaylist(Playlist playlist, List<Song> songs) {
    final present = playlist.songIds.toSet();
    final added = [for (final s in songs) if (present.add(s.id)) s.id];
    playlist.songIds.addAll(added);
    if (added.isNotEmpty) _savePlaylists(playlist);
    return added.length;
  }

  /// Removes the song at [index] of [playlistSongs], returning it.
  Song removeFromPlaylist(Playlist playlist, int index) {
    final song = playlistSongs(playlist)[index];
    playlist.songIds.remove(song.id);
    _savePlaylists(playlist);
    return song;
  }

  /// Puts [song] back at [index] of [playlistSongs], to undo a removal.
  void insertIntoPlaylist(Playlist playlist, int index, Song song) {
    if (playlist.songIds.contains(song.id)) return;
    playlist.songIds.insert(_idIndex(playlist, index), song.id);
    _savePlaylists(playlist);
  }

  /// Moves the song at [from] of [playlistSongs] so it ends up at [to].
  void movePlaylistSong(Playlist playlist, int from, int to) {
    final shown = playlistSongs(playlist);
    if (from == to) return;
    final song = shown[from];
    playlist.songIds.remove(song.id);
    _playlistSongs.remove(playlist.id);
    playlist.songIds.insert(_idIndex(playlist, to), song.id);
    _savePlaylists(playlist);
  }

  /// Where [index] of [playlistSongs] falls in [Playlist.songIds], which also
  /// holds songs that aren't in the library now.
  int _idIndex(Playlist playlist, int index) {
    final shown = playlistSongs(playlist);
    if (index >= shown.length) return playlist.songIds.length;
    return playlist.songIds.indexOf(shown[index].id);
  }

  List<String> get recentSearches => List.unmodifiable(_recentSearches);

  void addRecentSearch(String query) {
    query = query.trim();
    if (query.isEmpty || searchHistoryPaused) return;
    _recentSearches
      ..remove(query)
      ..insert(0, query);
    if (_recentSearches.length > 20) _recentSearches.removeLast();
    _prefs?.setStringList(_searchesKey, _recentSearches);
    _notify({MusicAspect.searches});
  }

  void removeRecentSearch(String query) {
    _recentSearches.remove(query);
    _prefs?.setStringList(_searchesKey, _recentSearches);
    _notify({MusicAspect.searches});
  }

  // ---------------------------------------------------------------------------
  // Playback

  Song? get currentSong => _loadingSong ?? songOf(player.sequenceState.currentSource);

  /// The song a new queue starts at, while [_setQueue] loads it. Until it's
  /// loaded the player shows the new list but keeps its old place in it, so
  /// it would report whichever song sits at that place: the song that was
  /// just playing or closed, if it's from the same list.
  Song? _loadingSong;

  /// The song a queue item plays. Queue items carry a [MediaItem] (what the
  /// notification and lock screen show) whose id is the song's id.
  Song? songOf(IndexedAudioSource? source) => switch (source?.tag) {
        final MediaItem item => switch (int.tryParse(item.id)) {
          final id => _scannedById[id] ?? _opened[id],
        },
        _ => null,
      };

  /// Songs opened with Blimp that aren't in the library, by id: from
  /// outside the music folder, or another app's file on the phone.
  final Map<int, Song> _opened = {};

  /// Plays files opened with Blimp (or dragged onto it on desktop), once the
  /// app has started. On desktop each is a path, perhaps a folder; on the
  /// phone a URI, with the library's id for it when Android knows it.
  Future<void> playOpened(List<({String? path, String? uri, int? id, String? name})> files) async {
    await ready;
    final List<Song> list;
    if (isDesktop) {
      list = await DesktopLibrary.songsAt([for (final f in files) ?f.path], known: (id) => _scannedById[id]);
    } else {
      list = [
        for (final f in files)
          if (_scannedById[f.id] case final song?)
            song
          else if (f.uri case final uri?)
            Song(
              id: DesktopLibrary.stableId(uri),
              title: switch (f.name) {
                final name? when name.contains('.') => name.substring(0, name.lastIndexOf('.')),
                final name? => name,
                null => 'Unknown title',
              },
              uri: uri,
            ),
      ];
    }
    for (final song in list) {
      if (!_scannedById.containsKey(song.id)) _opened[song.id] = song;
    }
    await playSongs(list);
  }

  static AudioSource _source(Song song, {bool autoplay = false}) => AudioSource.uri(
        Uri.parse(song.uri),
        tag: MediaItem(
          id: '${song.id}',
          title: song.title,
          artist: song.artistName,
          album: song.album,
          duration: song.duration == Duration.zero ? null : song.duration,
          // The song's own content URI: Android reads its embedded cover.
          artUri: Uri.parse(song.uri),
          extras: {'loadThumbnailUri': song.uri, if (autoplay) 'autoplay': true},
        ),
      );

  /// Whether [source] was queued by autoplay rather than by the user.
  static bool isAutoplay(IndexedAudioSource source) => switch (source.tag) {
        final MediaItem item => item.extras?['autoplay'] == true,
        _ => false,
      };

  /// Where the autoplay songs at the end of the queue start, in queue order
  /// (the queue's length when there are none). Up next lists them apart.
  int get autoplayStart {
    final sequence = player.sequence;
    var start = sequence.length;
    while (start > 0 && isAutoplay(sequence[start - 1])) {
      start--;
    }
    return start;
  }

  /// Plays [list] from [index]. A long list is queued a batch at a time:
  /// [_batchSize] songs either side of [index], then more as playback nears
  /// the end of the queue, so even the whole library starts at once.
  ///
  /// Songs before [index] are only ever queued up front: inserting ahead of
  /// the playing song makes just_audio briefly report the wrong one as
  /// current (and count it as played), and can desync its shuffle order.
  Future<void> playSongs(List<Song> list, {int index = 0, bool shuffle = false, Duration? at}) async {
    if (list.isEmpty) return;
    if (shuffle) {
      list = [...list]..shuffle();
      index = 0;
    }
    index = index.clamp(0, list.length - 1);
    final start = max(0, index - _batchSize);
    final end = min(list.length, index + _batchSize);
    _upcoming = list.sublist(end);
    await player.setShuffleModeEnabled(false);
    if (_unshuffled != null) {
      _unshuffled = null;
      _shufflingChanges.add(false);
    }
    await _setQueue(list.sublist(start, end).map(_source).toList(), index: index - start, at: at);
    player.play();
    await _topUpQueue();
  }

  /// Loads [sources] into the player, at [index], [at] into it if given.
  Future<void> _setQueue(List<AudioSource> sources, {required int index, Duration? at}) async {
    // Nothing may be added until the player has loaded the new list: added
    // meanwhile, the player loads without it and the two queues fall out of
    // step (and every later change to the queue fails).
    _settingQueue = true;
    _loadingSong = songOf(sources[index] as IndexedAudioSource);
    try {
      await player.setAudioSources(
        sources,
        initialIndex: index,
        initialPosition: at,
        shuffleOrder: _shuffleOrder = QueueShuffleOrder(isAutoplay: (i) {
          final sequence = player.sequence;
          return i < sequence.length && isAutoplay(sequence[i]);
        }),
      );
    } finally {
      _settingQueue = false;
      _loadingSong = null;
      // Take in the loaded queue now if the player is already in place;
      // otherwise its next update, when it gets there, will do.
      if (player.sequenceState.currentIndex == index) _onSequenceState(player.sequenceState);
    }
  }

  /// Whether [_setQueue] is waiting for the player to load a new list.
  bool _settingQueue = false;

  /// The loaded queue's shuffle order, which [moveInQueue] changes.
  QueueShuffleOrder? _shuffleOrder;

  /// Whether shuffle is on, as the shuffle button shows it.
  bool get shuffling => isDesktop ? _unshuffled != null : player.shuffleModeEnabled;

  /// [shuffling]'s changes.
  Stream<bool> get shufflingStream => isDesktop ? _shufflingChanges.stream : player.shuffleModeEnabledStream;
  final _shufflingChanges = StreamController<bool>.broadcast();

  /// On desktop, the user's songs still to come (queued, then [_upcoming])
  /// in the order they had before shuffle; null with shuffle off. The
  /// media_kit player there has no shuffle order of its own to follow
  /// just_audio's, so shuffle reorders the songs themselves instead.
  List<Song>? _unshuffled;

  Future<void> toggleShuffle() async {
    if (!isDesktop) {
      final enabled = player.shuffleModeEnabled;
      if (!enabled) await player.shuffle();
      return player.setShuffleModeEnabled(!enabled);
    }
    // Mid-change, the queue and [_upcoming] are out of step: a batch taken
    // from [_upcoming] but not added yet would be queued twice.
    if (_toppingUp || _settingQueue) return;
    // The user's songs after the current one; autoplay's stay where they are.
    final from = (player.currentIndex ?? -1) + 1;
    final to = max(from, autoplayStart);
    final queued = [for (final source in player.sequence.sublist(from, to)) ?songOf(source)];
    if (queued.length != to - from) return;
    final rest = [...queued, ..._upcoming];
    final List<Song> order;
    if (_unshuffled case final unshuffled?) {
      // Back in the order they had; songs queued since keep their places.
      final rank = <Song, int>{};
      for (final (i, song) in unshuffled.indexed) {
        rank.putIfAbsent(song, () => i);
      }
      final known = [for (final song in rest) if (rank.containsKey(song)) song]
        ..sort((a, b) => rank[a]!.compareTo(rank[b]!));
      var k = 0;
      order = [for (final song in rest) rank.containsKey(song) ? known[k++] : song];
      _unshuffled = null;
    } else {
      _unshuffled = rest;
      order = [...rest]..shuffle();
    }
    _shufflingChanges.add(shuffling);
    // Kept from topping up while the queue is briefly short.
    _toppingUp = true;
    try {
      _upcoming = order.sublist(queued.length);
      if (to > from) await player.removeAudioSourceRange(from, to);
      await player.insertAudioSources(from, order.take(queued.length).map(_source).toList());
    } finally {
      _toppingUp = false;
    }
  }

  /// Moves the song [from] one place in Up next to another, [to] counted
  /// after it's taken out; both are places in play order, so shuffled or not.
  Future<void> moveInQueue(int from, int to) async {
    if (from == to) return;
    if (!player.shuffleModeEnabled) return player.moveAudioSource(from, to);
    final order = _shuffleOrder;
    if (order == null) return;
    // just_audio has no call for changing the shuffle order, but reshuffling
    // sends whatever order there is to Android: the order makes the move
    // instead of shuffling (see [QueueShuffleOrder.shuffle]).
    order.pendingMove = (from: from, to: to);
    await player.shuffle();
  }

  /// Done once the last session's queue is loaded back, or found to be gone.
  final _queueRestored = Completer<void>();

  /// The user's songs in the queue, in play order, then the rest of the list
  /// they're from that isn't queued yet; not autoplay's. What saving the
  /// queue as a playlist saves.
  List<Song> get queuedSongs {
    final state = player.sequenceState;
    return [
      for (final source in state.effectiveSequence)
        if (!isAutoplay(source)) ?songOf(source),
      ..._upcoming,
    ];
  }

  /// Saves the queue, so the next launch (or a home screen widget) can pick
  /// up where it left off. Autoplay's songs are saved with an "a" in front.
  /// An empty queue isn't saved: after the player is closed, the widgets
  /// still offer the last song, and playing it brings that queue back.
  void _saveQueue() {
    final prefs = _prefs;
    final sequence = player.sequence;
    if (prefs == null || sequence.isEmpty || !_queueRestored.isCompleted) return;
    final ids = <String>[];
    var index = 0;
    for (final (i, source) in sequence.indexed) {
      final song = songOf(source);
      if (song == null) continue;
      if (i == player.currentIndex) index = ids.length;
      ids.add('${isAutoplay(source) ? 'a' : ''}${song.id}');
    }
    prefs.setStringList(_queueKey, ids);
    prefs.setInt(_queueIndexKey, index);
    // Desktop shuffle's order to go back to, for the songs saved above (the
    // rest of a long list doesn't come back).
    final unshuffled = _unshuffled;
    if (unshuffled == null) {
      prefs.remove(_unshuffledKey);
    } else {
      final queued = {for (final source in sequence) ?songOf(source)};
      prefs.setStringList(_unshuffledKey, [for (final song in unshuffled) if (queued.contains(song)) '${song.id}']);
    }
  }

  Timer? _queuePositionTimer;

  /// Notes how far into the song the player is every half a minute while
  /// it plays, and when it pauses, so the next launch carries on from there.
  /// While it plays rather than on closing, which may come without warning;
  /// no more often, as each save rewrites all the saved settings.
  void _updateQueuePosition() {
    if (player.playing && player.processingState == ProcessingState.ready) {
      _queuePositionTimer ??= Timer.periodic(const Duration(seconds: 30), (_) => _saveQueuePosition());
    } else {
      _queuePositionTimer?.cancel();
      _queuePositionTimer = null;
      _saveQueuePosition();
    }
  }

  /// Saves the song in the player and how far into it it is. The song goes
  /// with it, so a place in one song is never used for another.
  void _saveQueuePosition() {
    final prefs = _prefs;
    final song = currentSong;
    // Not while a queue loads or a song is still on its way: the player's
    // place is out of date then.
    if (prefs == null || song == null || !_queueRestored.isCompleted || _settingQueue) return;
    // Played to the end: next time it starts again, not a moment from its end.
    if (player.processingState == ProcessingState.completed) {
      prefs.remove(_queuePositionKey);
      return;
    }
    if (player.processingState != ProcessingState.ready) return;
    prefs.setStringList(_queuePositionKey, ['${song.id}', '${player.position.inMilliseconds}']);
  }

  /// Loads the queue saved by [_saveQueue], paused where the song that was
  /// playing was left. Songs since removed from the device are skipped; if
  /// the one that was playing is gone, it starts from the next. Only the queued songs come back, not
  /// the rest of a long list that hadn't been queued yet.
  Future<void> _restoreQueue() async {
    if (_queueRestored.isCompleted) return;
    try {
      final prefs = _prefs;
      // Something started playing first: that wins.
      if (prefs == null || player.sequence.isNotEmpty) return;
      final savedIndex = prefs.getInt(_queueIndexKey) ?? 0;
      final sources = <AudioSource>[];
      int? index;
      Song? current;
      for (final (i, entry) in (prefs.getStringList(_queueKey) ?? const <String>[]).indexed) {
        final autoplay = entry.startsWith('a');
        final song = _scannedById[int.tryParse(autoplay ? entry.substring(1) : entry)];
        if (song == null) continue;
        if (index == null && i >= savedIndex) {
          index = sources.length;
          current = song;
        }
        sources.add(_source(song, autoplay: autoplay));
      }
      if (sources.isEmpty) {
        HomeWidgets.clear();
        return;
      }
      if (index == null) {
        index = sources.length - 1;
        current = songOf(sources.last as IndexedAudioSource);
      }
      // Coming back to a song isn't playing it again.
      _lastRecordedId = current?.id;
      // Shuffled on desktop: still on, with the order to go back to.
      final ids = isDesktop ? prefs.getStringList(_unshuffledKey) : null;
      if (ids != null) {
        _unshuffled = [for (final id in ids) ?_scannedById[int.tryParse(id)]];
        _shufflingChanges.add(true);
      }
      final saved = prefs.getStringList(_queuePositionKey);
      final at = saved != null && saved.length == 2 && saved[0] == '${current?.id}'
          ? Duration(milliseconds: int.tryParse(saved[1]) ?? 0)
          : null;
      await _setQueue(sources, index: index, at: at);
    } catch (_) {
      // Couldn't load it: start empty, as before there was anything to restore.
    } finally {
      _queueRestored.complete();
    }
  }

  /// Does what a home screen widget asked for when it opened the app. Its
  /// buttons only open the app when nothing was loaded, so this waits for
  /// the last queue to come back, then plays or skips in it.
  Future<void> handleWidgetRequest(WidgetRequest request) async {
    if (request == WidgetRequest.shuffleAll) {
      await ready;
      if (songs.isNotEmpty) await playSongs(songs, shuffle: true);
      return;
    }
    // Startup's first load restores the queue, unless there's no access to
    // music yet: then there's nothing to play, rather than a wait that ends
    // in every tap at once if access is granted later.
    await ready;
    if (player.sequence.isEmpty) return;
    switch (request) {
      case WidgetRequest.openPlayer || WidgetRequest.favourites || WidgetRequest.shuffleAll:
        return;
      case WidgetRequest.play:
        break;
      case WidgetRequest.previous:
        await skipToPrevious();
      case WidgetRequest.next:
        if (player.hasNext) await player.seekToNext();
    }
    player.play();
  }

  /// Stops playing and empties the queue, which hides the mini player and
  /// the media notification.
  Future<void> closePlayer() async {
    _upcoming = const [];
    await player.stop();
    await player.clearAudioSources();
  }

  /// The rest of the list being played, not queued yet; it's queued
  /// [_batchSize] at a time as playback nears the end of the queue.
  List<Song> _upcoming = const [];
  bool _toppingUp = false;

  static const _batchSize = 50;

  /// How few songs may be left after the current one before the next batch
  /// is queued.
  static const _topUpThreshold = 10;

  /// How many songs autoplay adds at a time.
  static const _autoplayBatch = 15;

  /// Queues the next batch of the list being played or, once it's all
  /// queued, similar songs (autoplay), when the queue is close to running out.
  Future<void> _topUpQueue() async {
    if (_toppingUp || _settingQueue) return;
    final canAutoplay = autoplay && player.loopMode == LoopMode.off;
    if (_upcoming.isEmpty && !canAutoplay) return;
    final state = player.sequenceState;
    final current = state.currentSource;
    if (current == null) return;
    final order = state.effectiveSequence;
    if (order.length - order.indexOf(current) - 1 > _topUpThreshold) return;

    _toppingUp = true;
    try {
      if (_upcoming.isNotEmpty) {
        final batch = _upcoming.take(_batchSize).toList();
        _upcoming = _upcoming.skip(_batchSize).toList();
        await player.addAudioSources(batch.map(_source).toList());
      } else {
        final batch = _similarSongs(_autoplayBatch);
        if (batch.isNotEmpty) {
          await player.addAudioSources([for (final song in batch) _source(song, autoplay: true)]);
        }
      }
    } finally {
      _toppingUp = false;
    }
  }

  /// Songs like the last few queued: about a third by the same artists, the
  /// rest from the same genres, topped up at random. Never one that's
  /// already queued.
  List<Song> _similarSongs(int count) {
    final sequence = player.sequence;
    final queued = {for (final source in sequence) ?songOf(source)};
    // What the user queued last says most about what they want; once only
    // autoplay songs are left to go by, those carry it on.
    final picked = [for (final source in sequence) if (!isAutoplay(source)) source];
    final seeds = [for (final source in (picked.isEmpty ? sequence : picked).reversed.take(5)) ?songOf(source)];
    return _songsLike(seeds, count, exclude: queued);
  }

  /// [count] songs like [seeds], none of them (or a copy of one) in [exclude]:
  /// about a third by the same artists or off the same albums, the rest from
  /// the same genres. Songs without enough tags to go by (many have no genre)
  /// are filled out with songs from around the same years, then at random.
  List<Song> _songsLike(List<Song> seeds, int count, {required Set<Song> exclude}) {
    final artists = {for (final song in seeds) ?song.artist};
    final albums = {for (final song in seeds) if (song.album case final album? when album.isNotEmpty) album};
    final genres = {for (final song in seeds) ?song.genre};
    final years = {for (final song in seeds) ?song.year};

    // Also by name: libraries often hold the same song twice.
    String nameOf(Song s) => '${s.title.toLowerCase()}|${s.artist?.toLowerCase()}';
    final excludedNames = {for (final song in exclude) nameOf(song)};
    final fresh = songs
        .where((s) => !exclude.contains(s) && !excludedNames.contains(nameOf(s)) && !isUnwanted(s))
        .toList();

    bool close(Song s) => artists.contains(s.artist) || albums.contains(s.album);
    bool sameGenre(Song s) => genres.contains(s.genre);
    bool sameEra(Song s) => switch (s.year) {
          final year? => years.any((y) => (y - year).abs() <= 3),
          null => false,
        };
    List<Song> shuffled(bool Function(Song) test) => fresh.where(test).toList()..shuffle();

    final chosen = <Song>{...shuffled(close).take(count ~/ 3)};
    for (final tier in [sameGenre, sameEra, (Song _) => true]) {
      if (chosen.length >= count) break;
      chosen.addAll(shuffled((s) => !chosen.contains(s) && tier(s)).take(count - chosen.length));
    }
    final names = <String>{};
    return [for (final song in chosen) if (names.add(nameOf(song))) song]..shuffle();
  }

  /// How many songs a radio queues up front; autoplay carries on after.
  static const _radioLength = 25;

  /// Plays [song] followed by songs like it (same artist and genre), from
  /// [at] into it if given.
  Future<void> startRadio(Song song, {Duration? at}) =>
      playSongs([song, ..._songsLike([song], _radioLength - 1, exclude: {song})], at: at);

  /// Back to the start of the song a few seconds in (or with nothing before
  /// it), otherwise to the song before, as players do.
  Future<void> skipToPrevious() => player.position > const Duration(seconds: 3) || !player.hasPrevious
      ? player.seek(Duration.zero)
      : player.seekToPrevious();

  Future<void> playNext(Song song) => playAllNext([song]);

  Future<void> addToQueue(Song song) => addAllToQueue([song]);

  /// Inserts [list] right after the current song, keeping its order.
  Future<void> playAllNext(List<Song> list) async {
    final index = player.currentIndex;
    if (index == null || player.sequence.isEmpty) return playSongs(list);
    // Shuffled, straight after the playing song in play order too.
    _placeInShuffle(index + 1, _playPosition(index) + 1);
    await player.insertAudioSources(index + 1, list.map(_source).toList());
  }

  /// Adds [list] to the end of the user's queue: before autoplay's songs,
  /// so they play first.
  Future<void> addAllToQueue(List<Song> list) async {
    if (player.sequence.isEmpty) return playSongs(list);
    // Never ahead of the playing song (see [playSongs]).
    final at = max(autoplayStart, (player.currentIndex ?? -1) + 1);
    if (at >= player.sequence.length) return player.addAudioSources(list.map(_source).toList());
    // Shuffled, after the user's songs still to come, before autoplay's.
    final order = player.shuffleIndices;
    final sequence = player.sequence;
    var position = _playPosition(player.currentIndex ?? 0) + 1;
    while (position < order.length && !isAutoplay(sequence[order[position]])) {
      position++;
    }
    _placeInShuffle(at, position);
    await player.insertAudioSources(at, list.map(_source).toList());
  }

  /// Where the queue item at [index] plays, counting from the start of the
  /// shuffle order (or [index] itself unshuffled).
  int _playPosition(int index) => player.shuffleModeEnabled ? max(0, player.shuffleIndices.indexOf(index)) : index;

  /// Has the songs about to be inserted at queue [index] go at [position] in
  /// the shuffle order, in their own order; otherwise just_audio scatters
  /// them anywhere, even among songs already played.
  void _placeInShuffle(int index, int position) {
    if (player.shuffleModeEnabled) _shuffleOrder?.insertAt = (index: index, position: position);
  }

  /// The home screen widgets show the current song and whether it's playing.
  void _updateHomeWidgets() => HomeWidgets.update(currentSong, playing: player.playing);

  void _onSequenceState(SequenceState state) {
    _updateGain();
    _updateListening();
    _updateResume();
    _updateHomeWidgets();
    // While a new queue loads, the player's place in it is out of date (see
    // [_loadingSong]): saving it or counting a play would use the wrong song.
    if (_settingQueue) return _notify({MusicAspect.playback});
    _saveQueue();
    // Deferred: changing the queue while the player is still emitting this
    // event throws midway, leaving songs listed that the player never got.
    scheduleMicrotask(_topUpQueue);
    // Rebuild listeners on any queue change (current song, inserts, shuffle,
    // repeat) but only count a play when the song changes.
    final song = songOf(state.currentSource);
    if (song == null || song.id == _lastRecordedId) return _notify({MusicAspect.playback});
    _lastRecordedId = song.id;
    if (historyPaused) return _notify({MusicAspect.playback});

    _historyIds
      ..remove(song.id)
      ..insert(0, song.id);
    if (_historyIds.length > _historyLimit) _historyIds.removeLast();
    _playCounts[song.id] = (_playCounts[song.id] ?? 0) + 1;
    _invalidateHistory();

    _saveIds(_historyKey, _historyIds);
    _prefs?.setStringList(
      _playCountsKey,
      [for (final MapEntry(:key, :value) in _playCounts.entries) '$key:$value'],
    );
    _notify({MusicAspect.playback, MusicAspect.history});
  }
}

/// Provides the [MusicController] and rebuilds only the widgets that depend
/// on the aspects that changed.
class MusicScope extends StatefulWidget {
  const MusicScope({super.key, required this.controller, required this.child});

  final MusicController controller;
  final Widget child;

  /// Returns the controller and rebuilds [context] when any of [aspects] change.
  static MusicController of(BuildContext context, Set<MusicAspect> aspects) {
    for (final aspect in aspects) {
      InheritedModel.inheritFrom<_MusicModel>(context, aspect: aspect);
    }
    return read(context);
  }

  /// Returns the controller without subscribing to changes, for callbacks.
  static MusicController read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_MusicModel>()!.controller;

  @override
  State<MusicScope> createState() => _MusicScopeState();
}

class _MusicScopeState extends State<MusicScope> {
  /// Bumped for each aspect that changes.
  var _versions = {for (final a in MusicAspect.values) a: 0};

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    final changed = widget.controller.takeChanges();
    if (changed.isEmpty) return;
    setState(() {
      _versions = {for (final a in MusicAspect.values) a: _versions[a]! + (changed.contains(a) ? 1 : 0)};
    });
  }

  @override
  Widget build(BuildContext context) =>
      _MusicModel(controller: widget.controller, versions: _versions, child: widget.child);
}

class _MusicModel extends InheritedModel<MusicAspect> {
  const _MusicModel({required this.controller, required this.versions, required super.child});

  final MusicController controller;
  final Map<MusicAspect, int> versions;

  @override
  bool updateShouldNotify(_MusicModel old) => !identical(versions, old.versions);

  @override
  bool updateShouldNotifyDependent(_MusicModel old, Set<MusicAspect> dependencies) =>
      dependencies.any((a) => versions[a] != old.versions[a]);
}
