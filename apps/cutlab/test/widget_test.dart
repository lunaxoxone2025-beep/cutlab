import 'package:cutlab/src/app.dart';
import 'package:cutlab/src/workspace_screen.dart';
import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _openNewProject(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const CutlabApp());
  await tester.enterText(find.byKey(const Key('projectName')), 'Ranked highlights');
  await tester.tap(find.text('9:16 · Shorts / Reels'));
  await tester.tap(find.text('60'));
  await tester.pump();
  await tester.ensureVisible(find.byKey(const Key('createProject')));
  await tester.tap(find.byKey(const Key('createProject')));
  await tester.pumpAndSettle();
}

Finder _mode(String label) => find.descendant(of: find.byKey(const Key('modeSwitch')), matching: find.text(label));

void main() {
  testWidgets('creates a project and shows the desktop workspace', (tester) async {
    await _openNewProject(tester, const Size(1400, 900));

    expect(find.text('Ranked highlights'), findsOneWidget);
    expect(find.text('Video 1'), findsOneWidget);
    expect(find.text('Audio 1'), findsOneWidget);
    expect(find.text('Text 1'), findsOneWidget);
    // Inspector reflects the chosen canvas and frame rate.
    expect(find.text('60 fps'), findsOneWidget);
    expect(find.text('1080 × 1920'), findsWidgets);
    expect(find.text('MEDIA'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mode switch keeps every track', (tester) async {
    await _openNewProject(tester, const Size(1400, 900));

    expect(find.byIcon(Icons.lock_open), findsNothing);
    await tester.tap(_mode('Advanced'));
    await tester.pumpAndSettle();
    expect(find.text('Advanced'), findsWidgets);
    expect(find.byIcon(Icons.lock_open), findsNWidgets(3));
    await tester.tap(_mode('Beginner'));
    await tester.pumpAndSettle();
    expect(find.text('Video 1'), findsOneWidget);
    expect(find.text('Audio 1'), findsOneWidget);
    expect(find.text('Text 1'), findsOneWidget);
  });

  testWidgets('phone-sized screens get the touch layout without side panels', (tester) async {
    await _openNewProject(tester, const Size(400, 860));

    expect(find.text('MEDIA'), findsNothing);
    expect(find.text('PREVIEW'), findsOneWidget);
    expect(find.text('TIMELINE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('timecode uses exact frame math', () {
    expect(formatTimecode(0, Rational.fps30), '00:00:00:00');
    expect(formatTimecode(framesToTicks(30 * 3661 + 12, Rational.fps30), Rational.fps30), '01:01:01:12');
    expect(formatTimecode(framesToTicks(29, Rational.fps29_97), Rational.fps29_97), '00:00:00:29');
  });
}
