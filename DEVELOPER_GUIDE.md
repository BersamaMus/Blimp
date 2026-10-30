# Blimp developer guide

A map of the codebase: what each part does and which files to open for each
feature. For the build commands and the house rules (no network calls,
comment style, release steps), read [CLAUDE.md](CLAUDE.md) first.

Blimp (Better Localized Music Player) is an offline Flutter music player for
Android and Windows. Dart package: `blimp`. Android app ID: `com.blimp.app`.
The project folder is still called `better_music_player`, and the root widget
is still `BetterMusicPlayerApp`.

---

## 1. The big picture

```
lib/main.dart
  └─ MusicController  (lib/services/music_controller.dart)  ← all app state
       ├─ MediaLibrary  (Android: Kotlin over method channels)
       │    └─ DesktopLibrary  (Windows: scans a folder in Dart)
       ├─ just_audio AudioPlayer
       │    ├─ Android: just_audio_background → foreground service, notification, Android Auto
       │    └─ Windows: just_audio_media_kit → mpv
       └─ SharedPreferences + listening_log.csv
  └─ MusicScope (InheritedModel<MusicAspect>)  → every screen and widget
```

- **One controller holds everything.** `MusicController` owns the library,
  the queue and player, history, favourites, ratings, playlists, smart
  playlists, settings, stats, the sleep timer and backups. It's a
  `ChangeNotifier`, and it tells listeners which `MusicAspect` changed.
- **Widgets reach it through `MusicScope`**, defined at the bottom of
  `music_controller.dart`:
  - `MusicScope.of(context, {MusicAspect.playback})` in `build`. The widget
    rebuilds only when those aspects change.
  - `MusicScope.read(context)` in callbacks. It doesn't subscribe.
  - The aspects are `library, playback, history, favourites, playlists,
    searches, settings, stats`.
- **Platform split.** `isDesktop` (in `lib/services/desktop_library.dart`)
  decides between Android and Windows code paths. The static methods on
  `MediaLibrary` are the shared API. On desktop they hand off to
  `DesktopLibrary` or to a Windows channel.

### `music_controller.dart` sections

At about 2,100 lines, this is the biggest file. It's split by
`// ----` banners. Search for these headings:

| Section | Line (approx.) | What's there |
|---|---|---|
| (top) | 1–325 | `LibraryStatus`, `ScanResult`, `MusicAspect`, `Album`, `Artist`, the prefs keys, `init()`, `dispose()` |
| Library | 327 | Scanning, albums and artists, hidden folders, minimum song length, Quick picks |
| Settings | 575 | Every setting's field, how it loads, and its setter (speed, seek step, waveform seek bar, skip silence, autoplay, visualizer, equalizer, history pause) |
| Listening stats | 814 | Logging listens, play counts, resume points, backups (`_songKeys`), app lifecycle |
| Favourites and search history | 1056 | `toggleFavourite`, recent searches |
| Ratings | 1075 | `setRating`. A one-star rating keeps the song out of Quick picks and autoplay. `mergeSongInto` (used for duplicates) |
| Smart playlists | 1139 | Saving, deleting and restoring them |
| Lyrics search | 1319 | Reading every song's lyrics into the index, `searchLyricsFor` |
| Volume | 1188 | Volume, normalisation (ReplayGain), crossfade, the sleep timer's fade-out. They multiply together in one place |
| Sleep timer | 1320 | `setSleepTimer`, `setSleepAtEndOfSong` |
| Playlists | 1406 | Creating, renaming, reordering and deleting user playlists |
| Playback | 1520 | `playSongs`, `playOpened`, the queue, shuffle, `startRadio`, play next / add to queue, widget requests |
| `MusicScope` | 2046 | The InheritedModel wrapper |

---

## 2. Where each feature lives

### Library and scanning

