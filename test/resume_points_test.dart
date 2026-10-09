import 'package:blimp/services/media_library.dart';
import 'package:blimp/services/resume_points.dart';
import 'package:flutter_test/flutter_test.dart';

Song _song(int id, {Duration duration = const Duration(minutes: 4), bool spoken = false}) =>
    Song(id: id, title: 'Song $id', uri: 'content://$id', duration: duration, spoken: spoken);

void main() {
  final podcast = _song(1, duration: const Duration(minutes: 50), spoken: true);

  test('podcasts, audiobooks and long songs resume; ordinary songs don\'t', () {
    expect(ResumePoints.isResumable(podcast), isTrue);
    expect(ResumePoints.isResumable(_song(2, duration: const Duration(minutes: 45))), isTrue);
    expect(ResumePoints.isResumable(_song(3)), isFalse);
    expect(ResumePoints().save(_song(3), const Duration(minutes: 2)), isFalse);
  });

  test('keeps the place partway through, and forgets it near the start or end', () {
    final points = ResumePoints();
    expect(points.save(podcast, const Duration(minutes: 20)), isTrue);
    expect(points.of(podcast), const Duration(minutes: 20));
    expect(points.progressOf(podcast), closeTo(0.4, 1e-9));

    // Finished: within the last 30 seconds.
    expect(points.save(podcast, const Duration(minutes: 49, seconds: 45)), isTrue);
    expect(points.of(podcast), isNull);

    points.save(podcast, const Duration(minutes: 20));
    // Back to the start.
    points.save(podcast, const Duration(seconds: 5));
    expect(points.of(podcast), isNull);
  });

  test('survives saving and loading', () {
    final points = ResumePoints()..save(podcast, const Duration(minutes: 12, seconds: 3));
    final loaded = ResumePoints.decode([...points.encode(), 'garbage', '5:x']);
    expect(loaded.of(podcast), const Duration(minutes: 12, seconds: 3));
  });
}
