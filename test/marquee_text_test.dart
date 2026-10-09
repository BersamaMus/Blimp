import 'package:blimp/widgets/marquee_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _frame(String text, {bool reduceMotion = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        // A Scaffold gives the normal text style, as in the app; without one
        // Flutter uses a large fallback style.
        child: Scaffold(body: Center(child: SizedBox(width: 200, child: MarqueeText(text)))),
      ),
    );

final _ticker = find.descendant(of: find.byType(MarqueeText), matching: find.byType(Transform));

const _long = 'A very long song title that cannot possibly fit in two hundred pixels';

void main() {
  testWidgets('short text is shown once, without scrolling', (tester) async {
    await tester.pumpWidget(_frame('Short'));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Short'), findsOneWidget);
    expect(_ticker, findsNothing);
  });

  testWidgets('long text scrolls after the start delay', (tester) async {
    await tester.pumpWidget(_frame(_long));
    await tester.pump();
    // Two copies make the loop seamless.
    expect(find.text(_long), findsNWidgets(2));

    double offset() => tester.widget<Transform>(_ticker).transform.getTranslation().x;
    await tester.pump(const Duration(milliseconds: 1000));
    expect(offset(), 0, reason: 'waits before scrolling');

    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(offset(), lessThan(0), reason: 'moves left once started');
  });

  testWidgets('long text stays still when animations are turned off', (tester) async {
    await tester.pumpWidget(_frame(_long, reduceMotion: true));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text(_long), findsOneWidget);
  });
}