| What | Files |
|---|---|
| `Song`, `AudioFormat`, artwork cache (LRU), the shared platform API | `lib/services/media_library.dart` |
| Android song list, artwork, lyrics, gain, hi-res, waveform, file info, share | `android/.../AppChannels.kt` (`blimp/media`) |
| Android cover art thumbnails | `android/.../Artwork.kt` |
| Hiding voice recordings and voice notes from the library | `android/.../VoiceRecordings.kt` (+ `VoiceRecordingsTest.kt`) |
| Windows folder scan (an isolate, `audio_metadata_reader`) and the music folder setting | `lib/services/desktop_library.dart` |
| Albums, and sorting them into Album / EP / Single / Compilation | `lib/services/catalog.dart`, `Album` in `music_controller.dart` |
| Splitting artist credits ("A feat. B", "A, B" only when both are known artists) | `ArtistCredits` in `lib/services/catalog.dart` |
| Broad genres from detailed genre tags | `lib/services/genres.dart` |
| The folder tree, and merging single-child folders | `lib/services/folders.dart`, `lib/screens/folder_screen.dart` |
| Hidden folders and the minimum song length | `music_controller.dart` (Library section), `HiddenFoldersScreen` in `settings_screen.dart` |
| Rescan | `lib/widgets/app_menu.dart` (⋮ menu) → `MusicController` |

### Playback

| What | Files |
|---|---|
| Player setup (background service on Android, mpv on Windows) | `lib/main.dart` |
| Queue, shuffle, play next, add to queue, radio, autoplay | `music_controller.dart` (Playback section) |
| Shuffle order that keeps autoplay songs last | `lib/services/queue_order.dart` |
| Picking up long tracks (podcasts, mixes) where they were left | `lib/services/resume_points.dart` |
| Gapless: `prefetchPlaylist` on Windows. Android is gapless already | `lib/main.dart` |
| Equalizer and loudness boost (Android only: `AndroidEqualizer`, `AndroidLoudnessEnhancer`) | `music_controller.dart`, `EqualizerScreen` in `settings_screen.dart` |
| Normalisation (ReplayGain) and crossfade | `music_controller.dart` (Volume section); Android reads the gain in `EmbeddedLyrics.kt`, Windows in `desktop_library.dart` |
| Sleep timer | `music_controller.dart` (Sleep timer section); its UI is `_SleepTimerButton`/`_SleepTimerSheet` in `now_playing_screen.dart` |
| Speed and skip silence | Settings section, `_SpeedButton` in `now_playing_screen.dart`, `PlaybackSettingsScreen` |
| Hi-res detection and badge | `android/.../HiRes.kt`, `desktop_library.dart`, `HiResBadge` in `lib/widgets/shelf.dart` |
| Format line (codec, bit depth, sample rate) | `AudioFormat` in `media_library.dart`, `_FormatLine` in `now_playing_screen.dart` |
| Waveform seek bar | Android `getWaveform` in `AppChannels.kt`; Windows `windows/runner/waveform.cpp` (`blimp/waveform`); drawn by `_SeekBar` in `now_playing_screen.dart` |

### Screens and UI

| What | Files |
|---|---|
| Tabs (Home, Library, Playlists, Stats, Settings), per-tab navigators, desktop side tabs, drag-and-drop zone | `lib/screens/app_shell.dart` (`AppShell`, `DesktopFrame`, `openPage`) |
| Home: Quick picks and history | `lib/screens/home_screen.dart`, `lib/widgets/song_pager.dart` |
| Library: songs, albums, artists, playlists, with filters and sorting | `lib/screens/library_screen.dart`. The Playlists tab is `LibraryScreen.playlists()` |
| Album page, playlist header | `lib/screens/collection_screen.dart` |
| Artist page | `lib/screens/artist_screen.dart` |
| User playlist (drag to reorder, swipe to remove) | `lib/screens/playlist_screen.dart` |
| Smart playlist page and rule editor | `lib/screens/smart_playlist_screen.dart` |
| Search (accent-insensitive; "acdc" finds "AC/DC") | `lib/screens/search_screen.dart`, `lib/services/search_text.dart` |
| Full player: artwork swipe, double-tap seek, controls, and the Up next / Visualizer / Lyrics sheet | `lib/screens/now_playing_screen.dart` (about 1,600 lines; see its `_` classes) |
| Mini player above the tabs | `lib/widgets/mini_player.dart` |
| Settings, with sub-pages for Playback, Equalizer, Privacy, Storage, Hidden folders, Backup and About | `lib/screens/settings_screen.dart` |
| Song ⋮ menu / long-press sheet | `lib/widgets/song_options.dart` |
| Song details sheet (path, size, tags) | `lib/widgets/song_details.dart` |
| Add to playlist, new-playlist dialog, playlist covers | `lib/widgets/add_to_playlist.dart` |
| Song rows, playing indicator, desktop table view | `lib/widgets/song_tile.dart`, `lib/widgets/song_table.dart` |
| Shared bits: headers, pills, chips, cards, empty-state messages | `lib/widgets/shelf.dart`, `lib/widgets/cards.dart` |
| Artwork widget (decoded at display size) | `lib/widgets/song_artwork.dart` |
| Star ratings | `lib/widgets/star_rating.dart` |
| Scrolling title text | `lib/widgets/marquee_text.dart` |
| Theme: black and yellow, `AppColors`, corner radii | `lib/theme.dart` |

