import 'package:cutlab/src/app.dart';
import 'package:cutlab/src/format.dart';
import 'package:cutlab/src/media/media_platform.dart';
import 'package:cutlab/src/services.dart';
import 'package:cutlab/src/storage/app_settings.dart';
import 'package:cutlab/src/storage/project_store.dart';
import 'package:cutlab/src/storage/store_backend.dart';
import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const desktop = Size(1400, 900);
const phone = Size(400, 860);

class Harness {
  Harness({this.engine})
      : backend = MemoryBackend(),
        media = FakeMediaPlatform() {
    services = AppServices(
      projects: ProjectStore(backend),
      settingsStore: SettingsStore(MemoryBackend()),
      media: media,
      engine: engine,
    );
  }

  final MemoryBackend backend;
  final FakeMediaPlatform media;
  final FakeMediaEngine? engine;
  late final AppServices services;

  ProjectStore get store => services.projects;

  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CutlabApp(services: services));
    await tester.pumpAndSettle();
  }
}

Finder _mode(String label) => find.descendant(of: find.byKey(const Key('modeSwitch')), matching: find.text(label));

void main() {
  testWidgets('create a project, import media, undo/redo, save and see it in the library', (tester) async {
    final h = Harness();
    await h.pump(tester, desktop);
    expect(find.text('No projects yet'), findsOneWidget);

    await tester.tap(find.byKey(const Key('newProject')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('projectName')), 'Ranked highlights');
    await tester.tap(find.text('9:16 · Shorts / Reels'));
    await tester.pump();
    await tester.tap(find.text('60'));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('createProject')));
    await tester.tap(find.byKey(const Key('createProject')));
    await tester.pumpAndSettle();

    expect(find.text('Ranked highlights'), findsOneWidget);
    expect(find.text('Video 1'), findsOneWidget);
    expect(find.text('1080 × 1920'), findsOneWidget);
    expect(find.text('60 fps'), findsOneWidget);

    h.media.picks.add([video('match01.mp4')]);
    await tester.tap(find.byKey(const Key('importMedia')));
    await tester.pumpAndSettle();
    expect(find.text('match01.mp4'), findsOneWidget);
    expect(find.text('1:30 · 1920×1080 · 977 KB'), findsOneWidget);

    await tester.tap(find.byKey(const Key('undo')));
    await tester.pumpAndSettle();
    expect(find.text('match01.mp4'), findsNothing);
    await tester.tap(find.byKey(const Key('redo')));
    await tester.pumpAndSettle();
    expect(find.text('match01.mp4'), findsOneWidget);

    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Ranked highlights'), findsOneWidget);
    expect(find.textContaining('1 media'), findsOneWidget);
    final saved = await h.store.open((await h.store.list()).single.id);
    expect(saved.media.single.displayName, 'match01.mp4');
  });

  testWidgets('leaving the editor saves unsaved changes', (tester) async {
    final h = Harness();
    final p = await h.store.create(name: 'Auto');
    await h.pump(tester, desktop);
    await tester.tap(find.text('Auto'));
    await tester.pumpAndSettle();

    await tester.tap(_mode('Advanced'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.lock_open), findsNWidgets(3));

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect((await h.store.open(p.id)).editorMode, EditorMode.advanced);
    expect(await h.store.hasRecovery(p.id), isFalse);
  });

  testWidgets('missing media is flagged and can be relinked (phone layout)', (tester) async {
    final h = Harness();
    final p = await h.store.create(name: 'Moved files');
    await h.store.save(p.copyWith(media: [video('old.mp4', uri: '/gone/old.mp4').toMediaRef('m1')]));
    h.media.existing['/gone/old.mp4'] = false;

    await h.pump(tester, phone);
    await tester.tap(find.text('Moved files'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Media (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Missing'), findsOneWidget);
    expect(find.byKey(const Key('missingBanner')), findsOneWidget);

    h.media.picks.add([video('old.mp4', uri: '/found/old.mp4')]);
    await tester.tap(find.byTooltip('Media actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Relink…'));
    await tester.pumpAndSettle();
    expect(find.text('Missing'), findsNothing);
    expect(find.byKey(const Key('missingBanner')), findsNothing);
  });

  testWidgets('unsaved work from a crash can be restored', (tester) async {
    final h = Harness();
    final p = await h.store.create(name: 'Before crash');
    await h.store.autosave(p.copyWith(name: 'After crash'));

    await h.pump(tester, desktop);
    expect(find.text('Unsaved changes can be restored'), findsOneWidget);
    await tester.tap(find.text('Before crash'));
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes found'), findsOneWidget);
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(find.text('After crash'), findsOneWidget);
    expect(find.byTooltip('Save'), findsOneWidget, reason: 'restored work is still unsaved');
  });

  testWidgets('rename, duplicate, export and delete from the library', (tester) async {
    final h = Harness();
    final p = await h.store.create(name: 'Original');
    await h.pump(tester, phone);

    Future<void> menu(String item) async {
      await tester.tap(find.byKey(Key('projectMenu-${p.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item).last);
      await tester.pumpAndSettle();
    }

    await menu('Rename');
    await tester.enterText(find.byKey(const Key('promptField')), 'Renamed');
    await tester.tap(find.byKey(const Key('promptOk')));
    await tester.pumpAndSettle();
    expect(find.text('Renamed'), findsOneWidget);

    await menu('Duplicate');
    expect(find.text('Renamed (copy)'), findsOneWidget);

    await menu('Export .cutlab');
    expect(h.media.savedDocuments.single.$1, 'Renamed.cutlab');
    expect(h.media.savedDocuments.single.$2, contains('"format": "cutlab-project"'));

    await menu('Delete');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Renamed'), findsNothing);
    expect(find.text('Renamed (copy)'), findsOneWidget);
  });

  testWidgets('importing a .cutlab file adds it to the library', (tester) async {
    final h = Harness();
    final other = ProjectStore(MemoryBackend());
    final p = await other.create(name: 'From my PC');
    h.media.projectToImport = PickedDocument('From my PC.cutlab', other.exportText(p));

    await h.pump(tester, phone);
    await tester.tap(find.byKey(const Key('importProject')));
    await tester.pumpAndSettle();
    expect(find.text('From my PC'), findsOneWidget);
  });

  testWidgets('settings change the mode of new projects', (tester) async {
    final h = Harness();
    await h.pump(tester, phone);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const Key('defaultMode')), matching: find.text('Advanced')));
    await tester.tap(find.text('30 s'));
    await tester.pumpAndSettle();
    expect(h.services.settings.value.defaultMode, EditorMode.advanced);
    expect((await h.services.settingsStore.load()).autosaveSeconds, 30);

    final p = await h.store.create(name: 'x', mode: h.services.settings.value.defaultMode);
    expect(p.editorMode, EditorMode.advanced);
  });

  testWidgets('selecting media opens the viewer: play, scrub, frame step', (tester) async {
    final engine = FakeMediaEngine();
    final h = Harness(engine: engine);
    final p = await h.store.create(name: 'Viewer');
    await h.store.save(p.copyWith(media: [video('ranked.mp4', uri: '/v/ranked.mp4').toMediaRef('m1')]));
    engine.probes['/v/ranked.mp4'] = videoProbe(seconds: 90);

    await h.pump(tester, desktop);
    await tester.tap(find.text('Viewer'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Tap a file in Media'), findsOneWidget);
    expect(find.textContaining('H264 · 60 fps'), findsOneWidget, reason: 'probe summary in the media list');

    await tester.tap(find.text('ranked.mp4'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(engine.players, hasLength(1));
    final player = engine.players.single;
    expect(player.hardware, isTrue);
    expect(find.byKey(const Key('scrubber')), findsOneWidget);

    await tester.tap(find.byKey(const Key('playPause')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.playing, isTrue);
    await tester.tap(find.byKey(const Key('playPause')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.playing, isFalse);

    await tester.tap(find.byKey(const Key('stepForward')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.seeks.last, (framesToTicks(1, Rational.fps60), true));

    // Dragging scrubs with fast seeks and finishes with an accurate one.
    await tester.drag(find.byKey(const Key('scrubber')), const Offset(200, 0));
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.seeks.any((s) => !s.$2), isTrue);
    expect(player.seeks.last.$2, isTrue);

    await tester.pump(const Duration(seconds: 2)); // let the viewer go idle
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(player.disposed, isTrue);
  });

  testWidgets('settings: preview quality and hardware decoding reach the player', (tester) async {
    final engine = FakeMediaEngine();
    final h = Harness(engine: engine);
    await h.pump(tester, phone);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.textContaining('FFmpeg fake'));
    expect(find.textContaining('FFmpeg fake'), findsOneWidget);
    await tester.ensureVisible(find.text('540p'));
    await tester.tap(find.text('540p'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('hardwareDecoding')));
    await tester.tap(find.byKey(const Key('hardwareDecoding')));
    await tester.pumpAndSettle();
    expect(h.services.settings.value.previewHeight, 540);
    expect(h.services.settings.value.hardwareDecoding, isFalse);
    expect((await h.services.settingsStore.load()).previewHeight, 540);
  });

  test('formatting helpers', () {
    expect(formatTimecode(framesToTicks(30 * 3661 + 12, Rational.fps30), Rational.fps30), '01:01:01:12');
    expect(formatDuration(5025 * ticksPerSecond), '1:23:45');
    expect(formatDuration(187 * ticksPerSecond), '3:07');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    expect(const AppSettings().autosaveSeconds, 10);
  });
}
