import 'dart:typed_data';

import 'package:cutlab_project_format/cutlab_project_format.dart';

import '../engine/media_engine.dart';

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

  /// Something the native media engine can open for [uri]: the path itself
  /// on PC, or "fd:<n>" (an open file descriptor) for Android content URIs.
  Future<String> openForEngine(String uri);

  /// Releases what [openForEngine] returned.
  Future<void> closeForEngine(String engineUri);

  /// Whether hardware decoding may be used for [uri]. Videos with the same
  /// [key] (see hardwareCheckKey) share the answer. On Android the decoder
  /// is tried once in a separate process, so a faulty decoder cannot close
  /// the app; on PC hardware decoding falls back to software by itself.
  Future<HardwareCheck> checkHardwareDecoding(String uri, String key);

  /// Forgets every hardware decoding check (they run again when needed).
  Future<void> resetHardwareChecks();

  /// Device, memory, video decoders, earlier crashes/exits and the folder
  /// for crash reports, for the diagnostics screen.
  Future<Map<String, Object?>> deviceInfo();

  // ------------------------------------------------------------ export

  /// Where to render an exported video named [fileName]. Android: a file in
  /// the app's own folder (moved to the gallery by [publishExport]). PC: the
  /// user chooses the place; null when cancelled.
  Future<String?> exportTarget(String fileName);

  /// Makes a finished export available to the user (Android: Movies/CUTLAB
  /// in the gallery) and says where it is.
  Future<ExportedFile> publishExport(String path, String fileName, String mime);

  /// Opens the exported video (Android: a video player; PC: its folder).
  Future<bool> openExported(ExportedFile file);

  /// Keeps the app working while it is in the background (Android: a
  /// foreground service with a progress notification and a wake lock).
  Future<void> startBackgroundWork(String text);
  Future<void> updateBackgroundWork(String text, double progress);
  Future<void> stopBackgroundWork();

  /// Temperature and battery state (Android); unknown elsewhere.
  Future<DeviceCondition> deviceCondition();

  /// The encoder list with the hardware encoders test-encoded where that is
  /// safe (Android: in the separate test process, cached per app version).
  /// Null: ask the engine directly (PC).
  Future<List<EncoderInfo>?> testedEncoders({bool force = false});
}

/// A finished export where the user can find it.
class ExportedFile {
  const ExportedFile({required this.uri, required this.location, this.gallery = false});

  /// What [MediaPlatform.openForEngine] and [MediaPlatform.openExported] take.
  final String uri;

  /// Shown to the user ("Movies/CUTLAB/My video.mp4" or a path).
  final String location;

  /// In the phone's gallery.
  final bool gallery;
}

/// Device state that matters for long exports.
class DeviceCondition {
  const DeviceCondition({this.thermal = -1, this.battery = -1, this.charging = false, this.powerSave = false});

  /// Android thermal status: 0 none … 3 severe, 4 critical, 5 emergency; -1 unknown.
  final int thermal;

  /// Battery percentage, -1 unknown.
  final int battery;
  final bool charging;
  final bool powerSave;

  static const unknown = DeviceCondition();

  bool get hot => thermal >= 3;
  bool get cooledDown => thermal >= 0 && thermal <= 1;
  bool get lowBattery => battery >= 0 && battery < 15 && !charging;
}

/// Result of a hardware decoding check.
class HardwareCheck {
  const HardwareCheck({required this.ok, this.detail = ''});
  final bool ok;

  /// Why hardware decoding is not used, or what was tested.
  final String detail;
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
