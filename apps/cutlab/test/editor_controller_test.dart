import 'package:cutlab/src/editor/editor_controller.dart';
import 'package:cutlab/src/storage/project_store.dart';
import 'package:cutlab/src/storage/store_backend.dart';
import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:cutlab_project_format/cutlab_project_format.dart' as pf show Clip;
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late MemoryBackend backend;
  late ProjectStore store;
  late FakeMediaPlatform media;
  late Project project;

  setUp(() async {
    backend = MemoryBackend();
    store = ProjectStore(backend);
    media = FakeMediaPlatform();
    project = await store.create(name: 'Test');
  });

  EditorController make({Duration autosave = const Duration(milliseconds: 20), int limit = 200}) =>
      EditorController(project: project, store: store, media: media, autosaveDelay: autosave, historyLimit: limit);

  test('edits are undoable and redoable', () {
    final c = make();
    c.rename('One');
    c.rename('Two');
    expect(c.project.name, 'Two');
    c.undo();
    expect(c.project.name, 'One');
    c.undo();
    expect(c.project.name, 'Test');
    expect(c.canUndo, isFalse);
    c.redo();
    c.redo();
    expect(c.project.name, 'Two');
    c.undo();
    c.rename('Branch');
    expect(c.canRedo, isFalse, reason: 'a new edit clears the redo stack');
    c.dispose();
  });

  test('history is capped', () {
    final c = make(limit: 3);
    for (var i = 0; i < 10; i++) {
      c.rename('n$i');
    }
    var undos = 0;
    while (c.canUndo) {
      c.undo();
      undos++;
    }
    expect(undos, 3);
    expect(c.project.name, 'n6');
    c.dispose();
  });

  test('unsaved edits reach the recovery file after the delay; save clears it', () async {
    final c = make();
    c.rename('Unsaved');
    expect(c.saveState, SaveState.unsaved);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect((await store.openRecovery(project.id))?.name, 'Unsaved');
    expect((await store.open(project.id)).name, 'Test');

    expect(await c.save(), isTrue);
    expect(c.saveState, SaveState.saved);
    expect(await store.hasRecovery(project.id), isFalse);
    expect((await store.open(project.id)).name, 'Unsaved');
    c.dispose();
  });

  test('close saves pending changes', () async {
    final c = make(autosave: const Duration(hours: 1));
    c.setMode(EditorMode.advanced);
    await c.close();
    await c.close(); // idempotent
    expect((await store.open(project.id)).editorMode, EditorMode.advanced);
  });

  test('import skips files already in the project and is one undo step', () async {
    final c = make();
    media.picks.add([video('a.mp4'), song('b.mp3')]);
    expect(await c.importMedia(), 2);
    media.picks.add([video('a.mp4')]);
    expect(await c.importMedia(), 0);
    expect(c.project.media.length, 2);
    final a = c.project.media.first;
    expect(a.durationTicks, 90 * ticksPerSecond);
    expect(a.needsProbe, isFalse);
    expect(a.fingerprint, '1000000:1700000000000');
    expect(c.project.media.last.kind, MediaKind.audio);
    c.undo();
    expect(c.project.media, isEmpty);
    c.dispose();
  });

  test('missing media is detected and relinking keeps the id', () async {
    final c = make();
    media.picks.add([video('match.mp4', uri: '/old/match.mp4')]);
    await c.importMedia();
    final id = c.project.media.single.id;

    media.existing['/old/match.mp4'] = false;
    await c.checkMedia();
    expect(c.isAvailable(id), isFalse);
    expect(c.missingCount, 1);

    media.picks.add([song('wrong.mp3')]);
    expect(await c.relinkMedia(id), contains('video'));
    expect(c.project.media.single.uri, '/old/match.mp4');

    media.picks.add([video('match.mp4', uri: '/new/match.mp4')]);
    expect(await c.relinkMedia(id), isNull);
    expect(c.project.media.single.id, id);
    expect(c.project.media.single.uri, '/new/match.mp4');
    expect(c.missingCount, 0);
    c.dispose();
  });

  test('media used by a clip cannot be removed', () async {
    final c = make();
    media.picks.add([video('a.mp4')]);
    await c.importMedia();
    final id = c.project.media.single.id;
    c.edit((p) => p.copyWith(tracks: [
          p.tracks[0].copyWith(clips: [pf.Clip(id: 'c1', mediaId: id, startTicks: 0, durationTicks: ticksPerSecond)]),
          ...p.tracks.skip(1),
        ]));
    expect(c.removeMedia(id), isFalse);
    c.undo(); // remove the clip
    expect(c.removeMedia(id), isTrue);
    expect(c.project.media, isEmpty);
    c.dispose();
  });
}
