import 'dart:io';
import 'dart:typed_data';

import 'package:cutlab_project_format/cutlab_project_format.dart';
import 'package:file_picker/file_picker.dart';

import 'media_platform.dart';

/// Windows / Linux / macOS implementation: native file dialogs and plain
/// file paths. Duration and dimensions of video/audio are read by the media
/// engine (Phase 3), so imported clips are marked `needsProbe` until then.
class DesktopMediaPlatform implements MediaPlatform {
  /// Images larger than this are not loaded just for a thumbnail.
  static const maxImageThumbnailBytes = 25 * 1024 * 1024;

  @override
  Future<List<PickedMedia>> pickMedia({bool multiple = true}) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Import media',
      type: FileType.custom,
      allowedExtensions: [...videoExtensions, ...audioExtensions, ...imageExtensions],
      allowMultiple: multiple,
      lockParentWindow: true,
    );
    if (result == null) return const [];
    final picked = <PickedMedia>[];
    for (final f in result.files) {
      final path = f.path;
      if (path == null) continue;
      final media = await describeFile(File(path));
      if (media != null) picked.add(media);
    }
    return picked;
  }

  /// Reads what can be known about [file] without a media engine.
  static Future<PickedMedia?> describeFile(File file) async {
    final name = file.uri.pathSegments.isEmpty ? file.path : file.uri.pathSegments.last;
    final kind = kindFromName(name);
    if (kind == null) return null;
    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.notFound) return null;
    return PickedMedia(
      uri: file.path,
      name: name,
      kind: kind,
      sizeBytes: stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
      hasAudio: kind == MediaKind.audio,
    );
  }

  @override
  Future<bool> exists(String uri) => File(uri).exists();

  @override
  Future<Uint8List?> thumbnail(String uri, MediaKind kind, {int maxSize = 256}) async {
    if (kind != MediaKind.image) return null; // video frames need the Phase 3 engine
    final file = File(uri);
    if (!await file.exists() || await file.length() > maxImageThumbnailBytes) return null;
    return file.readAsBytes();
  }

  @override
  Future<PickedDocument?> pickProjectFile() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Import CUTLAB project',
      type: FileType.custom,
      allowedExtensions: const ['cutlab'],
      lockParentWindow: true,
    );
    final path = result?.files.single.path;
    if (path == null) return null;
    final file = File(path);
    return PickedDocument(file.uri.pathSegments.last, await file.readAsString());
  }

  @override
  Future<bool> saveProjectFile(String suggestedName, String text) async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Export CUTLAB project',
      fileName: suggestedName,
      type: FileType.custom,
      allowedExtensions: const ['cutlab'],
      lockParentWindow: true,
    );
    if (path == null) return false;
    final target = path.toLowerCase().endsWith('.cutlab') ? path : '$path.cutlab';
    await File(target).writeAsString(text, flush: true);
    return true;
  }

  @override
  Future<String> openForEngine(String uri) async => uri;

  @override
  Future<void> closeForEngine(String engineUri) async {}
}
