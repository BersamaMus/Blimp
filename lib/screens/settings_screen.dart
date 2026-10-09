import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/backup.dart';
import '../services/desktop_library.dart';
import '../services/device_files.dart';
import '../services/music_controller.dart';
import '../theme.dart';
import '../widgets/app_menu.dart';
import '../widgets/shelf.dart';
import '../widgets/song_options.dart';

/// The top-level settings list.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    void open(Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _SettingsTile(
            icon: Icons.play_circle_outline,
            title: 'Playback',
            subtitle: 'Speed, fades, normalisation, equalizer and more',
            onTap: () => open(const PlaybackSettingsScreen()),
          ),
          _SettingsTile(
            icon: Icons.shield_outlined,
            title: 'Privacy & data',
            subtitle: 'Listening and search history',
            onTap: () => open(const PrivacySettingsScreen()),
          ),
          _SettingsTile(
            icon: Icons.sd_storage_outlined,
            title: 'Library & storage',
            subtitle: 'Songs on this device, hidden folders, short files, rescan',
            onTap: () => open(const StorageSettingsScreen()),
          ),
          _SettingsTile(
            icon: Icons.settings_backup_restore_rounded,
            title: 'Backup & restore',
            subtitle: 'Keep your playlists, favourites and stats when you change phones',
            onTap: () => open(const BackupSettingsScreen()),
          ),
          _SettingsTile(icon: Icons.info_outline, title: 'About', onTap: () => open(const AboutSettingsScreen())),
        ],
      ),
    );
  }
}

class PlaybackSettingsScreen extends StatelessWidget {
  const PlaybackSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.settings});
    return Scaffold(
      appBar: AppBar(title: const Text('Playback')),
      body: ListView(
        children: [
          _SettingsTile(
            title: 'Double-tap to seek',
            subtitle: '${music.seekSeconds} seconds',
            onTap: () => _pickSeekSeconds(context, music),
          ),
          _SwitchTile(
            title: 'Autoplay',
            subtitle: 'Keep playing similar songs when your queue ends',
            value: music.autoplay,
            onChanged: music.setAutoplay,
          ),
          _SwitchTile(
            title: 'Waveform seek bar',
            subtitle: "Show the song's waveform in the player instead of a plain slider",
            value: music.waveformSeekBar,
            onChanged: music.setWaveformSeekBar,
          ),
          _SwitchTile(
            title: 'Skip silence',
            subtitle: 'Automatically skip silent parts of songs',
            value: music.skipSilence,
            onChanged: music.setSkipSilence,
          ),
          _SwitchTile(
            title: 'Volume normalisation',
            subtitle: 'Play every song at about the same loudness',
            value: music.normalizeVolume,
            onChanged: music.setNormalizeVolume,
          ),
          _SettingsTile(
            title: 'Fade between songs',
            subtitle: music.fadeSeconds == 0 ? 'Off' : 'Fade out and in over ${music.fadeSeconds} seconds',
            onTap: () => _pickOption(
              context,
              title: 'Fade between songs',
              options: MusicController.fadeSecondsOptions,
              selected: music.fadeSeconds,
              label: (s) => s == 0 ? 'Off' : '$s seconds',
              onPicked: music.setFadeSeconds,
            ),
          ),
          _SettingsTile(
            title: 'Playback speed',
            subtitle: music.speed == 1 ? 'Normal' : formatSpeed(music.speed),
            onTap: () => showSpeedPicker(context),
          ),
          if (music.equalizer != null)
            _SettingsTile(
              title: 'Equalizer',
              subtitle: music.equalizerEnabled ? 'On' : 'Off',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const EqualizerScreen())),
            ),
        ],
      ),
    );
  }

  Future<void> _pickSeekSeconds(BuildContext context, MusicController music) => _pickOption(
    context,
    title: 'Double-tap to seek',
    options: MusicController.seekSecondsOptions,
    selected: music.seekSeconds,
    label: (s) => '$s seconds',
    onPicked: music.setSeekSeconds,
  );
}

