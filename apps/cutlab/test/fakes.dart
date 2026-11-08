import 'dart:typed_data';

import 'package:cutlab/src/media/media_platform.dart';
import 'package:cutlab_project_format/cutlab_project_format.dart';

/// Scripted media platform for tests.
class FakeMediaPlatform implements MediaPlatform {
  /// Each pickMedia() call takes the next entry (empty list = cancelled).
  final List<List<PickedMedia>> picks = [];

  /// uri -> exists. Unknown uris exist.
  final Map<String, bool> existing = {};

  PickedDocument? projectToImport;
  final List<(String, String)> savedDocuments = [];

  @override
  Future<List<PickedMedia>> pickMedia({bool multiple = true}) async => picks.isEmpty ? const [] : picks.removeAt(0);

  @override
  Future<bool> exists(String uri) async => existing[uri] ?? true;

  @override
  Future<Uint8List?> thumbnail(String uri, MediaKind kind, {int maxSize = 256}) async => null;

  @override
  Future<PickedDocument?> pickProjectFile() async => projectToImport;

  @override
  Future<bool> saveProjectFile(String suggestedName, String text) async {
    savedDocuments.add((suggestedName, text));
    return true;
  }
}

PickedMedia video(String name, {String? uri, int durationMs = 90000}) => PickedMedia(
      uri: uri ?? '/videos/$name',
      name: name,
      kind: MediaKind.video,
      sizeBytes: 1000000,
      modifiedMs: 1700000000000,
      durationMs: durationMs,
      width: 1920,
      height: 1080,
      hasAudio: true,
      probed: true,
    );

PickedMedia song(String name) => PickedMedia(uri: '/music/$name', name: name, kind: MediaKind.audio, sizeBytes: 5000);
