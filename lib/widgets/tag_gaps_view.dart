import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/music_controller.dart';
import '../services/tag_finder.dart';
import '../theme.dart';
import 'song_artwork.dart';

/// Settings' Find missing tags page: songs with missing tags or covers, which
/// one click fills in from online.
class TagGapsView extends StatefulWidget {
  const TagGapsView({super.key});

  @override
  State<TagGapsView> createState() => _TagGapsViewState();
}

class _TagGapsViewState extends State<TagGapsView> {
  static const _agreedKey = 'tag_finder_agreed';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final music = MusicScope.of(context, const {MusicAspect.library});
    tagFinder.onChanged = music.load;
    tagFinder.scan(music.songs);
  }

  /// Runs [fix], first saying what's sent, the first time.
  Future<void> _withConsent(VoidCallback fix) async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_agreedKey) ?? false)) {
      if (!mounted) return;
      final agreed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: AppColors.sheet,
          title: const Text('Find tags online?'),
          content: const Text(tagFinderNotice),
          actions: [
            TextButton(
              style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Find tags')),
          ],
        ),
      );
      if (!(agreed ?? false)) return;
      await prefs.setBool(_agreedKey, true);
    }
    fix();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: tagFinder,
      builder: (context, _) {
        final gaps = tagFinder.gaps;
        final checking = tagFinder.checking;
        final untried = gaps.where((gap) => !tagFinder.fixes.containsKey(gap.song.id)).length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      checking != null
                          ? 'Checking covers: ${checking.$1} of ${checking.$2}'
                          : '${tagFinder.needing} ${tagFinder.needing == 1 ? 'song needs' : 'songs need'} tags',
                      style: textTheme.titleSmall,
                    ),
                  ),
                  if (tagFinder.running)
                    TextButton(onPressed: tagFinder.stop, child: const Text('Stop'))
                  else
                    FilledButton(
                      onPressed: untried == 0 ? null : () => _withConsent(tagFinder.fixAll),
                      child: const Text('Find all'),
                    ),
                ],
              ),
            ),
            if (checking != null) LinearProgressIndicator(value: checking.$1 / checking.$2),
            if (tagFinder.problem case final problem?)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                child: Text(problem, style: textTheme.bodySmall?.copyWith(color: AppColors.textSecondary)),
              ),
            if (tagFinder.unsupported > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(
                  '${tagFinder.unsupported} more in formats Blimp can’t save tags to. Only MP3 and FLAC can be filled in.',
                  style: textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
                ),
              ),
            Expanded(
              child: gaps.isEmpty
                  ? Center(
                      child: Text(
                        checking != null ? '' : 'All your songs have their tags and covers.',
                        style: textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
                      ),
                    )
                  : ListView.builder(
                      itemCount: gaps.length,
                      itemBuilder: (context, i) {
                        final gap = gaps[i];
                        return _GapTile(gap, onFind: () => _withConsent(() => tagFinder.fix([gap])));
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _GapTile extends StatelessWidget {
  const _GapTile(this.gap, {required this.onFind});

  final TagGap gap;
  final VoidCallback onFind;

  @override
  Widget build(BuildContext context) {
    final song = gap.song;
    final fix = tagFinder.fixes[song.id];
    final missing = tagFinder.lacking(gap);
    final lacking = missing.isEmpty ? null : 'Missing ${missing.map((tag) => tag.label).join(', ')}';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: SongArtwork(songId: song.id, size: 44, radius: 8),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        switch (fix?.state) {
          TagFixState.waiting => 'Waiting',
          TagFixState.working => 'Searching',
          _ => [?fix?.note, ?lacking].join(' · '),
        },
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: switch (fix?.state) {
        TagFixState.working => const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
        TagFixState.waiting => const Icon(Icons.schedule_rounded),
        _ when missing.isEmpty => Icon(Icons.check_circle_rounded, color: AppColors.accent),
        _ => IconButton(tooltip: 'Find tags', icon: const Icon(Icons.travel_explore_rounded), onPressed: onFind),
      },
    );
  }
}