/// A dialog to pick one of [options], each shown by [label].
Future<void> _pickOption<T>(
  BuildContext context, {
  required String title,
  required List<T> options,
  required T selected,
  required String Function(T) label,
  required ValueChanged<T> onPicked,
}) {
  return showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.sheet,
      title: Text(title),
      contentPadding: const EdgeInsets.only(top: 12, bottom: 8),
      content: SingleChildScrollView(
        child: RadioGroup<T>(
          groupValue: selected,
          onChanged: (value) {
            if (value != null) onPicked(value);
            Navigator.pop(dialogContext);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [for (final option in options) RadioListTile<T>(value: option, title: Text(label(option)))],
          ),
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}

/// Gains for a preset at a band's center frequency in hertz.
typedef _Preset = ({String name, double Function(double hz) gain});

class EqualizerScreen extends StatelessWidget {
  const EqualizerScreen({super.key});

  static final List<_Preset> _presets = [
    (name: 'Flat', gain: (_) => 0),
    (name: 'Bass boost', gain: (hz) => hz <= 250 ? 6 : (hz <= 1000 ? 2 : 0)),
    (name: 'Treble boost', gain: (hz) => hz >= 4000 ? 6 : (hz >= 2000 ? 3 : 0)),
    (name: 'Vocal', gain: (hz) => hz >= 1000 && hz <= 4000 ? 4 : (hz <= 250 ? -2 : 0)),
    (name: 'Loudness', gain: (hz) => hz <= 250 ? 5 : (hz >= 4000 ? 4 : 0)),
  ];

  static String _formatHz(double hz) =>
      hz >= 1000 ? '${(hz / 1000).toStringAsFixed(hz >= 10000 ? 0 : 1)} kHz' : '${hz.round()} Hz';

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.settings});
    return Scaffold(
      appBar: AppBar(title: const Text('Equalizer')),
      body: FutureBuilder<AndroidEqualizerParameters>(
        future: music.equalizer!.parameters,
        builder: (context, snapshot) {
          final params = snapshot.data;
          return ListView(
            children: [
              _SwitchTile(title: 'Use equalizer', value: music.equalizerEnabled, onChanged: music.setEqualizerEnabled),
              const Divider(),
              if (params == null)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: MessageView(icon: Icons.equalizer, text: 'Play a song to adjust the equalizer.'),
                )
              else
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: music.equalizerEnabled ? 1 : 0.4,
                  child: IgnorePointer(
                    ignoring: !music.equalizerEnabled,
                    child: _Bands(params: params, presets: _presets, formatHz: _formatHz),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Bands extends StatelessWidget {
  const _Bands({required this.params, required this.presets, required this.formatHz});

  final AndroidEqualizerParameters params;
  final List<_Preset> presets;
  final String Function(double) formatHz;

  List<double> _presetGains(_Preset preset) => [
    for (final band in params.bands)
      preset.gain(band.centerFrequency).clamp(params.minDecibels, params.maxDecibels).toDouble(),
  ];

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.read(context);
    final textTheme = Theme.of(context).textTheme;

    // Highlight the preset the current gains match, if any.
    final current = [for (final band in params.bands) band.gain];
    final selected = presets.indexWhere((p) {
      final gains = _presetGains(p);
      return [for (var i = 0; i < gains.length; i++) (gains[i] - current[i]).abs() < 0.05].every((ok) => ok);
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        ChipBar(
          labels: [for (final p in presets) p.name],
          selected: selected < 0 ? null : selected,
          onSelected: (i) => music.setEqualizerGains(_presetGains(presets[i])),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 300,
          child: Row(
            children: [
              for (final band in params.bands)
                Expanded(
                  child: StreamBuilder<double>(
                    stream: band.gainStream,
                    initialData: band.gain,
                    builder: (context, snapshot) {
                      final gain = snapshot.data ?? 0;
                      return Column(
                        children: [
                          Text('${gain > 0 ? '+' : ''}${gain.toStringAsFixed(1)} dB', style: textTheme.labelSmall),
                          Expanded(
                            child: RotatedBox(
                              quarterTurns: 3,
                              child: Slider(
                                value: gain.clamp(params.minDecibels, params.maxDecibels),
                                min: params.minDecibels,
                                max: params.maxDecibels,
                                onChanged: band.setGain,
                                onChangeEnd: (_) => music.saveEqualizerGains(params),
                              ),
                            ),
                          ),
                          Text(formatHz(band.centerFrequency), style: textTheme.labelSmall),
                        ],
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class PrivacySettingsScreen extends StatelessWidget {
  const PrivacySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.settings});
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy & data')),
      body: ListView(
        children: [
          _SwitchTile(
            title: 'Pause listening history',
            subtitle: "Songs you play won't appear in History, your charts or listening stats",
            value: music.historyPaused,
            onChanged: music.setHistoryPaused,
          ),
          _SettingsTile(
            title: 'Clear listening history',
            subtitle: 'Also resets your top songs chart and listening stats',
            onTap: () => _confirm(
              context,
              title: 'Clear listening history?',
              action: 'Clear',
              onConfirm: music.clearHistory,
              done: 'Listening history cleared',
            ),
          ),
          const Divider(),
          _SwitchTile(
            title: 'Pause search history',
            subtitle: "Searches won't be saved",
            value: music.searchHistoryPaused,
            onChanged: music.setSearchHistoryPaused,
          ),
          _SettingsTile(
            title: 'Clear search history',
            onTap: () => _confirm(
              context,
              title: 'Clear search history?',
              action: 'Clear',
              onConfirm: music.clearSearchHistory,
              done: 'Search history cleared',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirm(
    BuildContext context, {
    required String title,
    required String action,
    required VoidCallback onConfirm,
    required String done,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.sheet,
        title: Text(title),
        content: const Text("This can't be undone."),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(action),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      onConfirm();
      messenger.showSnackBar(SnackBar(content: Text(done)));
    }
  }
}

class StorageSettingsScreen extends StatelessWidget {
  const StorageSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.library, MusicAspect.settings});
    final textTheme = Theme.of(context).textTheme;
    final loading = music.status == LibraryStatus.loading;
    final hidden = music.hiddenFolders.length;

    Widget stat(String label, String value) => Expanded(
      child: Column(
        children: [
          Text(value, style: textTheme.headlineSmall),
          Text(label, style: textTheme.bodyMedium),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Library & storage')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Music on this device', style: textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(formatBytes(music.librarySizeBytes), style: textTheme.displaySmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Row(
              children: [
                stat('Songs', '${music.songs.length}'),
                stat('Albums', '${music.albums.length}'),
                stat('Artists', '${music.artists.length}'),
                stat('Genres', '${music.genres.length}'),
              ],
            ),
          ),
          const Divider(),
          if (isDesktop) const _MusicFolderTile(),
          _SettingsTile(
            title: 'Rescan device for music',
            subtitle: loading ? 'Scanning…' : 'Find songs added or removed since the last scan',
            trailing: loading
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            onTap: loading ? null : () => rescanLibrary(context),
          ),
          _SettingsTile(
            title: 'Hidden folders',
            subtitle: switch (hidden) {
              0 => "None. Hide a folder from its ⋮ menu in Library's Folders.",
              1 => '1 folder',
              _ => '$hidden folders',
            },
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HiddenFoldersScreen())),
          ),
          _SettingsTile(
            title: 'Ignore short files',
            subtitle: music.minSongSeconds == 0
                ? 'Off. Voice notes and ringtones may show up as songs'
                : 'Shorter than ${music.minSongSeconds} seconds',
            onTap: () => _pickMinSeconds(context, music),
          ),
        ],
      ),
    );
  }

  Future<void> _pickMinSeconds(BuildContext context, MusicController music) => _pickOption(
    context,
    title: 'Ignore short files',
    options: MusicController.minSongSecondsOptions,
    selected: music.minSongSeconds,
    label: (s) => s == 0 ? 'Off' : 'Shorter than $s seconds',
    onPicked: music.setMinSongSeconds,
  );
}

/// The folders left out of the library, each with a button to bring it back.
class HiddenFoldersScreen extends StatelessWidget {
  const HiddenFoldersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.settings});
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Hidden folders')),
      body: music.hiddenFolders.isEmpty
          ? const MessageView(
              icon: Icons.folder_outlined,
              text: "No hidden folders.\nOpen a folder in Library's Folders and pick Hide folder from its ⋮ menu.",
            )
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Text(
                    'Songs in these folders, and in folders inside them, are left out of your library.',
                    style: textTheme.bodyMedium,
                  ),
                ),
                for (final path in music.hiddenFolders)
                  ListTile(
                    leading: const Icon(Icons.folder_off_outlined, color: AppColors.textSecondary),
                    title: Text(path.substring(path.lastIndexOf('/') + 1), style: textTheme.bodyLarge),
                    subtitle: Text(path),
                    trailing: TextButton(onPressed: () => music.unhideFolder(path), child: const Text('Unhide')),
                  ),
              ],
            ),
    );
  }
}

class AboutSettingsScreen extends StatelessWidget {
  const AboutSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: FutureBuilder<PackageInfo>(
        future: PackageInfo.fromPlatform(),
        builder: (context, snapshot) {
          final info = snapshot.data;
          return ListView(
            children: [
              _SettingsTile(
                title: 'App version',
                subtitle: info == null ? '…' : '${info.version} (${info.buildNumber})',
              ),
              _SettingsTile(
                title: 'Open source licenses',
                onTap: () =>
                    showLicensePage(context: context, applicationName: 'Blimp', applicationVersion: info?.version),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Saving everything the user has made to a file, and bringing it back.
class BackupSettingsScreen extends StatelessWidget {
  const BackupSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & restore')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'A backup holds your playlists, favourites, listening history and stats, where you were in '
              'podcasts and audiobooks, and your settings. Your music files aren\x27t included.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          _SettingsTile(
            icon: Icons.save_alt_rounded,
            title: 'Back up to a file',
            subtitle: 'Save it anywhere, such as Downloads or Google Drive',
            onTap: () => _backUp(context),
          ),
          _SettingsTile(
            icon: Icons.restore_rounded,
            title: 'Restore from a file',
            subtitle: 'Replaces what\x27s here now',
            onTap: () => _restore(context),
          ),
        ],
      ),
    );
  }

  Future<void> _backUp(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final music = MusicScope.read(context);
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final name = 'Blimp backup ${now.year}-${two(now.month)}-${two(now.day)}.json';
    try {
      final saved = await DeviceFiles.save(name, 'application/json', utf8.encode(music.createBackup()));
      if (saved) messenger.showSnackBar(const SnackBar(content: Text('Backup saved')));
    } on PlatformException {
      messenger.showSnackBar(const SnackBar(content: Text("Couldn't save the backup there. Try another folder.")));
    }
  }

  Future<void> _restore(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final music = MusicScope.read(context);
    final navigator = Navigator.of(context);
    final ({String? name, Uint8List bytes})? file;
    try {
      file = await DeviceFiles.open(const ['application/json', 'application/octet-stream', 'text/plain']);
    } on PlatformException {
      messenger.showSnackBar(const SnackBar(content: Text("Couldn't open that file.")));
      return;
    }
    if (file == null || !navigator.mounted) return;

    final confirmed = await showDialog<bool>(
      context: navigator.context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.sheet,
        title: const Text('Restore this backup?'),
        content: Text(
          'Your playlists, favourites, history, stats and settings here will be replaced by those in '
          '${file?.name ?? 'the backup'}. Blimp will then restart.',
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Restore')),
        ],
      ),
    );
    if (confirmed != true) return;

    final RestoredBackup restored;
    try {
      restored = await music.restoreBackup(utf8.decode(file.bytes, allowMalformed: true));
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (!navigator.mounted) return;
    await showDialog<void>(
      context: navigator.context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.sheet,
        title: const Text('Backup restored'),
        content: Text(
          restored.songsMissing == 0
              ? 'Everything was found on this phone. Blimp will now restart.'
              : '${restored.songsMissing} ${restored.songsMissing == 1 ? 'song isn\x27t' : 'songs aren\x27t'} on this phone, '
                    'so they\x27re left out. Blimp will now restart.',
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Restart'))],
      ),
    );
    await DeviceFiles.restartApp();
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({required this.title, this.subtitle, this.icon, this.trailing, this.onTap});

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minVerticalPadding: 14,
      leading: icon == null ? null : Icon(icon),
      title: Text(title, style: Theme.of(context).textTheme.bodyLarge),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: trailing,
      onTap: onTap,
    );
  }
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({required this.title, required this.value, required this.onChanged, this.subtitle});

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      minVerticalPadding: 14,
      title: Text(title, style: Theme.of(context).textTheme.bodyLarge),
      subtitle: subtitle == null ? null : Text(subtitle!),
      value: value,
      onChanged: onChanged,
    );
  }
}

/// Desktop only: the folder Blimp scans for songs. Picking another scans
/// it straight away.
class _MusicFolderTile extends StatefulWidget {
  const _MusicFolderTile();

  @override
  State<_MusicFolderTile> createState() => _MusicFolderTileState();
}

class _MusicFolderTileState extends State<_MusicFolderTile> {
  late Future<String> _folder = DesktopLibrary.musicFolder();

  Future<void> _pick() async {
    final picked = await getDirectoryPath(initialDirectory: await _folder, confirmButtonText: 'Use this folder');
    if (picked == null || !mounted) return;
    await DesktopLibrary.setMusicFolder(picked);
    setState(() => _folder = DesktopLibrary.musicFolder());
    if (mounted) await rescanLibrary(context);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _folder,
      builder: (context, snapshot) => _SettingsTile(
        title: 'Music folder',
        // Shown the Windows way, with backslashes.
        subtitle: snapshot.data?.replaceAll('/', r'\') ?? '',
        onTap: _pick,
      ),
    );
  }
}
