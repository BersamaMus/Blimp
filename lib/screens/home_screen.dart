import 'dart:math';

import 'package:flutter/material.dart';

import '../services/decades.dart';
import '../services/media_library.dart';
import '../services/music_controller.dart';
import '../services/time_machine.dart';
import '../theme.dart';
import '../widgets/app_menu.dart';
import '../widgets/shelf.dart';
import '../widgets/song_artwork.dart';
import '../widgets/song_options.dart';
import '../widgets/song_pager.dart';
import 'app_shell.dart';
import 'collection_screen.dart';
import 'now_playing_screen.dart';
import 'search_screen.dart';

/// Quick picks (a random selection) and your listening history.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  /// How many Quick picks are listed; playing them carries on through the
  /// whole library.
  static const _shownPicks = SongPager.shown;

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.library, MusicAspect.history});
    final picks = music.quickPicks;
    final history = music.recentlyPlayed.take(20).toList();
    final recentlyAdded = music.recentlyAdded.take(20).toList();
    final trips = music.timeTrips;
    final decades = music.decades;

    return Scaffold(
      // Pulling down shuffles Quick picks afresh, as the Refresh button does.
      body: RefreshIndicator(
        color: AppColors.accent,
        backgroundColor: AppColors.surfaceHigh,
        onRefresh: () async {
          music.reshuffleQuickPicks();
          // Long enough to see that something happened.
          await Future<void>.delayed(const Duration(milliseconds: 400));
        },
        child: CustomScrollView(
          // So it can be pulled even when everything fits on screen.
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              floating: true,
              snap: true,
              titleSpacing: 20,
              title: const AppLogo(),
              actions: [
                IconButton(
                  tooltip: 'Search',
                  icon: const Icon(Icons.search),
                  onPressed: () => openPage(const SearchScreen()),
                ),
                const AppMenuButton(),
                const SizedBox(width: 4),
              ],
            ),
            SliverToBoxAdapter(
              child: ShelfHeader(
                title: 'Quick picks',
                extraActions: [
                  IconButton(
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh_rounded),
                    color: AppColors.textSecondary,
                    onPressed: music.reshuffleQuickPicks,
                  ),
                  IconButton(
                    tooltip: 'Play a random pick',
                    icon: const Icon(Icons.shuffle_rounded),
                    color: AppColors.textSecondary,
                    // As if a random one of the picks shown were tapped.
                    onPressed: picks.isEmpty
                        ? null
                        : () => music.startRadio(picks[Random().nextInt(min(picks.length, _shownPicks))]),
                  ),
                ],
                actionLabel: 'Play all',
                actionIcon: Icons.play_arrow_rounded,
                onAction: music.playQuickPicks,
              ),
            ),
            SliverToBoxAdapter(
              child: SongPager(
                songs: picks.take(_shownPicks).toList(),
                showFavourite: true,
                // A radio of that song, not the whole list.
                onTap: (i) => music.startRadio(picks[i]),
              ),
            ),
            SliverToBoxAdapter(
              child: ShelfHeader(
                title: 'History',
                actionLabel: history.isEmpty ? null : 'See all',
                onAction: () => openPage(CollectionScreen.history()),
              ),
            ),
            SliverToBoxAdapter(child: history.isEmpty ? const _EmptyHistory() : _SongRow(songs: history)),
            if (trips.isNotEmpty) SliverToBoxAdapter(child: _TimeMachine(trips: trips)),
            if (decades.length > 1) ...[
              const SliverToBoxAdapter(
                child: ShelfHeader(title: 'Decade radio', subtitle: 'Shuffles your songs from one decade'),
              ),
              SliverToBoxAdapter(child: _DecadeRow(decades: decades)),
            ],
            if (recentlyAdded.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: ShelfHeader(
                  title: 'Recently added',
                  actionLabel: 'See all',
                  onAction: () => openPage(CollectionScreen.recentlyAdded()),
                ),
              ),
              SliverToBoxAdapter(child: _SongRow(songs: recentlyAdded)),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }
}

