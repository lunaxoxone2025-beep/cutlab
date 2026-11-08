import 'package:cutlab_project_format/cutlab_project_format.dart';
import 'package:flutter/services.dart';

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
