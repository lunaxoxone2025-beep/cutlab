import 'dart:io';

import 'package:cutlab/src/storage/app_settings.dart';
import 'package:cutlab/src/storage/project_store.dart';
import 'package:cutlab/src/storage/store_backend.dart';
import 'package:cutlab_project_format/cutlab_project_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late ProjectStore store;
  var now = DateTime.utc(2026, 11, 8, 10);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cutlab_store_test');
    now = DateTime.utc(2026, 11, 8, 10);
    store = ProjectStore(FileBackend(Directory('${dir.path}/projects')), clock: () => now);
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  File file(String name) => File('${dir.path}/projects/$name');

  test('create writes a .cutlab file that opens to the same project', () async {
    final p = await store.create(name: 'Montage', settings: ProjectSettings.vertical1080p, mode: EditorMode.advanced);
    expect(await file('${p.id}.cutlab').exists(), isTrue);
    final back = await store.open(p.id);
    expect(back.toJson(), p.toJson());
    expect(back.editorMode, EditorMode.advanced);
    expect(back.settings.height, 1920);
  });

  test('save keeps the previous version as .bak and leaves no temp files', () async {
    final p = await store.create(name: 'A');
    await store.save(p.copyWith(name: 'B'));
    expect((await store.open(p.id)).name, 'B');
    final bak = await file('${p.id}.cutlab.bak').readAsString();
    expect(bak, contains('"name": "A"'));
    final names = dir.listSync(recursive: true).map((e) => e.path).where((n) => n.endsWith('.tmp'));
    expect(names, isEmpty);
  });

  test('autosave is a recovery file that a real save clears', () async {
    final p = await store.create(name: 'Work');
    await store.autosave(p.copyWith(name: 'Work (unsaved)'));
    expect(await store.hasRecovery(p.id), isTrue);
    expect((await store.list()).single.hasRecovery, isTrue);
    expect((await store.openRecovery(p.id))!.name, 'Work (unsaved)');
    expect((await store.open(p.id)).name, 'Work', reason: 'the saved file is untouched');

    await store.save(p.copyWith(name: 'Work v2'));
    expect(await store.hasRecovery(p.id), isFalse);
  });

  test('list is newest first and reports damaged files instead of failing', () async {
    final a = await store.create(name: 'Older');
    now = now.add(const Duration(hours: 1));
    final b = await store.create(name: 'Newer');
    await file('broken.cutlab').writeAsString('{ not json');
    final entries = await store.list();
    expect(entries.where((e) => e.error == null).map((e) => e.id), [b.id, a.id]);
    final broken = entries.singleWhere((e) => e.id == 'broken');
    expect(broken.error, isNotNull);
    await store.delete('broken');
    expect((await store.list()).length, 2);
  });

  test('rename, duplicate and delete', () async {
    final p = await store.create(name: 'Clip');
    await store.rename(p.id, 'Renamed');
    expect((await store.open(p.id)).name, 'Renamed');

    final copy = await store.duplicate(p.id);
    expect(copy.id, isNot(p.id));
    expect(copy.name, 'Renamed (copy)');
    expect((await store.list()).length, 2);

    await store.delete(p.id);
    expect(await file('${p.id}.cutlab').exists(), isFalse);
    expect(await file('${p.id}.cutlab.bak').exists(), isFalse);
    expect((await store.list()).single.id, copy.id);
  });

  test('import never overwrites an existing project', () async {
    final p = await store.create(name: 'Original');
    final imported = await store.importText(store.exportText(p.copyWith(name: 'Imported')));
    expect(imported.id, isNot(p.id));
    expect((await store.open(p.id)).name, 'Original');
    expect((await store.open(imported.id)).name, 'Imported');
    await expectLater(store.importText('{"format":"nope"}'), throwsA(isA<ProjectFormatException>()));
  });

  test('settings round trip and tolerate garbage', () async {
    final s = SettingsStore(FileBackend(dir));
    expect((await s.load()).autosaveSeconds, 10);
    await s.save(const AppSettings(defaultMode: EditorMode.advanced, autosaveSeconds: 30));
    final back = await s.load();
    expect(back.defaultMode, EditorMode.advanced);
    expect(back.autosaveSeconds, 30);
    await File('${dir.path}/settings.json').writeAsString('][');
    expect((await s.load()).autosaveSeconds, 10);
  });
}
