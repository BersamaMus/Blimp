import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../services/folders.dart';
import '../services/media_library.dart';
import '../services/music_controller.dart';
import '../theme.dart';
import '../widgets/shelf.dart';
import '../widgets/song_tile.dart';

const _routePrefix = 'folder:';

/// A route to the folder at [path]. [inLibrary] says the folders opened from
/// Library's Folders view, which shows the top folder itself. [highlight] is
/// a song to scroll to and point out, as "Go to folder" does.
Route<void> folderRoute(String path, {bool inLibrary = false, Song? highlight}) => MaterialPageRoute(
      settings: RouteSettings(name: '$_routePrefix$path'),
      builder: (_) => FolderScreen(path: path, inLibrary: inLibrary, highlight: highlight),
    );

/// The songs and subfolders in one folder, with a path bar to jump back up.
class FolderScreen extends StatefulWidget {
  const FolderScreen({super.key, required this.path, this.inLibrary = false, this.highlight});

  /// Looked up on each build so the page follows library rescans.
  final String path;
  final bool inLibrary;
  final Song? highlight;

  @override
  State<FolderScreen> createState() => _FolderScreenState();
}

class _FolderScreenState extends State<FolderScreen> {
  String get path => widget.path;
  bool get inLibrary => widget.inLibrary;

  final _scroll = ScrollController();

  /// The first song's row, to measure rows by, and the highlighted song's.
  final _firstSongKey = GlobalKey();
  final _highlightKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    if (widget.highlight != null) WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToHighlight());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Brings the highlighted song into view. A long folder only builds the
  /// rows on screen, so it first jumps to about where the song is, worked
  /// out from the first song's row, then lines it up once it's built.
  void _scrollToHighlight() {
    final song = widget.highlight;
    final folder = MusicScope.read(context).folderAt(path);
    if (song == null || folder == null || !_scroll.hasClients) return;
    final index = folder.songs.indexOf(song);
    if (index < 0) return;
    final first = _firstSongKey.currentContext?.findRenderObject() as RenderBox?;
    if (_highlightKey.currentContext == null && first != null) {
      // Where the list would be scrolled to with the first song at the top.
      final firstTop = RenderAbstractViewport.of(first).getOffsetToReveal(first, 0).offset;
      final estimate = firstTop + index * first.size.height - _scroll.position.viewportDimension / 3;
      _scroll.jumpTo(estimate.clamp(0, _scroll.position.maxScrollExtent));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _highlightKey.currentContext;
      if (target != null && mounted) {
        Scrollable.ensureVisible(target, alignment: 0.3, duration: const Duration(milliseconds: 250));
      }
    });
  }

  /// Shows [target], one of this folder's parents: closes the folders opened
  /// below it, or opens it if it wasn't one of them.
  void _goUp(BuildContext context, Folder root, String target) {
    final navigator = Navigator.of(context);
    if (target == root.path && inLibrary) {
      // Library's Folders view is the top folder.
      navigator.popUntil((route) => !(route.settings.name?.startsWith(_routePrefix) ?? false));
      return;
    }
    String? landed;
    navigator.popUntil((route) {
      final name = route.settings.name;
      if (name != null && name.startsWith('$_routePrefix$target/')) return false;
      landed = name;
      return true;
    });
    if (landed != '$_routePrefix$target') navigator.push(folderRoute(target, inLibrary: inLibrary));
  }

  /// Leaves [folder]'s songs out of the library, and closes its page.
  void _hide(BuildContext context, Folder folder) {
    final music = MusicScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    music.hideFolder(folder.path);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Hid ${folder.name}. Manage hidden folders in Settings.'),
        // Goes away on its own like other messages, despite the action.
        persist: false,
        action: SnackBarAction(label: 'Undo', onPressed: () => music.unhideFolder(folder.path)),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.library});
    final folder = music.folderAt(path);
    final root = music.rootFolder;
    if (folder == null || root == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const MessageView(icon: Icons.folder_off_outlined, text: 'This folder no longer has any music.'),
      );
    }
    final songs = folder.allSongs;

    return Scaffold(
      appBar: AppBar(
        title: Text(folder.name),
        actions: [
          // The top folder holds everything, so hiding it would empty the library.
          if (folder != root)
            PopupMenuButton<bool>(
              tooltip: 'More',
              onSelected: (_) => _hide(context, folder),
              itemBuilder: (_) => const [PopupMenuItem(value: true, child: Text('Hide folder'))],
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: _PathBar(
            folders: folderChain(root, folder),
            onTap: (target) => _goUp(context, root, target.path),
          ),
        ),
      ),
      body: ListView(
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: PillButton(
                    label: 'Play',
                    icon: Icons.play_arrow_rounded,
                    filled: true,
                    onPressed: () => music.playSongs(songs),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: PillButton(
                    label: 'Shuffle',
                    icon: Icons.shuffle_rounded,
                    onPressed: () => music.playSongs(songs, shuffle: true),
                  ),
                ),
              ],
            ),
          ),
          for (final sub in folder.folders)
            FolderRow(
              folder: sub,
              onTap: () => Navigator.of(context).push(folderRoute(sub.path, inLibrary: inLibrary)),
            ),
          for (final (i, song) in folder.songs.indexed)
            KeyedSubtree(
              key: song == widget.highlight ? _highlightKey : (i == 0 ? _firstSongKey : null),
              child: _Flash(
                on: song == widget.highlight,
                child: SongTile(
                  song: song,
                  subtitle: song.fileName,
                  onTap: () => music.playSongs(folder.songs, index: i),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The folders from the top one down to this one, each tappable but the last.
class _PathBar extends StatelessWidget {
  const _PathBar({required this.folders, required this.onTap});

  final List<Folder> folders;
  final ValueChanged<Folder> onTap;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelLarge;
    return SizedBox(
      height: 40,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // Starts scrolled to the end, so the current folder shows.
          reverse: true,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          // At least the full width, so a short path still starts at the left.
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth - 24),
            child: Row(children: _crumbs(style)),
          ),
        ),
      ),
    );
  }

  List<Widget> _crumbs(TextStyle? style) => [
        for (final (i, folder) in folders.indexed) ...[
          if (i > 0) const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.textTertiary),
          i == folders.length - 1
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(folder.name, style: style?.copyWith(color: AppColors.accent)),
                )
              : InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => onTap(folder),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                    child: Text(folder.name, style: style?.copyWith(color: AppColors.textSecondary)),
                  ),
                ),
        ],
      ];
}

