import 'package:flutter/material.dart';

import '../services/music_controller.dart';
import '../services/smart_playlists.dart';
import '../theme.dart';
import '../widgets/shelf.dart';
import '../widgets/song_artwork.dart';
import 'app_shell.dart';
import 'collection_screen.dart';

/// Opens a smart playlist's page: its songs, with Edit and Delete.
void openSmartPlaylist(SmartPlaylist playlist) => openPage(smartPlaylistPage(playlist));

Widget smartPlaylistPage(SmartPlaylist playlist) => CollectionScreen.playlist(
  title: playlist.name,
  kindLine: 'Smart playlist',
  art: const PlaylistArt.smart(radius: AppRadius.card),
  // Looked up again so the page follows edits.
  songsOf: (music) => switch (music.smartPlaylistWithId(playlist.id)) {
    final current? => music.smartPlaylistSongs(current),
    null => const [],
  },
  emptyText: 'No songs match this playlist’s rules yet.',
  actions: [_SmartPlaylistMenu(id: playlist.id)],
);

enum _Action { edit, delete }

class _SmartPlaylistMenu extends StatelessWidget {
  const _SmartPlaylistMenu({required this.id});

  final String id;

  Future<void> _onAction(BuildContext context, _Action action) async {
    final music = MusicScope.read(context);
    final playlist = music.smartPlaylistWithId(id);
    if (playlist == null) return;
    final navigator = Navigator.of(context);
    switch (action) {
      case _Action.edit:
        final saved = await navigator.push<SmartPlaylist>(
          MaterialPageRoute(builder: (_) => SmartPlaylistEditor(playlist: playlist)),
        );
        // Opened afresh, so the page shows its new name.
        if (saved != null) navigator.pushReplacement(MaterialPageRoute(builder: (_) => smartPlaylistPage(saved)));
      case _Action.delete:
        final messenger = ScaffoldMessenger.of(context);
        final index = music.smartPlaylists.indexOf(playlist);
        navigator.pop();
        music.deleteSmartPlaylist(playlist);
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('Deleted ${playlist.name}'),
              // Goes away on its own like other messages, despite the action.
              persist: false,
              action: SnackBarAction(label: 'Undo', onPressed: () => music.restoreSmartPlaylist(playlist, index)),
            ),
          );
    }
  }

  @override
  Widget build(BuildContext context) => PopupMenuButton<_Action>(
    tooltip: 'More',
    onSelected: (action) => _onAction(context, action),
    itemBuilder: (_) => const [
      PopupMenuItem(value: _Action.edit, child: Text('Edit rules')),
      PopupMenuItem(value: _Action.delete, child: Text('Delete playlist')),
    ],
  );
}

/// Makes a new smart playlist, or changes [playlist]'s name and rules. Pops
/// with the playlist once saved.
class SmartPlaylistEditor extends StatefulWidget {
  const SmartPlaylistEditor({super.key, this.playlist});

  final SmartPlaylist? playlist;

  @override
  State<SmartPlaylistEditor> createState() => _SmartPlaylistEditorState();
}

class _SmartPlaylistEditorState extends State<SmartPlaylistEditor> {
  late final _name = TextEditingController(text: widget.playlist?.name ?? '');

  /// A copy being edited; the saved playlist only changes on Save.
  late final SmartPlaylist _draft = SmartPlaylist(
    id: widget.playlist?.id ?? '${DateTime.now().microsecondsSinceEpoch}',
    name: widget.playlist?.name ?? '',
    rules: [...?widget.playlist?.rules],
    matchAll: widget.playlist?.matchAll ?? true,
    sort: widget.playlist?.sort ?? SmartSort.random,
    limit: widget.playlist?.limit,
  );

  /// One per rule, so each row keeps its own value box as rules come and go.
  late final List<Key> _ruleKeys;

