import 'package:cutlab/src/app.dart';
import 'package:cutlab/src/services.dart';
import 'package:cutlab/src/storage/app_settings.dart';
import 'package:cutlab/src/storage/project_store.dart';
import 'package:cutlab/src/storage/store_backend.dart';
import 'package:cutlab/src/timeline/effects_panel.dart';
import 'package:cutlab/src/timeline/timeline_state.dart';
import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:cutlab_project_format/cutlab_project_format.dart' as pf show Clip;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const desktop = Size(1400, 900);
const phone = Size(400, 860);
const tps = ticksPerSecond;

/// A project with two clips back to back on Video 1 (plenty of media on
/// both sides of the cut at 5 s).
Future<(AppServices, FakeMediaEngine, Project)> setUpProject({EditorMode mode = EditorMode.beginner}) async {
  final engine = FakeMediaEngine();
  final services = AppServices(
    projects: ProjectStore(MemoryBackend()),
    settingsStore: SettingsStore(MemoryBackend()),
    media: FakeMediaPlatform(),
    engine: engine,
  );
  engine.probes['/v/match.mp4'] = videoProbe(seconds: 60);
  final p0 = await services.projects.create(name: 'FX', mode: mode);
  final media = video('match.mp4', uri: '/v/match.mp4', durationMs: 60000).toMediaRef('m1');
  final p = p0.copyWith(media: [
    media
  ], tracks: [
    for (final t in p0.tracks)
      if (t.kind == TrackKind.video)
        t.copyWith(clips: const [
          pf.Clip(id: 'ca', mediaId: 'm1', startTicks: 0, durationTicks: 5 * tps, sourceInTicks: 10 * tps),
          pf.Clip(id: 'cb', mediaId: 'm1', startTicks: 5 * tps, durationTicks: 5 * tps, sourceInTicks: 30 * tps),
        ])
      else
        t,
  ]);
  await services.projects.save(p);
  return (services, engine, p);
}

Future<void> openProject(WidgetTester tester, AppServices services, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(CutlabApp(services: services));
  await tester.pumpAndSettle();
  await tapIn(tester, find.text('FX'));
  await tester.pumpAndSettle();
}

/// Taps the clip at [seconds] on the video row.
Future<void> tapClip(WidgetTester tester, double seconds) async {
  final origin = tester.getTopLeft(find.byKey(const Key('timelineCanvas')));
  final y = rulerHeight + trackHeight(TrackKind.text) + 2 + 20;
  await tester.tapAt(origin + Offset(seconds * 40, y));
  await tester.pumpAndSettle();
}

Finder inPanel(Key key) => find.descendant(of: find.byKey(const Key('fxPanel')), matching: find.byKey(key));

Future<void> show(WidgetTester tester, Key key) async {
  await tester.scrollUntilVisible(inPanel(key), 150,
      scrollable: find.descendant(of: find.byKey(const Key('fxPanel')), matching: find.byType(Scrollable)).first);
  await tester.pumpAndSettle();
}

/// Scrolls [f] into view (toolbars and panels scroll on small screens), then taps it.
Future<void> tapIn(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
}

Future<void> dragIn(WidgetTester tester, Finder f, Offset by) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.drag(f, by);
}

