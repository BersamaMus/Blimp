import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/media_library.dart';
import '../services/music_controller.dart';
import '../theme.dart';
import 'shelf.dart';
import 'song_artwork.dart';

/// A sheet with everything known about the song's file: where it is, its
/// size and format, and its tags. Tapping the location opens its folder.
Future<void> showSongDetails(BuildContext context, Song song) {
  return showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
    builder: (_) => _SongDetails(song: song),
  );
}

class _SongDetails extends StatelessWidget {
  const _SongDetails({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: FutureBuilder(
        future: Future.wait([MediaLibrary.getFileInfo(song), MediaLibrary.getAudioFormat(song)]),
        builder: (context, snapshot) {
          final file = snapshot.data?[0] as ({String? name, String? path, DateTime? modified})?;
          final format = snapshot.data?[1] as AudioFormat?;
          final loading = snapshot.connectionState != ConnectionState.done;
          final path = file?.path;
          return ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            children: [
              Row(
                children: [
                  SongArtwork(songId: song.id, size: 56, radius: 10),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(song.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: textTheme.titleMedium),
                        HiResLine(
                          hiRes: MusicScope.read(context).isHiRes(song),
                          line: Text(song.artistName, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodyMedium),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (loading)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                const _Heading('File'),
                _Row('Name', file?.name),
                if (path != null) _Location(path: path),
                _Row('Size', song.size > 0 ? formatBytes(song.size) : null),
                _Row('Modified', _date(file?.modified)),
                _Row('Added', _date(song.dateAdded)),
                const _Heading('Audio'),
                _Row('Length', switch (song.duration) {
                  final d? when d > Duration.zero => formatDuration(d),
                  _ => null,
                }),
                _Row('Format', format?.codec),
                _Row('Bitrate', format?.bitrateText),
                _Row('Sample rate', format?.sampleRateText),
                _Row('Bit depth', switch (format?.bitsPerSample) {
                  final bits? => '$bits-bit',
                  _ => null,
                }),
                _Row('Channels', switch (format?.channels) {
                  1 => 'Mono',
                  2 => 'Stereo',
                  final n? => '$n channels',
                  null => null,
                }),
                const _Heading('Tags'),
                _Row('Title', song.title),
                _Row('Artist', song.artist),
                _Row('Album', song.album),
                _Row('Track', song.track != null && song.track! > 0 ? '${song.track}' : null),
                _Row('Year', song.year?.toString()),
                _Row('Genre', song.genre),
              ],
            ],
          );
        },
      ),
    );
  }

  static String? _date(DateTime? date) {
    if (date == null) return null;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 4),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: AppColors.accent, letterSpacing: 1.2),
      ),
    );
  }
}

/// A label and its value; left out when the value isn't known.
class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final value = this.value;
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 104, child: Text(label, style: textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary))),
          Expanded(child: SelectableText(value, style: textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// The file's folder, tappable to open it in the Files app. Where that isn't
/// possible, the path is copied instead so it can be pasted into one.
class _Location extends StatefulWidget {
  const _Location({required this.path});

  final String path;

  @override
  State<_Location> createState() => _LocationState();
}

class _LocationState extends State<_Location> {
  String? _note;

  /// The path as the system writes it: with backslashes on Windows.
  String _native(String path) => Platform.isWindows ? path.replaceAll('/', r'\') : path;

  Future<void> _open() async {
    final opened = await MediaLibrary.openFolder(widget.path);
    if (opened || !mounted) return;
    await Clipboard.setData(ClipboardData(text: _native(widget.path)));
    if (mounted) setState(() => _note = "Couldn't open the folder here, so its path was copied.");
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final folder = widget.path.contains('/') ? widget.path.substring(0, widget.path.lastIndexOf('/')) : widget.path;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text('Location', style: textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
          ),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: _open,
              onLongPress: () async {
                await Clipboard.setData(ClipboardData(text: _native(widget.path)));
                if (mounted) setState(() => _note = 'Path copied.');
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(_native(folder), style: textTheme.bodyMedium?.copyWith(color: AppColors.accent)),
                      ),
                      const SizedBox(width: 6),
                      Icon(Icons.folder_open_rounded, size: 18, color: AppColors.accent),
                    ],
                  ),
                  if (_note case final note?)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(note, style: textTheme.bodySmall),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