  @override
  void initState() {
    super.initState();
    // A new one starts with a rule to fill in.
    if (_draft.rules.isEmpty) _draft.rules = [SmartRule.on(SmartField.genre)];
    _ruleKeys = [for (final _ in _draft.rules) UniqueKey()];
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    _draft
      ..name = name
      ..rules = [for (final rule in _draft.rules) if (rule.isComplete) rule];
    MusicScope.read(context).saveSmartPlaylist(_draft);
    Navigator.pop(context, _draft);
  }

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.library});
    final textTheme = Theme.of(context).textTheme;
    final matching = music.smartPlaylistSongs(_draft);
    final complete = _draft.rules.any((r) => r.isComplete);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.playlist == null ? 'New smart playlist' : 'Edit smart playlist'),
        actions: [
          ListenableBuilder(
            listenable: _name,
            builder: (context, _) => TextButton(
              onPressed: _name.text.trim().isEmpty || !complete ? null : _save,
              child: const Text('Save'),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            controller: _name,
            autofocus: widget.playlist == null,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Forgotten favourites'),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Text('Songs that match', style: textTheme.titleSmall),
              const SizedBox(width: 12),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: true, label: Text('All rules')),
                  ButtonSegment(value: false, label: Text('Any rule')),
                ],
                selected: {_draft.matchAll},
                onSelectionChanged: (v) => setState(() => _draft.matchAll = v.first),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final (i, rule) in _draft.rules.indexed)
            _RuleRow(
              key: _ruleKeys[i],
              rule: rule,
              genres: music.genres,
              onChanged: (changed) => setState(() {
                // Another field makes it a new row, with a fresh value box.
                if (changed.field != rule.field) _ruleKeys[i] = UniqueKey();
                _draft.rules[i] = changed;
              }),
              onRemove: _draft.rules.length == 1
                  ? null
                  : () => setState(() {
                      _draft.rules.removeAt(i);
                      _ruleKeys.removeAt(i);
                    }),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() {
                _draft.rules = [..._draft.rules, SmartRule.on(SmartField.plays)];
                _ruleKeys.add(UniqueKey());
              }),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add rule'),
            ),
          ),
          const Divider(height: 32),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<SmartSort>(
                  initialValue: _draft.sort,
                  decoration: const InputDecoration(labelText: 'Order'),
                  items: [for (final sort in SmartSort.values) DropdownMenuItem(value: sort, child: Text(sort.label))],
                  onChanged: (sort) => setState(() => _draft.sort = sort ?? _draft.sort),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int?>(
                  initialValue: _draft.limit,
                  decoration: const InputDecoration(labelText: 'Limit'),
                  items: [
                    for (final limit in SmartPlaylist.limitOptions)
                      DropdownMenuItem(value: limit, child: Text(limit == null ? 'No limit' : '$limit songs')),
                  ],
                  onChanged: (limit) => setState(() => _draft.limit = limit),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            complete ? describeLength(matching.length, Duration.zero) : 'Fill in a rule to see what matches',
            style: textTheme.titleSmall?.copyWith(color: AppColors.accent),
          ),
          const SizedBox(height: 4),
          for (final song in matching.take(5))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: SongArtwork(songId: song.id, size: 40, radius: 8),
              title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(song.artistName, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          if (matching.length > 5) Text('…and ${matching.length - 5} more', style: textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// One rule: what it looks at, how it compares, and the value to compare with.
class _RuleRow extends StatefulWidget {
  const _RuleRow({super.key, required this.rule, required this.genres, required this.onChanged, this.onRemove});

  final SmartRule rule;
  final List<String> genres;
  final ValueChanged<SmartRule> onChanged;
  final VoidCallback? onRemove;

  @override
  State<_RuleRow> createState() => _RuleRowState();
}

class _RuleRowState extends State<_RuleRow> {
  late final _value = TextEditingController(text: widget.rule.value);

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  Widget _valueField() {
    final rule = widget.rule;
    if (!rule.op.takesValue) return const SizedBox.shrink();
    return switch (rule.field.value) {
      SmartValue.genre => DropdownButtonFormField<String>(
        initialValue: widget.genres.contains(rule.value) ? rule.value : null,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Genre'),
        items: [for (final genre in widget.genres) DropdownMenuItem(value: genre, child: Text(genre))],
        onChanged: (genre) => widget.onChanged(rule.copyWith(value: genre ?? '')),
      ),
      SmartValue.stars => DropdownButtonFormField<String>(
        initialValue: const ['1', '2', '3', '4', '5'].contains(rule.value) ? rule.value : null,
        decoration: const InputDecoration(labelText: 'Stars'),
        items: [
          for (var i = 1; i <= 5; i++) DropdownMenuItem(value: '$i', child: Text('★' * i)),
        ],
        onChanged: (stars) => widget.onChanged(rule.copyWith(value: stars ?? '')),
      ),
      final kind => TextField(
        controller: _value,
        keyboardType: kind == SmartValue.text ? TextInputType.text : TextInputType.number,
        decoration: InputDecoration(
          labelText: switch (kind) {
            SmartValue.days => 'Days',
            SmartValue.number => 'Number',
            _ => 'Text',
          },
        ),
        onChanged: (value) => widget.onChanged(rule.copyWith(value: value)),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final rule = widget.rule;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<SmartField>(
                    initialValue: rule.field,
                    decoration: const InputDecoration(labelText: 'Field'),
                    items: [
                      for (final field in SmartField.values) DropdownMenuItem(value: field, child: Text(field.label)),
                    ],
                    onChanged: (field) {
                      if (field != null && field != rule.field) widget.onChanged(SmartRule.on(field));
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<SmartOp>(
                    // Keyed by field, so a field with other comparisons starts afresh.
                    key: ValueKey(rule.field),
                    initialValue: rule.op,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Is'),
                    items: [for (final op in rule.field.ops) DropdownMenuItem(value: op, child: Text(op.label))],
                    onChanged: (op) => widget.onChanged(rule.copyWith(op: op)),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove rule',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: widget.onRemove,
                ),
              ],
            ),
            if (rule.op.takesValue)
              Padding(
                padding: const EdgeInsets.only(top: 8, right: 8),
                child: _valueField(),
              ),
          ],
        ),
      ),
    );
  }
}
