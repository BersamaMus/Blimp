import 'package:flutter/material.dart';

import '../services/listening_stats.dart';
import '../services/music_controller.dart';
import '../theme.dart';
import '../widgets/app_menu.dart';
import '../widgets/listening_chart.dart';
import '../widgets/shelf.dart';
import '../widgets/song_artwork.dart';
import 'app_shell.dart';
import 'artist_screen.dart';
import 'badges_screen.dart';
import 'now_playing_screen.dart';

/// Listening time, plays and favourites for a day, week, month or all time.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  StatsRange _range = StatsRange.week;

  /// 0 for the current period, -1 for the one before, and so on.
  int _offset = 0;

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.stats, MusicAspect.library});
    final stats = music.statsFor(_range, offset: _offset);
    final period = stats.period;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            titleSpacing: 20,
            title: const Text('Listening stats'),
            actions: const [AppMenuButton(), SizedBox(width: 4)],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: SegmentedPills(
                labels: [for (final r in StatsRange.values) r.label],
                selected: _range.index,
                onChanged: (i) => setState(() {
                  _range = StatsRange.values[i];
                  _offset = 0;
                }),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Earlier',
                    icon: const Icon(Icons.chevron_left_rounded),
                    onPressed: period.canGoBack ? () => setState(() => _offset--) : null,
                  ),
                  Expanded(
                    child: Text(period.label, textAlign: TextAlign.center, style: textTheme.titleMedium),
                  ),
                  IconButton(
                    tooltip: 'Later',
                    icon: const Icon(Icons.chevron_right_rounded),
                    onPressed: period.canGoForward ? () => setState(() => _offset++) : null,
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(child: _Headline(stats: stats)),
          if (music.streak.longest > 0) SliverToBoxAdapter(child: _Milestones(music: music)),
          if (stats.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 24),
                child: MessageView(
                  icon: Icons.insights_rounded,
                  text: 'No listening here yet.\nPlay some music and your stats will show up.',
                ),
              ),
            )
          else
            ..._details(context, music, stats),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  List<Widget> _details(BuildContext context, MusicController music, ListeningStats stats) {
    final textTheme = Theme.of(context).textTheme;
    return [
      SliverToBoxAdapter(
        child: _Card(
          title: 'Listening time',
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 16, 12),
            child: ListeningChart(buckets: stats.buckets),
          ),
        ),
      ),
      if (stats.topSongs.isNotEmpty)
        SliverToBoxAdapter(
          child: _Card(
            title: 'Top songs',
            child: Column(
              children: [
                for (final (i, s) in stats.topSongs.indexed)
                  _RankedRow(
                    rank: i + 1,
                    art: SongArtwork(songId: s.song.id, size: 44, radius: 10),
                    title: s.song.title,
                    subtitle:
                        '${s.song.artistName} • ${_plays(s.plays)} • '
                        '${formatListeningTime(Duration(milliseconds: s.listenedMs))}',
                    hiRes: music.isHiRes(s.song),
                    onTap: () =>
                        playAndOpen(context, () => music.playSongs([for (final t in stats.topSongs) t.song], index: i)),
                  ),
              ],
            ),
          ),
        ),
      if (stats.topArtists.isNotEmpty)
        SliverToBoxAdapter(
          child: _Card(
            title: 'Top artists',
            child: Column(
              children: [
                for (final (i, a) in stats.topArtists.indexed)
                  _RankedRow(
                    rank: i + 1,
                    art: switch (music.artistNamed(a.name)) {
                      final artist? => ArtistAvatar(songId: artist.cover.id, size: 44),
                      null => const CircleAvatar(
                        radius: 22,
                        backgroundColor: AppColors.surfaceHigh,
                        child: Icon(Icons.person_rounded, color: AppColors.textTertiary),
                      ),
                    },
                    title: a.name,
                    subtitle: '${formatListeningTime(Duration(milliseconds: a.listenedMs))} • ${_plays(a.plays)}',
                    onTap: music.artistNamed(a.name) == null ? null : () => openPage(ArtistScreen(artistName: a.name)),
                  ),
              ],
            ),
          ),
        ),
      if (stats.topGenres.isNotEmpty)
        SliverToBoxAdapter(
          child: _Card(
            title: 'Top genres',
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                children: [
                  for (final g in stats.topGenres)
                    ShareBar(
                      label: g.name,
                      share: g.listenedMs / stats.genreTotalMs,
                      detail: formatListeningTime(Duration(milliseconds: g.listenedMs)),
                    ),
                ],
              ),
            ),
          ),
        ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: Text(
            'A song counts as played after 30 seconds of listening.',
            textAlign: TextAlign.center,
            style: textTheme.bodySmall,
          ),
        ),
      ),
    ];
  }

  static String _plays(int n) => n == 1 ? '1 play' : '$n plays';
}

/// The hero listening time, then plays, songs and artists.
class _Headline extends StatelessWidget {
  const _Headline({required this.stats});

  final ListeningStats stats;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final average = stats.averagePerDay;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatListeningTime(stats.total),
            style: textTheme.displayMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1.5),
          ),
          Text(
            [
              'of listening',
              if (average != null && !stats.isEmpty) 'about ${formatListeningTime(average)} a day',
            ].join(' • '),
            style: textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _StatTile(label: 'Plays', value: '${stats.plays}'),
              const SizedBox(width: 10),
              _StatTile(label: 'Songs', value: '${stats.songCount}'),
              const SizedBox(width: 10),
              _StatTile(label: 'Artists', value: '${stats.artistCount}'),
            ],
          ),
        ],
      ),
    );
  }
}

/// The listening streak and badges earned, each opening the Badges page.
class _Milestones extends StatelessWidget {
  const _Milestones({required this.music});

  final MusicController music;

  @override
  Widget build(BuildContext context) {
    final streak = music.streak;
    final badges = music.badges;
    final earned = badges.where((b) => b.earned).length;
    final next = badges.where((b) => !b.earned).firstOrNull;
    void open() => openPage(const BadgesScreen());
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: Row(
        children: [
          _MilestoneTile(
            icon: Icons.local_fire_department_rounded,
            iconColor: streak.current > 0 ? const Color(0xFFF97316) : AppColors.textTertiary,
            title: streak.current == 1 ? '1-day streak' : '${streak.current}-day streak',
            subtitle: streak.current > 0 && !streak.playedToday ? 'Play today to keep it' : 'Longest: ${streak.longest}',
            onTap: open,
          ),
          const SizedBox(width: 10),
          _MilestoneTile(
            icon: Icons.military_tech_rounded,
            iconColor: earned > 0 ? AppColors.accent : AppColors.textTertiary,
            title: '$earned of ${badges.length} badges',
            subtitle: next == null ? 'Every one earned' : 'Next: ${next.title}',
            onTap: open,
          ),
        ],
      ),
    );
  }
}

class _MilestoneTile extends StatelessWidget {
  const _MilestoneTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Expanded(
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(icon, color: iconColor, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.titleSmall),
                      Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(AppRadius.card)),
        child: Column(
          children: [
            FittedBox(
              child: Text(value, style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 2),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// A titled, rounded panel.
class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(AppRadius.large)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          child,
        ],
      ),
    );
  }
}

class _RankedRow extends StatelessWidget {
  const _RankedRow({
    required this.rank,
    required this.art,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.hiRes = false,
  });

  final int rank;
  final bool hiRes;
  final Widget art;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text('$rank', style: textTheme.titleMedium?.copyWith(color: AppColors.textSecondary)),
            ),
            art,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodyLarge),
                  HiResLine(
                    hiRes: hiRes,
                    line: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodySmall),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
