import 'package:blimp/services/queue_order.dart';
import 'package:flutter_test/flutter_test.dart';

/// An order over [length] queue items, the ones in [autoplay] added by autoplay.
QueueShuffleOrder _order(int length, {Set<int> autoplay = const {}}) =>
    QueueShuffleOrder(isAutoplay: autoplay.contains)..insert(0, length);

void main() {
  test('shuffling puts the playing song first and autoplay songs last', () {
    final order = _order(6, autoplay: {4, 5})..shuffle(initialIndex: 2);
    expect(order.indices.first, 2);
    expect(order.indices.sublist(4).toSet(), {4, 5});
    expect(order.indices.toSet(), {0, 1, 2, 3, 4, 5});
  });

  test('songs inserted with a place go there, together and in order', () {
    final order = _order(4)
      ..indices.setAll(0, [2, 0, 3, 1])
      // "Play next" while queue item 2 plays: inserted after it in the queue,
      // and straight after it in play order.
      ..insertAt = (index: 3, position: 1)
      ..insert(3, 2);
    // Items 3 and up moved along by the two inserted.
    expect(order.indices, [2, 3, 4, 0, 5, 1]);
  });

  test('a place meant for another insert is left for it', () {
    final order = _order(3)
      ..indices.setAll(0, [0, 1, 2])
      ..insertAt = (index: 1, position: 1)
      // Appended first, e.g. by autoplay topping up the queue.
      ..insert(3, 1);
    expect(order.insertAt, isNotNull);
    order.insert(1, 1);
    expect(order.indices.sublist(0, 2), [0, 1]);
    expect(order.insertAt, isNull);
  });

  test('songs inserted without a place never land among those already played', () {
    final order = _order(5)
      ..indices.setAll(0, [4, 3, 2, 1, 0])
      ..insert(2, 1);
    expect(order.indices.last, 2);
  });

  test('songs inserted with a place at the end of the queue still go there', () {
    final order = _order(4)
      ..indices.setAll(0, [0, 3, 1, 2])
      // "Play next" while the last queue item plays, second in play order.
      ..insertAt = (index: 4, position: 2)
      ..insert(4, 2);
    expect(order.indices, [0, 3, 4, 5, 1, 2]);
  });

  test('a pending move is made instead of shuffling', () {
    final order = _order(4)
      ..indices.setAll(0, [3, 1, 0, 2])
      ..pendingMove = (from: 3, to: 0)
      ..shuffle(initialIndex: 3);
    expect(order.indices, [2, 3, 1, 0]);
    expect(order.pendingMove, isNull);
  });
}