### Lyrics

| What | Files |
|---|---|
| Parsing LRC and plain lyrics, finding the current line | `lib/services/lyrics.dart` |
| Embedded lyrics on Android (ID3v2, FLAC, MP4 tags) | `android/.../EmbeddedLyrics.kt` (+ `EmbeddedLyricsTest.kt`) |
| Embedded and `.lrc` lyrics on Windows | `desktop_library.dart` (mpv's `sub-auto=no` is set in `packages/just_audio_media_kit`) |
| Display: synced and tappable, or plain | `lib/widgets/lyrics_view.dart` |
| Karaoke mode: full screen, fills each line as it's sung (word by word with enhanced-LRC `<mm:ss.xx>` word times, otherwise at a steady pace) | `lib/screens/karaoke_screen.dart`; word times parsed into `LyricLine.words` in `lyrics.dart` |
| Searching lyrics: every song's lyrics read once and kept, matched like other search, played from the line | `lib/services/lyrics_index.dart`, Lyrics search section of `music_controller.dart`, `MediaLibrary.readLyrics` and `lyricsStamps` (`getLyricsBatch` / `getLyricsStamps` in `AppChannels.kt`, `DesktopLibrary.lyricsOf` / `lyricsStamps` on Windows), `_LyricResult` in `search_screen.dart` |

### Visualizer

| What | Files |
|---|---|
| Styles, genre colours, artwork colours (`artworkColors`, loaded by `MediaLibrary.getArtworkColors`), `AudioFrame`, the event stream | `lib/services/visualizer.dart` (`blimp/visualizer`) |
| Drawing all five styles, permission and "whole PC" notes | `lib/widgets/visualizer_view.dart` |
| Android capture (`android.media.audiofx.Visualizer`; needs RECORD_AUDIO) | `AppChannels.kt` |
| Windows capture (process loopback on Windows 10 build 20348+, otherwise the whole PC) | `windows/runner/visualizer.cpp` |

### Playlists, M3U, smart playlists

| What | Files |
|---|---|
| `Playlist` model and encoding | `lib/services/playlists.dart` |
| M3U import and export (matched by path, then path ending, then "Artist - Title") | `lib/services/m3u.dart` |
| Smart playlist rules, fields, sorting | `lib/services/smart_playlists.dart` |
| Save and Open file pickers | `lib/services/device_files.dart` → `blimp/files` in `MainActivity.kt` / `file_selector` on Windows |

### Tidying up

| What | Files |
|---|---|
| Tag editor. Pure Dart MP3 (ID3v2.3/2.4) and FLAC writer; every other field in the file is copied across. Lyrics go in a USLT frame or LYRICS comment (with several languages, only the first with words is shown and replaced; emptying the field removes them all), and the field shows only the file's own lyrics (`MediaLibrary.embeddedLyrics`: `getEmbeddedLyrics` in `AppChannels.kt`, `DesktopLibrary.embeddedLyrics` on Windows), never a .lrc file | `lib/services/tag_editor.dart`, `lib/screens/tag_editor_screen.dart` |
| On Android, the file is copied out with `copySong`, edited, then written back with `writeSong` after the user agrees | `MainActivity.kt` (`blimp/files`), `MediaLibrary.writeWithAccess` |
| Finding duplicates | `lib/services/duplicates.dart`, `lib/screens/duplicates_screen.dart` |
| Throwing files away | Android: `trashSongs` in `MainActivity.kt`. Windows: `windows/runner/recycle_bin.cpp` (`blimp/recycle_bin`) |
| Ratings | `music_controller.dart` (Ratings), `star_rating.dart` |

### Stats, history, backups

| What | Files |
|---|---|
| The listening log (`listening_log.csv` in the app support folder, saved in pieces every 30 s; a listen counts as a play at 30 s) | `lib/services/listening_log.dart` |
| Day, week, month and all-time totals, and the top songs, artists and genres | `lib/services/listening_stats.dart` |
| Stats screen, chart, share bar | `lib/screens/stats_screen.dart`, `lib/widgets/listening_chart.dart` |
| Streaks and badges | `lib/services/milestones.dart`, `lib/screens/badges_screen.dart` (tiles on the Stats screen) |
| Top songs of each year (auto playlists on the Playlists tab) | `playedYears` / `topSongsOfYear` in `listening_stats.dart`, `CollectionScreen.yearChart`, `_playlists` in `library_screen.dart` |
| Time machine (Home shelf: the same week in past years, then 6, 3 and 1 months ago) | `lib/services/time_machine.dart`, `_TimeMachine` in `home_screen.dart` |
| Song DNA sheet (song ⋮ menu) | `lib/services/song_dna.dart`, `lib/widgets/song_dna_sheet.dart` |

All of these are worked out from the listening log. The controller caches
them (`streak`, `badges`, `timeTrips`, `chartYears`, `topSongsOf`) and clears them in
`_forgetListenFacts`, which runs whenever a listen is saved or history is
cleared.

### Discovery

| What | Files |
|---|---|
| Decade radio (Home shelf; songs grouped by year tag) | `lib/services/decades.dart`, `MusicController.decades` / `playDecade`, `_DecadeRow` in `home_screen.dart` |
| Six degrees (artists linked by shared songs, then compilations) and the artist page's "Worked with" shelf | `lib/services/artist_links.dart` (`ArtistGraph`), `lib/screens/six_degrees_screen.dart`, `artist_screen.dart` |
| Backup and restore (one JSON file, `format: blimp-backup`, `version: 1`; songs are matched again on the new device) | `lib/services/backup.dart`, `_songKeys` in `music_controller.dart`, `BackupSettingsScreen` |

### Android-only features

| What | Files |
|---|---|
| Activity: file pickers, open-with intents, the `blimp/files` channel | `android/.../MainActivity.kt` (extends `AudioServiceActivity`) |
| Setting up channels on every engine, including headless Android Auto | `BlimpApplication.kt`, `packages/engine_hooks/` |
| Android Auto browsing (Recent, Favourites, Playlists, Albums, Artists) | `lib/services/car_browser.dart`, `packages/just_audio_background` (`MediaBrowserDelegate`), `res/xml/automotive_app_desc.xml`, test in `android/app/src/androidTest/.../CarBrowsingTest.kt` |
| Home screen widgets (small 4x1, square 2x2, wide) | `android/.../NowPlayingWidgets.kt`, `res/layout/widget_now_playing_*.xml`, `res/xml/widget_info_*.xml`, Dart side `lib/services/home_widgets.dart` (`blimp/widgets`) |
| Launcher shortcuts (Resume, Shuffle all, Favourites) | `res/xml/shortcuts.xml`, `WidgetRequest` in `home_widgets.dart`, `handleWidgetRequest` in the controller |
| Playback notification and lock screen | `just_audio_background`, set up in `lib/main.dart`; icon `res/drawable/ic_stat_music.xml` |
| Permissions, the service, receivers, intent filters | `android/app/src/main/AndroidManifest.xml` |
| Signing | `android/key.properties` (not committed), `android/app/build.gradle.kts` |

### Windows-only features

Each feature is a pair: a C++ file in `windows/runner/` and a Dart file in
`lib/`, joined by a `blimp/<name>` channel. They're wired up in
`flutter_window.cpp`.

| What | C++ | Dart |
|---|---|---|
| Media keys and the Windows media flyout (SMTC) | `media_controls.cpp` | `lib/services/media_controls.dart` |
| Pausing when headphones are unplugged | `output_watch.cpp` (goes through the media controls channel) | `media_controls.dart` |
| System tray and close-to-tray; asks what closing does | `background.cpp` (`blimp/window`) | `lib/services/desktop_window.dart`, `lib/widgets/close_choice.dart` |
| Open with Blimp, drag and drop, one instance at a time | `open_files.cpp`, `main.cpp` | `lib/services/open_files.dart`, `_DropZone` in `app_shell.dart` |
| Share panel | `share.cpp` | `MediaLibrary.shareSong` |
| Recycle Bin | `recycle_bin.cpp` | `MediaLibrary.trashSongs` |
| Waveform levels (Media Foundation) | `waveform.cpp` | `desktop_library.dart` |
| Visualizer capture | `visualizer.cpp` | `visualizer.dart` |
| Remembering window size and position (registry `HKCU\Software\Blimp\Blimp`) | `window_placement.cpp` | — |
| Compact player that stays on top | (`setCompact` on `blimp/window`) | `lib/widgets/compact_player.dart` |
| Window title shows the song playing | (`setTitle` on `blimp/window`) | `lib/services/desktop_window.dart` |
| Keyboard shortcuts | — | `lib/widgets/desktop_shortcuts.dart` |
| Zooming the UI with the window height | — | `lib/widgets/window_scale.dart` |
| Volume slider | — | `lib/widgets/volume_control.dart` |
| Installer | `windows/installer/blimp.iss`, `build_installer.ps1` | — |
| Store package | `msix_config` in `pubspec.yaml` | — |

---

## 3. Platform channels

| Channel | Dart | Android | Windows |
|---|---|---|---|
| `blimp/media` | `media_library.dart` | `AppChannels.kt`: getSongs, getArtwork, getAudioFormat, getFileInfo, getWaveform, openFolder, getLyrics, getEmbeddedLyrics, getGain, getReleaseTypes, getHiRes, shareSong | — (handled in `DesktopLibrary`) |
| `blimp/files` | `device_files.dart`, `media_library.dart`, `tag_editor.dart` | `MainActivity.kt`: save, open, restart, copySong, writeSong, trashSongs | — (`file_selector`) |
| `blimp/widgets` | `home_widgets.dart` | `AppChannels.kt`: update, clear, setColors, takeRequest; calls `request` | — |
| `blimp/open` | `open_files.dart` | `AppChannels.kt`: takeOpened; calls `opened` | `open_files.cpp` |
| `blimp/visualizer` (event) | `visualizer.dart` | `AppChannels.kt` | `visualizer.cpp` |
| `blimp/share` | `media_library.dart` | — | `share.cpp` |
| `blimp/recycle_bin` | `media_library.dart` | — | `recycle_bin.cpp` |
| `blimp/waveform` | `desktop_library.dart` | — | `waveform.cpp` |
| `blimp/media_controls` | `media_controls.dart` | — | `media_controls.cpp`, `output_watch.cpp` |
| `blimp/window` | `desktop_window.dart` | — | `background.cpp` |

**Adding a platform feature:** add a static method on `MediaLibrary` (or a
small service in `lib/services/`), a Kotlin handler in `AppChannels.kt`
(`MainActivity.kt` if it needs a screen), and a C++ handler in a new
`windows/runner/<name>.cpp` registered in `flutter_window.cpp` and
`windows/runner/CMakeLists.txt`. Use the same channel name in all three.
Catch `MissingPluginException` on the platform that doesn't have it.

---

## 4. Saved data

**SharedPreferences.** Most keys are `static const _...Key` at the top of
`MusicController`:

- Library and history: `liked_song_ids` (favourites; the key is still
  called "liked"), `history_song_ids`, `play_counts`, `song_ratings`,
  `resume_points`, `recent_searches`, `hidden_folders`, `min_song_seconds`
- Queue: `queue_song_ids`, `queue_index`, `queue_unshuffled_ids`, `queue_position` (the song playing and how far into it)
- Playlists: `playlists`, `smart_playlists`
- Settings: `seek_seconds`, `skip_silence`, `waveform_seek_bar`,
  `library_browse_folders`, `equalizer_enabled`, `equalizer_gains`,
  `history_paused`, `search_history_paused`, `visualizer_style`, `visualizer_artwork_colors`,
  `visualizer_enabled`, `autoplay`, `playback_speed`, `normalize_volume`,
  `fade_seconds`, `volume`
- Elsewhere: `desktopMusicFolder` (`desktop_library.dart`), `close_action`
  (`desktop_window.dart`)

**Files** in the app support folder: `listening_log.csv`, and
`lyrics_index.json` (see `LyricsIndex`), which can be read again from the
songs so isn't backed up. It keeps a stamp of each song's file and `.lrc` file
(size and when they last changed), so a changed one is read again.
**Windows registry:** window placement.
**Android widgets:** keep their own copy of the last song, so they can redraw
without the app.

**When you add saved state:** if it should survive a backup, add the key to
`_songKeys` in `music_controller.dart` (with its `SongIds` kind if it holds
song ids) and check `lib/services/backup.dart`.

**Song ids:** on Android they're MediaStore ids, which are different on each
device. Backups match songs again by their tags. On Windows, ids are made up
by `DesktopLibrary`.

---

## 5. Vendored packages (`packages/`)

| Package | Why it's here |
|---|---|
| `engine_hooks` | Our own small plugin. It runs a callback on every Flutter engine, so `AppChannels` is set up even when Android Auto starts the app without a screen. |
| `just_audio_background` | Adds `MediaBrowserDelegate` / `JustAudioBackground.browser` for Android Auto. |
| `just_audio_media_kit` | The Windows player (mpv). Sets `sub-auto=no` so mpv doesn't load `.lrc` files, and fixes inserting songs partway through the queue. |

Mark changed lines with "Blimp" comments and record them in each package's
`BLIMP_CHANGES.md`.

---

## 6. Tests

`flutter test` runs pure Dart tests on `Song` objects built by hand. No
device is needed.

| Test | Covers |
|---|---|
| `catalog_test`, `album_kind_test` | Album grouping, artist splitting, release types |
| `genres_test`, `search_text_test`, `folders_test` | Genre mapping, search normalisation, the folder tree |
| `playlists_test`, `smart_playlists_test`, `m3u_test` | Playlists |
| `queue_order_test`, `resume_points_test` | Queue and resume |
| `listening_stats_test`, `backup_test` | Stats and backups |
| `milestones_test`, `year_charts_test` | Streaks, badges, Top songs of the year, Time machine |
| `discovery_test` | Decades, Six degrees, Song DNA, artwork colours |
| `lyrics_test`, `tag_editor_test`, `audio_format_test`, `desktop_library_test` | File parsing and writing |
| `lyrics_search_test` | Searching lyrics, the lyrics index |
| `marquee_text_test`, `desktop_shortcuts_test`, `accessibility_test`, `chart_colors_test` | Widgets and contrast |

Kotlin unit tests are in `android/app/src/test/` (EmbeddedLyrics, HiRes,
VoiceRecordings). The Android Auto instrumented test is in
`android/app/src/androidTest/`. Platform channels have no automated tests, so
check those on a device or emulator (`emulator-5554`).

---

## 7. Other folders

- `docs/`: the GitHub Pages site (download page `index.html`,
  `privacy.html`, screenshots in `docs/img/`).
- `store_listing/`: Play Store and Microsoft Store text (`listing.md`,
  `microsoft_store.md`), screenshots, feature graphic, icon and privacy
  policy.
- `windows/installer/`: the Inno Setup script and its build script.
- `README.md`: the user-facing feature list. Update it when features change.

---

## 8. Things that catch people out

- `MusicController` notifies by aspect. If a new piece of state doesn't show
  up in the UI, check that its setter notifies the right `MusicAspect`, and
  that the widget asks for that aspect in `MusicScope.of`.
- To play something and show the player, use `playAndOpen` in
  `now_playing_screen.dart`. It waits until the song is queued. Opened before
  anything is playing, the player closes itself.
- Use `openPage` from `app_shell.dart` to push album and artist pages, so the
  tab bar and mini player stay.
- Android channels are set up per engine in `AppChannels`. Don't move
  channels there that need an Activity; those go in `MainActivity`.
- Don't test on Windows with your own data. A debug
  `build/windows/x64/runner/Debug/blimp.exe` uses the real Blimp settings and
  Music folder.
- Before running `dart run msix:create`, close any Blimp running from
  `build/`.
- Raise the `+build` number in `pubspec.yaml` for every Play upload, and keep
  `msix_version` in step.
