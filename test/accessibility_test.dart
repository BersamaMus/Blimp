import 'dart:ui';

import 'package:blimp/widgets/shelf.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final tonal in [false, true]) {
    testWidgets('${tonal ? 'genre' : 'filter'} chips are big enough to tap and labelled', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChipBar(tonal: tonal, labels: const ['Hip-Hop', 'Pop', 'Rock'], selected: 1, onSelected: (_) {}),
        ),
      ));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });
  }

  testWidgets('a custom seek bar is a slider that moves 10 seconds at a time', (tester) async {
    final handle = tester.ensureSemantics();
    Duration? sought;
    await tester.pumpWidget(MaterialApp(
      home: seekSemantics(
        position: const Duration(seconds: 83),
        duration: const Duration(minutes: 3, seconds: 45),
        onSeek: (d) => sought = d,
        child: const SizedBox(width: 300, height: 20),
      ),
    ));
    final node = tester.getSemantics(find.bySemanticsLabel('Seek'));
    expect(node.value, '1:23 of 3:45');
    tester.semantics.performAction(find.semantics.byLabel('Seek'), SemanticsAction.increase);
    expect(sought, const Duration(seconds: 93));
    handle.dispose();
  });
}
