import 'dart:convert';

import 'package:cutlab_project_format/cutlab_project_format.dart';
import 'package:flutter/services.dart';

import '../engine/media_engine.dart';

import 'media_platform.dart';

/// Android implementation backed by MainActivity's "cutlab/media" channel
/// (Storage Access Framework + MediaMetadataRetriever). Files are referenced
/// by persistable content:// URIs and never copied.
class AndroidMediaPlatform implements MediaPlatform {
  AndroidMediaPlatform([MethodChannel? channel]) : _channel = channel ?? const MethodChannel('cutlab/media');

  final MethodChannel _channel;

  @override
  Future<List<PickedMedia>> pickMedia({bool multiple = true}) async {
    final raw = await _channel.invokeListMethod<Object?>('pickMedia', {'multiple': multiple}) ?? const [];
    return [
      for (final item in raw)
        if (item is Map<Object?, Object?>) fromChannelMap(item),
    ];
  }

  @override
  Future<bool> exists(String uri) async => await _channel.invokeMethod<bool>('exists', {'uri': uri}) ?? false;

  @override
  Future<Uint8List?> thumbnail(String uri, MediaKind kind, {int maxSize = 256}) {
    if (kind == MediaKind.audio) return Future.value(null);
    return _channel.invokeMethod<Uint8List>('thumbnail', {'uri': uri, 'kind': kind.name, 'maxSize': maxSize});
  }

  @override
  Future<PickedDocument?> pickProjectFile() async {
    final raw = await _channel.invokeMapMethod<String, Object?>('pickDocument');
    if (raw == null) return null;
    return PickedDocument(raw['name'] as String? ?? 'project.cutlab', raw['text'] as String? ?? '');
  }

  @override
  Future<bool> saveProjectFile(String suggestedName, String text) async =>
      await _channel.invokeMethod<bool>('saveDocument', {'name': suggestedName, 'text': text}) ?? false;

  @override
  Future<String> openForEngine(String uri) async {
    // content:// (picked files) and file:// both go through the
    // ContentResolver: the engine reads a descriptor, never a copy.
    if (!uri.startsWith('content://') && !uri.startsWith('file://')) return uri;
    final fd = await _channel.invokeMethod<int>('openFd', {'uri': uri});
    if (fd == null || fd < 0) throw Exception('cannot open $uri');
    return 'fd:$fd';
  }

  @override
  Future<void> closeForEngine(String engineUri) async {
    if (!engineUri.startsWith('fd:')) return;
    await _channel.invokeMethod<void>('closeFd', {'fd': int.parse(engineUri.substring(3))});
  }

  @override
  Future<HardwareCheck> checkHardwareDecoding(String uri, String key) async {
    final r = await _channel.invokeMapMethod<String, Object?>('checkHardware', {'uri': uri, 'key': key});
    return HardwareCheck(ok: r?['ok'] == true, detail: r?['detail'] as String? ?? '');
  }

  @override
  Future<void> resetHardwareChecks() => _channel.invokeMethod<void>('resetHardwareChecks');

  @override
  Future<Map<String, Object?>> deviceInfo() async =>
      await _channel.invokeMapMethod<String, Object?>('deviceInfo') ?? const <String, Object?>{};

  @override
  Future<String?> exportTarget(String fileName) => _channel.invokeMethod<String>('exportTarget', {'name': fileName});

  @override
  Future<ExportedFile> publishExport(String path, String fileName, String mime) async {
    final r = await _channel.invokeMapMethod<String, Object?>('publishExport', {'path': path, 'name': fileName, 'mime': mime}) ?? const {};
    return ExportedFile(uri: r['uri'] as String? ?? path, location: r['location'] as String? ?? path, gallery: r['gallery'] == true);
  }

  @override
  Future<bool> openExported(ExportedFile file) async =>
      await _channel.invokeMethod<bool>('openExported', {'uri': file.uri, 'mime': 'video/*'}) ?? false;

  @override
  Future<void> startBackgroundWork(String text) => _channel.invokeMethod<bool>('startBackgroundWork', {'text': text});

  @override
  Future<void> updateBackgroundWork(String text, double progress) =>
      _channel.invokeMethod<void>('updateBackgroundWork', {'text': text, 'progress': (progress.clamp(0.0, 1.0) * 1000).round()});

  @override
  Future<void> stopBackgroundWork() => _channel.invokeMethod<void>('stopBackgroundWork');

  @override
  Future<DeviceCondition> deviceCondition() async {
    final r = await _channel.invokeMapMethod<String, Object?>('deviceCondition') ?? const {};
    return DeviceCondition(
      thermal: (r['thermal'] as num?)?.toInt() ?? -1,
      battery: (r['battery'] as num?)?.toInt() ?? -1,
      charging: r['charging'] == true,
      powerSave: r['powerSave'] == true,
    );
  }

  @override
  Future<List<EncoderInfo>?> testedEncoders({bool force = false}) async {
    final json = await _channel.invokeMethod<String>('checkEncoders', {'force': force});
    if (json == null) return null;
    final decoded = jsonDecode(json);
    if (decoded is Map && decoded['encoders'] != null) return EncoderInfo.listFromJson(decoded['encoders']);
    // The test failed or crashed: hardware encoders are not used.
    return const [];
  }

  /// Converts one map from the channel into a [PickedMedia]. Public for tests.
  static PickedMedia fromChannelMap(Map<Object?, Object?> m) {
    int? asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
    final name = m['name'] as String? ?? 'media';
    final kind = switch (m['kind']) {
      'video' => MediaKind.video,
      'audio' => MediaKind.audio,
      'image' => MediaKind.image,
      _ => kindFromName(name) ?? MediaKind.video,
    };
    return PickedMedia(
      uri: m['uri'] as String? ?? '',
      name: name,
      kind: kind,
      sizeBytes: asInt(m['sizeBytes']),
      modifiedMs: asInt(m['modifiedMs']),
      durationMs: asInt(m['durationMs']),
      width: asInt(m['width']),
      height: asInt(m['height']),
      hasAudio: m['hasAudio'] == true,
      probed: m['probed'] == true,
    );
  }
}
