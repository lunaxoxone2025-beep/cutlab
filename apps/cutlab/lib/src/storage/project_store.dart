import 'dart:math';

import 'package:cutlab_project_format/cutlab_project_format.dart';

import 'store_backend.dart';

/// One row of the project library.
class ProjectEntry {
  const ProjectEntry({
    required this.id,
    required this.name,
    this.modifiedAt,
    this.settings,
    this.mediaCount = 0,
    this.durationTicks = 0,
    this.hasRecovery = false,
    this.error,
  });

  final String id;
  final String name;
  final DateTime? modifiedAt;
  final ProjectSettings? settings;
  final int mediaCount;
  final int durationTicks;

  /// An autosave newer than the last explicit save exists (unsaved work).
  final bool hasRecovery;

  /// Set when the file could not be read; the entry can still be deleted.
  final String? error;
}

/// The project library: one `<id>.cutlab` file per project plus optional
/// `<id>.cutlab.bak` (previous save) and `<id>.cutlab.autosave` (unsaved
/// changes, used for crash recovery).
///
/// Files are named by id, so renaming a project never moves files.
class ProjectStore {
  ProjectStore(this.backend, {ProjectCodec codec = const ProjectCodec(), DateTime Function()? clock, Random? random})
      : _codec = codec,
        _clock = clock ?? DateTime.now,
        _random = random ?? Random.secure();

  static const extension = '.cutlab';
  static const backupSuffix = '.bak';
  static const autosaveSuffix = '.autosave';

  final StoreBackend backend;
  final ProjectCodec _codec;
  final DateTime Function() _clock;
  final Random _random;

  String get location => backend.location;

  DateTime _now() => _clock().toUtc();

  String _main(String id) => '$id$extension';
  String _bak(String id) => '$id$extension$backupSuffix';
  String _auto(String id) => '$id$extension$autosaveSuffix';

  /// A new random id (12 base-36 characters).
  String newId() {
    const chars = '0123456789abcdefghijklmnopqrstuvwxyz';
    return List.generate(12, (_) => chars[_random.nextInt(chars.length)]).join();
  }

  /// All projects, most recently modified first.
  Future<List<ProjectEntry>> list() async {
    final names = await backend.listNames();
    final autosaves = names.where((n) => n.endsWith('$extension$autosaveSuffix')).toSet();
    final entries = <ProjectEntry>[];
    for (final name in names) {
      if (!name.endsWith(extension)) continue;
      final id = name.substring(0, name.length - extension.length);
      final hasRecovery = autosaves.contains(_auto(id));
      try {
        final p = _codec.decode(await backend.read(name) ?? '');
        entries.add(ProjectEntry(
          id: id,
          name: p.name,
          modifiedAt: p.modifiedAt,
          settings: p.settings,
          mediaCount: p.media.length,
          durationTicks: p.durationTicks,
          hasRecovery: hasRecovery,
        ));
      } on Object catch (e) {
        entries.add(ProjectEntry(id: id, name: id, hasRecovery: hasRecovery, error: e.toString()));
      }
    }
    entries.sort((a, b) => (b.modifiedAt ?? DateTime(0)).compareTo(a.modifiedAt ?? DateTime(0)));
    return entries;
  }

  Future<Project> create(
      {required String name, ProjectSettings settings = const ProjectSettings(), EditorMode mode = EditorMode.beginner}) async {
    final p = Project.create(id: newId(), name: name, settings: settings, now: _now()).copyWith(editorMode: mode);
    await save(p);
    return p;
  }

  Future<Project> open(String id) async {
    final text = await backend.read(_main(id));
    if (text == null) throw ProjectFormatException('project "$id" does not exist');
    return _codec.decode(text);
  }

  /// The autosaved version of [id], or null if there is none or it is unreadable.
  Future<Project?> openRecovery(String id) async {
    final text = await backend.read(_auto(id));
    if (text == null) return null;
    try {
      return _codec.decode(text);
    } on Object {
      return null;
    }
  }

  Future<bool> hasRecovery(String id) => backend.exists(_auto(id));

  /// Writes [project] as the saved version: the previous save becomes
  /// `.bak`, and the autosave (now redundant) is removed.
  Future<void> save(Project project) async {
    final previous = await backend.read(_main(project.id));
    if (previous != null) await backend.writeAtomic(_bak(project.id), previous);
    await backend.writeAtomic(_main(project.id), _codec.encode(project));
    await backend.delete(_auto(project.id));
  }

  /// Writes unsaved changes to the recovery file without touching the save.
  Future<void> autosave(Project project) => backend.writeAtomic(_auto(project.id), _codec.encode(project));

  Future<void> discardRecovery(String id) => backend.delete(_auto(id));

  Future<Project> rename(String id, String newName) async {
    final p = (await open(id)).copyWith(name: newName, modifiedAt: _now());
    await save(p);
    return p;
  }

  Future<Project> duplicate(String id) async {
    final source = await open(id);
    final now = _now();
    final copy = source.copyWith(id: newId(), name: '${source.name} (copy)', createdAt: now, modifiedAt: now);
    await save(copy);
    return copy;
  }

  Future<void> delete(String id) async {
    await backend.delete(_main(id));
    await backend.delete(_bak(id));
    await backend.delete(_auto(id));
  }

  /// Adds a project from .cutlab text. It gets a new id when one with the
  /// same id is already in the library, so imports never overwrite.
  Future<Project> importText(String text) async {
    var p = _codec.decode(text);
    if (await backend.exists(_main(p.id))) p = p.copyWith(id: newId());
    await save(p);
    return p;
  }

  String exportText(Project project) => _codec.encode(project);
}
