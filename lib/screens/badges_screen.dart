import 'package:flutter/material.dart';

import '../services/milestones.dart';
import '../services/music_controller.dart';
import '../theme.dart';

/// The listening streak and every badge, earned or still to aim for.
class BadgesScreen extends StatelessWidget {
  const BadgesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.of(context, const {MusicAspect.stats, MusicAspect.library});
    final streak = music.streak;
    final badges = music.badges;
    final earned = badges.where((b) => b.earned).length;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Streaks & badges')),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: StreakCard(streak: streak)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
              child: Text('Badges • $earned of ${badges.length}', style: textTheme.titleLarge),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                mainAxisExtent: 196,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: badges.length,
              itemBuilder: (context, i) => _BadgeTile(badge: badges[i]),
            ),
          ),
        ],
      ),
    );
  }
}

/// The days-in-a-row count, big, with the longest run beneath.
class StreakCard extends StatelessWidget {
  const StreakCard({super.key, required this.streak});

  final Streak streak;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final alive = streak.current > 0;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.large),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: alive
              ? const [Color(0xFFF97316), Color(0xFFDB2777)]
              : const [AppColors.surfaceHigh, AppColors.surface],
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.local_fire_department_rounded, size: 56, color: alive ? Colors.white : AppColors.textTertiary),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  streak.current == 1 ? '1 day' : '${streak.current} days',
                  style: textTheme.displaySmall?.copyWith(color: Colors.white),
                ),
                Text(
                  [
                    if (!alive)
                      'Play a song today to start a streak'
                    else if (!streak.playedToday)
                      'Play a song today to keep it going'
                    else
                      'in a row with music',
                    'Longest: ${streak.longest == 1 ? '1 day' : '${streak.longest} days'}',
                  ].join('\n'),
                  style: textTheme.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.85)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BadgeTile extends StatelessWidget {
  const _BadgeTile({required this.badge});

  final ListeningBadge badge;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final earned = badge.earned;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: earned ? AppColors.accentFaint : AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: earned ? AppColors.accentSoft : Colors.transparent),
      ),
      child: Column(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: earned ? AppColors.accent : AppColors.surfaceHigh,
            child: Icon(badge.icon, size: 28, color: earned ? AppColors.onAccent : AppColors.textTertiary),
          ),
          const SizedBox(height: 10),
          Text(badge.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.titleSmall),
          const SizedBox(height: 2),
          Expanded(
            child: Text(
              badge.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: textTheme.bodySmall,
            ),
          ),
          if (!earned) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: badge.fraction,
                minHeight: 4,
                backgroundColor: AppColors.surfaceHigh,
              ),
            ),
            const SizedBox(height: 6),
          ],
          Text(
            badge.progressText,
            style: textTheme.labelMedium?.copyWith(color: earned ? AppColors.accent : AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
