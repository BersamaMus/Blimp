import 'package:flutter/material.dart';

import '../services/desktop_library.dart';
import '../services/media_library.dart';
import '../services/music_controller.dart';
import '../services/tag_editor.dart';
import '../theme.dart';
import '../widgets/song_artwork.dart';

/// Edits a song's tags: what it's called, who it's by, the album and so on.
/// They're saved into the file itself, so other apps see them too.
class TagEditorScreen extends StatefulWidget {
  const TagEditorScreen({super.key, required this.song});

  final Song song;

  @override
  State<TagEditorScreen> createState() => _TagEditorScreenState();
}

class _TagEditorScreenState extends State<TagEditorScreen> {
  late final Map<String, ({String label, String initial, bool number})> _fields = {
    'title': (label: 'Title', initial: widget.song.title, number: false),
    'artist': (label: 'Artist', initial: widget.song.artist ?? '', number: false),
    'album': (label: 'Album', initial: widget.song.album ?? '', number: false),
    'albumArtist': (label: 'Album artist', initial: widget.song.albumArtist ?? '', number: false),
    'genre': (label: 'Genre', initial: widget.song.genre ?? '', number: false),
    'year': (label: 'Year', initial: '${widget.song.year ?? ''}', number: true),
    'track': (label: 'Track', initial: (widget.song.track ?? 0) > 0 ? '${widget.song.track}' : '', number: true),
    'disc': (label: 'Disc', initial: (widget.song.disc ?? 0) > 0 ? '${widget.song.disc}' : '', number: true),
  };

  late final _controllers = {
    for (final MapEntry(:key, :value) in _fields.entries) key: TextEditingController(text: value.initial),
  };

  bool _saving = false;

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// The field's new value, or null if it wasn't changed.
  String? _changed(String key) {
    final text = _controllers[key]!.text.trim();
    return text == _fields[key]!.initial ? null : text;
  }

  Future<void> _save() async {
    final changes = TagChanges(
      title: _changed('title'),
      artist: _changed('artist'),
      album: _changed('album'),
      albumArtist: _changed('albumArtist'),
      genre: _changed('genre'),
      year: _changed('year'),
      track: _changed('track'),
      disc: _changed('disc'),
    );
    if (changes.isEmpty) return Navigator.pop(context);
    if (changes.title?.isEmpty ?? false) return _say('A song needs a title.');
    final music = MusicScope.read(context);
    setState(() => _saving = true);
    try {
      final saved = await TagEditor.save(widget.song, changes);
      if (!saved) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      MediaLibrary.forget(widget.song.id);
      // Read again, so the library shows the new tags.
      await music.load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tags saved')));
      Navigator.pop(context);
    } on TagEditException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _say(e.message);
    }
  }

  void _say(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    Widget field(String key) {
      final info = _fields[key]!;
      return TextField(
        controller: _controllers[key],
        enabled: !_saving,
        keyboardType: info.number ? TextInputType.number : TextInputType.text,
        textCapitalization: info.number ? TextCapitalization.none : TextCapitalization.words,
        decoration: InputDecoration(labelText: info.label),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit tags'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            TextButton(onPressed: _save, child: const Text('Save')),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Row(
            children: [
              SongArtwork(songId: widget.song.id, size: 56, radius: 10),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  widget.song.fileName ?? widget.song.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          for (final key in ['title', 'artist', 'album', 'albumArtist', 'genre']) ...[
            field(key),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(child: field('year')),
              const SizedBox(width: 12),
              Expanded(child: field('track')),
              const SizedBox(width: 12),
              Expanded(child: field('disc')),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            isDesktop
                ? 'Saved into the file, so other apps see the changes too.'
                : 'Saved into the file, so other apps see the changes too. Android asks you to allow it first.',
            style: textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
