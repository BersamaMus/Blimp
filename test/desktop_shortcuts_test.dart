import 'package:blimp/widgets/desktop_shortcuts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> pressed;

  Widget app({Widget page = const Scaffold(body: Text('Home'))}) => MaterialApp(
    builder: (context, child) => DesktopShortcuts(
      onPlayPause: () => pressed.add('playPause'),
      onNext: () => pressed.add('next'),
      onPrevious: () => pressed.add('previous'),
      onSearch: () => pressed.add('search'),
      child: child!,
    ),
    home: page,
  );

  setUp(() => pressed = []);

  testWidgets('Space, Ctrl+arrows and Ctrl+F reach their actions', (tester) async {
    await tester.pumpWidget(app());

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(pressed, ['playPause', 'next', 'previous', 'search']);
  });

  testWidgets('arrows without Ctrl do nothing', (tester) async {
    await tester.pumpWidget(app());

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);

    expect(pressed, isEmpty);
  });

  testWidgets('Space in a text field types a space instead of pausing', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(app(page: Scaffold(body: TextField(controller: controller, autofocus: true))));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'a');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);

    expect(pressed, isEmpty);
  });

  testWidgets('Ctrl+F still searches while typing', (tester) async {
    await tester.pumpWidget(app(page: const Scaffold(body: TextField(autofocus: true))));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(pressed, ['search']);
  });
}
