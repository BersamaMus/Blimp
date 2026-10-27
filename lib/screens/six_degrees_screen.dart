import 'dart:math';

import 'package:flutter/material.dart';

import '../services/artist_links.dart';
import '../services/music_controller.dart';
import '../services/search_text.dart';
import '../theme.dart';
import '../widgets/shelf.dart';
import '../widgets/song_artwork.dart';
import 'app_shell.dart';
import 'artist_screen.dart';
import 'now_playing_screen.dart';

/// Six degrees: how one artist in the library links to another through
/// songs they share (features, collaborations), one step at a time.
class SixDegreesScreen extends StatefulWidget {
  const SixDegreesScreen({super.key, required this.from});

  final String from;

  @override
  State<SixDegreesScreen> createState() => _SixDegreesScreenState();
}

class _SixDegreesScreenState extends State<SixDegreesScreen> {
  String? _to;

  /// Picks one of the furthest artists that can be reached, for the longest
  /// chain there is.
  void _surprise(Map<String, int> distances) {
    final furthest = distances.values.fold(0, max);
    final picks = [
      for (final MapEntry(:key, :value) in distances.entries)
        if (value == furthest && key != widget.from && key != _to) key,
    ];
    if (picks.isEmpty) return;
    setState(() => _to = picks[Random().nextInt(picks.length)]);
  }

  Future<void> _choose(Map<String, int> distances) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      builder: (_) => _ArtistPicker(names: [for (final name in distances.keys) if (name != widget.from) name]),
    );
    if (picked != null) setState(() => _to = picked);
  }

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.library});
    final graph = music.artistGraph;
    final from = widget.from;
    final distances = graph.distancesFrom(from);
    final neighbours = graph.neighbours(from);
    final to = _to;
    final path = to == null ? null : graph.path(from, to);
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Six degrees')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Row(
              children: [
                _Avatar(name: from, size: 64),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(from, maxLines: 2, overflow: TextOverflow.ellipsis, style: textTheme.titleLarge),
                      Text(
                        neighbours.isEmpty
                            ? 'No links yet'
                            : '${_artists(neighbours.length)} one step away • ${_artists(distances.length - 1)} in reach',
                        style: textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (neighbours.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 32),
              child: MessageView(
                icon: Icons.hub_outlined,
                text: "None of this artist's songs credit anyone else in your library, so there's nothing to link "
                    'them to yet.',
              ),
            )
          else ...[
            const ShelfHeader(title: 'Linked with'),
            Shelf(
              height: 112 + 64,
              itemCount: neighbours.length,
              itemBuilder: (context, i) => _LinkCard(link: neighbours[i], onTap: () => setState(() => _to = neighbours[i].artist)),
            ),
            ShelfHeader(
              title: 'Find the link',
              extraActions: [
                TextButton.icon(
                  onPressed: distances.length > 2 ? () => _surprise(distances) : null,
                  icon: const Icon(Icons.casino_outlined, size: 20),
                  label: const Text('Surprise me'),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ListTile(
                tileColor: AppColors.surface,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
                leading: const Icon(Icons.person_search_outlined),
                title: Text(to ?? 'Choose an artist'),
                subtitle: Text(to == null ? 'See how $from links to them' : 'Tap to choose someone else'),
                trailing: const Icon(Icons.expand_more_rounded),
                onTap: () => _choose(distances),
              ),
            ),
            if (to != null && path != null) _Chain(from: from, steps: path),
          ],
        ],
      ),
    );
  }

  static String _artists(int n) => n == 1 ? '1 artist' : '$n artists';
}

/// The steps from one artist to another, each through the song that links
/// them, and a button to play those songs.
class _Chain extends StatelessWidget {
  const _Chain({required this.from, required this.steps});

  final String from;
  final List<ArtistLink> steps;

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.read(context);
    final textTheme = Theme.of(context).textTheme;
    final degrees = steps.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  degrees == 1 ? 'One degree apart' : '$degrees degrees apart',
                  style: textTheme.titleMedium?.copyWith(color: AppColors.accent),
                ),
              ),
              PillButton(
                label: 'Play the chain',
                icon: Icons.play_arrow_rounded,
                filled: true,
                onPressed: () => playAndOpen(context, () => music.playSongs([for (final step in steps) step.via])),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Node(name: from),
          for (final step in steps) ...[
            _Step(link: step),
            _Node(name: step.artist),
          ],
        ],
      ),
    );
  }
}

/// An artist in the chain; tapping opens their page.
class _Node extends StatelessWidget {
  const _Node({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final known = MusicScope.read(context).artistNamed(name) != null;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      onTap: known ? () => openPage(ArtistScreen(artistName: name)) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            _Avatar(name: name, size: 44),
            const SizedBox(width: 14),
            Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium)),
          ],
        ),
      ),
    );
  }
}

/// The song linking two artists in the chain, on the line between them.
class _Step extends StatelessWidget {
  const _Step({required this.link});

  final ArtistLink link;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final song = link.via;
    return IntrinsicHeight(
      child: Row(
        children: [
          // The line, under the avatars' centres.
          const SizedBox(
            width: 44,
            child: Center(child: VerticalDivider(width: 2, thickness: 2, color: AppColors.accentSoft)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Material(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.card),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => playAndOpen(context, () => MusicScope.read(context).playSongs([song])),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      children: [
                        SongArtwork(songId: song.id, size: 40, radius: 8),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodyLarge),
                              Text(
                                link.together ? 'On the same song' : 'On the same compilation${_album(song.album)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.play_arrow_rounded, color: AppColors.textSecondary),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _album(String? album) => album == null ? '' : ', $album';
}

/// A linked artist on the shelf, with the song that links them.
class _LinkCard extends StatelessWidget {
  const _LinkCard({required this.link, required this.onTap});

  final ArtistLink link;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MediaCard(
      width: 112,
      circle: true,
      art: _Avatar(name: link.artist, size: null),
      title: link.artist,
      subtitle: link.together ? link.via.title : 'Compilation',
      onTap: onTap,
    );
  }
}

/// The artist's picture, or a plain icon for a name credited only as a
/// guest, with no songs of their own in the library.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, required this.size});

  final String name;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final artist = MusicScope.read(context).artistNamed(name);
    if (artist != null) return ArtistAvatar(songId: artist.cover.id, size: size);
    return SizedBox.square(
      dimension: size,
      child: const CircleAvatar(
        backgroundColor: AppColors.surfaceHigh,
        child: Icon(Icons.person_rounded, color: AppColors.textTertiary),
      ),
    );
  }
}

/// A searchable list of the artists that can be reached.
class _ArtistPicker extends StatefulWidget {
  const _ArtistPicker({required this.names});

  final List<String> names;

  @override
  State<_ArtistPicker> createState() => _ArtistPickerState();
}

class _ArtistPickerState extends State<_ArtistPicker> {
  String _query = '';
  late final _sorted = [...widget.names]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  @override
  Widget build(BuildContext context) {
    final query = searchKey(_query);
    final shown = [for (final name in _sorted) if (query.isEmpty || searchKey(name).contains(query)) name];
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Find an artist'),
              onChanged: (text) => setState(() => _query = text),
            ),
          ),
          Expanded(
            child: shown.isEmpty
                ? const MessageView(icon: Icons.person_off_outlined, text: 'No artist in reach by that name.')
                : ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (context, i) => ListTile(
                      leading: _Avatar(name: shown[i], size: 40),
                      title: Text(shown[i]),
                      onTap: () => Navigator.pop(context, shown[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
