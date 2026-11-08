import 'dart:io';

/// Minimal key → text storage used by the project library and settings.
/// [FileBackend] is the real one; [MemoryBackend] keeps widget tests fast
/// and free of real I/O.
abstract class StoreBackend {
  /// Human-readable location (shown in Settings).
  String get location;

  Future<List<String>> listNames();
  Future<String?> read(String name);

  /// Replaces [name] with [text] so that a crash leaves either the old or
  /// the new content, never a truncated file.
  Future<void> writeAtomic(String name, String text);
  Future<void> delete(String name);
  Future<bool> exists(String name);
}

class FileBackend implements StoreBackend {
  FileBackend(this.directory);

  final Directory directory;

  @override
  String get location => directory.path;

  File _file(String name) => File('${directory.path}${Platform.pathSeparator}$name');

  @override
  Future<List<String>> listNames() async {
    if (!await directory.exists()) return const [];
    final names = <String>[];
    await for (final e in directory.list(followLinks: false)) {
      if (e is File) names.add(e.uri.pathSegments.last);
    }
    names.sort();
    return names;
  }

  @override
  Future<String?> read(String name) async {
    final f = _file(name);
    return await f.exists() ? f.readAsString() : null;
  }

  @override
  Future<void> writeAtomic(String name, String text) async {
    await directory.create(recursive: true);
    final tmp = _file('$name.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(_file(name).path);
  }

  @override
  Future<void> delete(String name) async {
    final f = _file(name);
    if (await f.exists()) await f.delete();
  }

  @override
  Future<bool> exists(String name) => _file(name).exists();
}

class MemoryBackend implements StoreBackend {
  final Map<String, String> files = {};

  @override
  String get location => 'memory';

  @override
  Future<List<String>> listNames() async => files.keys.toList()..sort();

  @override
  Future<String?> read(String name) async => files[name];

  @override
  Future<void> writeAtomic(String name, String text) async {
    files[name] = text;
  }

  @override
  Future<void> delete(String name) async {
    files.remove(name);
  }

  @override
  Future<bool> exists(String name) async => files.containsKey(name);
}
