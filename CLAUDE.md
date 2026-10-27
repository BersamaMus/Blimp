# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Blimp (Better Localized Music Player) is an offline Flutter music player for Android and Windows. The Dart package is `blimp` and the Android app ID is `com.blimp.app`; the folder is still named `better_music_player`. It never goes online, so don't add network calls or analytics.

## Commands

```sh
flutter analyze                          # run after every change; android/, ios/, windows/ are excluded
flutter test                             # all tests (pure Dart logic, no device needed)
flutter test test/catalog_test.dart      # one file
flutter test --plain-name "some name"    # one test by name
flutter run -d emulator-5554             # Android emulator
flutter run -d windows
```

Release builds:

- Windows installer: `powershell -File windows\installer\build_installer.ps1` (needs Inno Setup) → `build\installer\Blimp-Setup-<version>.exe`.
- Microsoft Store package: `dart run msix:create` → `build/msix/Blimp.msix`. Close any Blimp running from `build/` first. The identity values in `msix_config` must match Partner Center exactly.
- Google Play: `flutter build appbundle`, signed through `android/key.properties`.
- Version bumps: `version` in `pubspec.yaml` (raise the `+build` number for every Play upload) and `msix_version`.

## Architecture

For a feature-by-feature map of which files do what (channels, saved keys, tests), see [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md).

**One controller, platform-split services.** `lib/main.dart` creates a single `MusicController` (`lib/services/music_controller.dart`, by far the biggest file). It owns the library, the queue and the `just_audio` player, plus history, favourites, playlists, settings and stats. Widgets reach it through `MusicScope`, an `InheritedModel` keyed by `MusicAspect`. Use `MusicScope.of(context, {MusicAspect.playback, ...})` to rebuild only on the aspects a widget shows, and `MusicScope.read(context)` inside callbacks.

**Android and Windows get songs in different ways.** `isDesktop` (in `desktop_library.dart`) picks the path:
- Android: `MediaLibrary` (`media_library.dart`) asks Kotlin over method channels (`blimp/media`, `blimp/files`, `blimp/share`, ...). Kotlin reads MediaStore and handles artwork, embedded lyrics, hi-res detection, tag writing and trashing (`android/app/src/main/kotlin/com/blimp/app/`).
- Windows: `DesktopLibrary` scans a music folder itself with `audio_metadata_reader` in an isolate, and works out from the files what Kotlin would report on Android. Native features live in `windows/runner/*.cpp` (SMTC media controls, tray/background, open-with, visualizer capture, waveform, recycle bin, window placement), each on its own `blimp/<name>` channel.
- `MediaLibrary`'s static methods are the shared API and pass to `DesktopLibrary` on desktop. A new platform feature usually needs a Dart method in `MediaLibrary`, a Kotlin handler and a C++ handler, all on the same channel name.

**Android channels are set up on every engine.** `BlimpApplication` uses the local `packages/engine_hooks` plugin to register `AppChannels` on each Flutter engine that starts, including the one the playback service starts with no activity (Android Auto). Channels that only make sense with a screen (file pickers, permission prompts) are in `MainActivity`.

**Vendored packages in `packages/`.** Each has a `BLIMP_CHANGES.md`, and changed lines are marked "Blimp":
- `just_audio_background`: adds `MediaBrowserDelegate` / `JustAudioBackground.browser`, which `CarBrowser` implements for Android Auto.
- `just_audio_media_kit`: the Windows player (mpv). Sets `sub-auto=no` so mpv doesn't load `.lrc` files, and fixes inserting songs partway through the queue.

When changing these, keep the "Blimp" markers and update `BLIMP_CHANGES.md`.

**Storage.** Settings and small lists (favourites, playlists, history ids) are in `SharedPreferences`. The listening log is a file in the app support directory. `backup.dart` exports and restores all of it as one file, so new persisted state usually needs adding there too.

**Tests** cover the pure logic in `lib/services/` (catalog/album grouping, artist splitting, smart playlists, M3U, lyrics parsing, backup, queue order, and so on) by building `Song` objects directly. Nothing tests platform channels; check those on a device.

## Conventions

- Comments and UI text are plain, non-technical English that explains why, in the style already in the code. Match it.
- Windows testing: `build/windows/x64/runner/Debug/blimp.exe` uses the user's real Blimp data and Music folder, so don't save test playlists or tag edits there.
- `docs/` is the GitHub Pages site (download page, privacy policy). `store_listing/` holds the Play and Microsoft Store text, screenshots and graphics. Update the README's feature list when user-facing features change.
- The README says "All rights reserved", so don't add an open-source license.