/// A subfolder: folder art, its name and how much music it holds.
class FolderRow extends StatelessWidget {
  const FolderRow({super.key, required this.folder, required this.onTap});

  final Folder folder;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const SizedBox.square(dimension: 56, child: FolderArt()),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodyLarge),
                  const SizedBox(height: 2),
                  Text(describeFolder(folder), maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "3 folders • 42 songs", or just the songs.
String describeFolder(Folder folder) {
  final songs = folder.allSongs.length;
  return [
    if (folder.folders.isNotEmpty) folder.folders.length == 1 ? '1 folder' : '${folder.folders.length} folders',
    songs == 1 ? '1 song' : '$songs songs',
  ].join(' • ');
}

/// A folder's square art: a folder icon on a plain tile.
class FolderArt extends StatelessWidget {
  const FolderArt({super.key});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: DecoratedBox(
        decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(AppRadius.art)),
        child: FractionallySizedBox(
          widthFactor: 0.45,
          heightFactor: 0.45,
          child: FittedBox(child: Icon(Icons.folder_rounded, color: AppColors.accent)),
        ),
      ),
    );
  }
}

/// Points out its child when [on]: an accent glow that fades away.
class _Flash extends StatefulWidget {
  const _Flash({required this.on, required this.child});

  final bool on;
  final Widget child;

  @override
  State<_Flash> createState() => _FlashState();
}

class _FlashState extends State<_Flash> with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));

  @override
  void initState() {
    super.initState();
    // After the page has slid in and scrolled there.
    if (widget.on) Future.delayed(const Duration(milliseconds: 450), () => mounted ? _fade.forward() : null);
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.on) return widget.child;
    return AnimatedBuilder(
      animation: _fade,
      child: widget.child,
      builder: (context, child) {
        // Up quickly, held, then gone.
        final t = _fade.value;
        final strength = t < 0.15 ? t / 0.15 : (t < 0.5 ? 1.0 : 1 - (t - 0.5) / 0.5);
        // Laid over the row, inset as its own highlight is.
        return Stack(
          children: [
            child!,
            Positioned.fill(
              left: 8,
              right: 8,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.22 * strength),
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
