import 'dart:typed_data';

import 'package:cutlab_project_format/cutlab_project_format.dart';

/// A file chosen by the user, with whatever metadata the platform could read.
class PickedMedia {
  const PickedMedia({
    required this.uri,
    required this.name,
    required this.kind,
    this.sizeBytes,
    this.modifiedMs,
    this.durationMs,
    this.width,
    this.height,
    this.hasAudio = false,
    this.probed = false,
  });

  final String uri;
  final String name;
  final MediaKind kind;
  final int? sizeBytes;
  final int? modifiedMs;
  final int? durationMs;
  final int? width;
  final int? height;
  final bool hasAudio;

  /// Whether duration/dimensions were actually read from the file.
  final bool probed;

  /// "size:mtime" — detects a moved or replaced file when relinking.
  String? get fingerprint => sizeBytes == null ? null : '$sizeBytes:${modifiedMs ?? 0}';

  MediaRef toMediaRef(String id) => MediaRef(
        id: id,
        kind: kind,
        uri: uri,
        displayName: name,
        // Milliseconds convert to ticks exactly (705,600 ticks per ms).
        durationTicks: durationMs == null ? 0 : durationMs! * (ticksPerSecond ~/ 1000),
        width: width,
        height: height,
        hasAudio: kind == MediaKind.audio || hasAudio,
        fingerprint: fingerprint,
        sizeBytes: sizeBytes,
        // Images have no duration, so only their size needs reading.
        needsProbe: kind == MediaKind.image ? width == null : !probed,
      );
}

/// A text document chosen by the user (used for importing .cutlab files).
class PickedDocument {
  const PickedDocument(this.name, this.text);
  final String name;
  final String text;
}

/// Platform services for choosing and inspecting media.
abstract class MediaPlatform {
  /// Opens the system picker. Returns an empty list when cancelled.
  Future<List<PickedMedia>> pickMedia({bool multiple = true});

  /// Whether the file behind [uri] can still be opened.
  Future<bool> exists(String uri);

  /// A small JPEG/PNG preview, or null when the platform cannot make one yet.
  Future<Uint8List?> thumbnail(String uri, MediaKind kind, {int maxSize = 256});

  /// Lets the user choose a .cutlab file to import.
  Future<PickedDocument?> pickProjectFile();

  /// Lets the user choose where to write [text]; false when cancelled.
  Future<bool> saveProjectFile(String suggestedName, String text);
}

const videoExtensions = {'mp4', 'mov', 'mkv', 'webm', 'm4v', '3gp', 'avi', 'ts', 'mts', 'm2ts', 'flv', 'wmv'};
const audioExtensions = {'mp3', 'wav', 'm4a', 'aac', 'flac', 'ogg', 'oga', 'opus', 'wma'};
const imageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic', 'avif'};

/// Media kind from a file name, or null for unsupported files.
MediaKind? kindFromName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return null;
  final ext = name.substring(dot + 1).toLowerCase();
  if (videoExtensions.contains(ext)) return MediaKind.video;
  if (audioExtensions.contains(ext)) return MediaKind.audio;
  if (imageExtensions.contains(ext)) return MediaKind.image;
  return null;
}

/// File-name-safe version of a project name, for exports.
String safeFileName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  return cleaned.isEmpty ? 'project' : cleaned;
}