Future<void> undo(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

Future<void> redo(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('beginner: looks, quick sliders, a transition — sent to the renderer, undoable, saved', (tester) async {
    final (services, engine, p) = await setUpProject();
    await openProject(tester, services, desktop);
    final tl = engine.timelines.single;

    await tapClip(tester, 7);
    await tapIn(tester, find.byKey(const Key('tlEffects')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fxPanel')), findsOneWidget);
    expect(find.byKey(const Key('fxAdd')), findsNothing, reason: 'the full stack is an advanced tool');

    await tapIn(tester, inPanel(const Key('look-cinematic')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(tl.plan, contains('effect cb filter '));
    expect(tl.plan, contains('effect cb vignette '));
    expect(tl.plan, isNot(contains('effect ca ')), reason: 'only the selected clip');

    // A quick slider adds its effect; the whole drag is one undo step.
    final slider = find.descendant(of: inPanel(const Key('quick-brightness')), matching: find.byType(Slider));
    await dragIn(tester, slider, const Offset(60, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(tl.plan, contains('effect cb brightness amount=0.'));
    await undo(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tl.plan, isNot(contains('brightness')));
    expect(tl.plan, contains('effect cb filter '), reason: 'the look stays');
    await redo(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tl.plan, contains('effect cb brightness'));

    // Fade from black and a dip to black from the clip before.
    await show(tester, const Key('trType-dip_black'));
    await tapIn(tester, inPanel(const Key('trType-dip_black')));
    await tester.pumpAndSettle();
    await show(tester, const Key('trDur-500'));
    await tapIn(tester, inPanel(const Key('trDur-500')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(tl.plan, contains('transition cb dip_black ${tps ~/ 4} ${tps ~/ 4} left'));
    expect(find.byKey(const Key('trSpan')), findsOneWidget);

    // The first clip has no clip before it.
    await tapClip(tester, 2);
    await tapIn(tester, find.byKey(const Key('tlEffects')));
    await tester.pumpAndSettle();
    await show(tester, const Key('trNoCut'));
    expect(inPanel(const Key('trNoCut')), findsOneWidget);

    // Leaving saves: effects and the transition are in the project file.
    await tester.pageBack();
    await tester.pumpAndSettle();
    final saved = await services.projects.open(p.id);
    final cb = saved.find('cb')!.clip;
    expect([for (final e in cb.effects) e.type], ['filter', 'contrast', 'vignette', 'brightness']);
    expect(cb.transitionIn, const Transition(type: 'dip_black', durationTicks: tps ~/ 2));
  });

  testWidgets('advanced: add, disable, reorder and remove effects; precise transition timing', (tester) async {
    final (services, engine, _) = await setUpProject(mode: EditorMode.advanced);
    await openProject(tester, services, desktop);
    final tl = engine.timelines.single;
    await tapClip(tester, 7);
    await tapIn(tester, find.byKey(const Key('tlEffects')));
    await tester.pumpAndSettle();

    Future<void> add(String type) async {
      await tapIn(tester, inPanel(const Key('fxAdd')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(Key('fxAddItem-$type')).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('fxAddItem-$type')).last);
      await tester.pumpAndSettle();
    }

    await add('sepia');
    await add('blur');
    await tester.pump(const Duration(milliseconds: 100));
    expect(tl.plan, contains('effect cb sepia amount=1.000000\neffect cb blur radius=0.006000'));
    final ids = [for (final e in _current(tester).find('cb')!.clip.effects) e.id];
    // Off: no longer rendered.
    await tapIn(tester, inPanel(Key('fxToggle-${ids[0]}')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(tl.plan, isNot(contains('sepia')));
    await tapIn(tester, inPanel(Key('fxToggle-${ids[0]}')));
    // Blur first.
    await tapIn(tester, inPanel(Key('fxUp-${ids[1]}')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(tl.plan, contains('effect cb blur radius=0.006000\neffect cb sepia'));
    // A parameter slider.
    await dragIn(tester, find.descendant(of: inPanel(Key('fxParam-${ids[1]}-radius')), matching: find.byType(Slider)), const Offset(80, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(tl.plan, isNot(contains('blur radius=0.006000')));
    await tapIn(tester, inPanel(Key('fxRemove-${ids[0]}')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(tl.plan, isNot(contains('sepia')));

    // Transition with direction, then timed with the slider.
    await show(tester, const Key('trType-slide'));
    await tapIn(tester, inPanel(const Key('trType-slide')));
    await tester.pumpAndSettle();
    await show(tester, const Key('trDirection'));
    await tapIn(tester, find.descendant(of: inPanel(const Key('trDirection')), matching: find.byIcon(Icons.arrow_upward)));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(tl.plan, contains('transition cb slide ${tps ~/ 2} ${tps ~/ 2} up'));
    await show(tester, const Key('trDuration'));
    await dragIn(tester, find.descendant(of: inPanel(const Key('trDuration')), matching: find.byType(Slider)), const Offset(100, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    final tr = _current(tester).find('cb')!.clip.transitionIn!;
    expect(tr.durationTicks, greaterThan(tps));
    expect(tr.durationTicks % (_current(tester).frameTicks), 0, reason: 'whole frames');
    expect(tl.plan, contains('transition cb slide ${tr.durationTicks ~/ 2} ${tr.durationTicks - tr.durationTicks ~/ 2} up'));
  });

  testWidgets('phone: the effects sheet opens from the toolbar and from a transition on the timeline', (tester) async {
    final (services, engine, _) = await setUpProject();
    await openProject(tester, services, phone);
    await tapClip(tester, 7);
    await tapIn(tester, find.byKey(const Key('tlEffects')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fxPanel')), findsOneWidget);
    await tapIn(tester, inPanel(const Key('look-noir')));
    await tester.pumpAndSettle();
    await show(tester, const Key('trType-dissolve'));
    await tapIn(tester, inPanel(const Key('trType-dissolve')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(engine.timelines.single.plan, contains('transition cb dissolve'));
    // Close the sheet; tapping the transition bar opens it again.
    await tester.tapAt(const Offset(200, 40));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fxPanel')), findsNothing);
    final origin = tester.getTopLeft(find.byKey(const Key('timelineCanvas')));
    final barY = rulerHeight + trackHeight(TrackKind.text) + trackHeight(TrackKind.video) - 10;
    await tester.tapAt(origin + Offset(5 * 40, barY));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fxPanel')), findsOneWidget);
  });

  testWidgets('settings: the fast effects preview lowers only the preview picture', (tester) async {
    final (services, engine, _) = await setUpProject();
    await openProject(tester, services, desktop);
    final tl = engine.timelines.single;
    await tapClip(tester, 7);
    await tapIn(tester, find.byKey(const Key('tlEffects')));
    await tester.pumpAndSettle();
    await tapIn(tester, inPanel(const Key('look-warm')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tl.plan, isNot(contains('preview ')));
    await services.updateSettings(services.settings.value.copyWith(fastEffectsPreview: true));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(tl.plan, contains('preview 360\n'));
    expect(const AppSettings().fastEffectsPreview, isFalse);
  });
}

/// The editor's current project (the effects panel's controller).
Project _current(WidgetTester tester) => tester.widget<EffectsPanel>(find.byType(EffectsPanel)).controller.project;