/// The app's mark: a yellow rounded square with a black waveform, as the
/// launcher icon.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(9)),
          child: const Icon(Icons.graphic_eq_rounded, size: 20, color: Color(0xFF111111)),
        ),
        const SizedBox(width: 10),
        const Text('Blimp'),
      ],
    );
  }
}

/// Recently played songs in a single sideways row.
/// A row of song cards (History, Recently added): tapping one plays the
/// row from there.
class _SongRow extends StatelessWidget {
  const _SongRow({required this.songs});

  final List<Song> songs;

  static const _tileWidth = 132.0;

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.read(context);
    return Shelf(
      height: _tileWidth + 76,
      itemCount: songs.length,
      itemBuilder: (context, i) => MediaCard(
        width: _tileWidth,
        art: SongArtwork(songId: songs[i].id, size: null, radius: AppRadius.card),
        title: songs[i].title,
        subtitle: songs[i].artistName,
        hiRes: music.isHiRes(songs[i]),
        onTap: () => playAndOpen(context, () => music.playSongs(songs, index: i)),
        onLongPress: () => showSongOptions(context, songs[i]),
        onPlay: () => music.playSongs(songs, index: i),
      ),
    );
  }
}

/// What was played around this week some time ago; the button beside the
/// heading goes to another time, when there's more than one.
class _TimeMachine extends StatefulWidget {
  const _TimeMachine({required this.trips});

  final List<TimeTrip> trips;

  @override
  State<_TimeMachine> createState() => _TimeMachineState();
}

class _TimeMachineState extends State<_TimeMachine> {
  int _shown = 0;

  @override
  Widget build(BuildContext context) {
    final trips = widget.trips;
    final trip = trips[_shown % trips.length];
    final music = MusicScope.read(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ShelfHeader(
          title: 'Time machine',
          subtitle: trip.label,
          extraActions: [
            if (trips.length > 1)
              IconButton(
                tooltip: 'Another time',
                icon: const Icon(Icons.history_toggle_off_rounded),
                color: AppColors.textSecondary,
                onPressed: () => setState(() => _shown++),
              ),
          ],
          actionLabel: 'Play',
          actionIcon: Icons.play_arrow_rounded,
          onAction: () => music.playSongs([for (final s in trip.songs) if (!music.isUnwanted(s)) s]),
        ),
        _SongRow(songs: trip.songs),
      ],
    );
  }
}

/// A card for each decade in the library; tapping one shuffles its songs.
class _DecadeRow extends StatelessWidget {
  const _DecadeRow({required this.decades});

  final List<Decade> decades;

  static const _width = 132.0;

  /// Each decade's own pair of colours, going round.
  static const _colors = [
    (Color(0xFFF97316), Color(0xFFDB2777)),
    (Color(0xFF8B5CF6), Color(0xFF22D3EE)),
    (Color(0xFF14B8A6), Color(0xFF84CC16)),
    (Color(0xFFFACC15), Color(0xFFEF4444)),
    (Color(0xFF3B82F6), Color(0xFFA855F7)),
    (Color(0xFFEC4899), Color(0xFFF59E0B)),
  ];

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.read(context);
    final textTheme = Theme.of(context).textTheme;
    return Shelf(
      height: _width + 76,
      itemCount: decades.length,
      itemBuilder: (context, i) {
        final decade = decades[i];
        final (from, to) = _colors[(decade.start ~/ 10) % _colors.length];
        return MediaCard(
          width: _width,
          art: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.card),
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [from, to]),
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: FittedBox(
                  child: Text(
                    decade.shortLabel,
                    style: textTheme.displaySmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      shadows: const [Shadow(blurRadius: 12, color: Color(0x55000000))],
                    ),
                  ),
                ),
              ),
            ),
          ),
          title: decade.label,
          subtitle: [
            '${decade.songs.length} songs',
            ...decade.topGenres.take(1),
          ].join(' • '),
          onTap: () => music.playDecade(decade),
          onPlay: () => music.playDecade(decade),
        );
      },
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(AppRadius.card)),
      child: Row(
        children: [
          Icon(Icons.history, color: AppColors.accent),
          const SizedBox(width: 14),
          Expanded(child: Text('Songs you play will show up here.', style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
