import 'dart:async';
import 'dart:ui' as ui;

import 'package:cutlab_project_format/cutlab_project_format.dart';
import 'package:flutter/foundation.dart';

import '../editor/editor_controller.dart';
import '../engine/media_engine.dart';

/// Thumbnails and waveforms for clips on the timeline, made by the media
/// engine in the background the first time a clip is visible and kept for
/// the session. Sizes are bounded: at most 180 small thumbnails per file and
/// a waveform of at most ~4000 buckets, whatever the recording length.
class TimelineAssets extends ChangeNotifier {
  TimelineAssets(this.controller);

  final EditorController controller;
  final Map<String, List<(int, ui.Image)>> _thumbs = {};
  final Map<String, Peaks> _peaks = {};
  final Set<String> _loading = {};
  final Set<String> _failed = {};
  final Map<String, Future<String>> _engineUris = {};
  bool _disposed = false;

  MediaEngine get engine => controller.engine;

  /// A path / "fd:N" the engine can read, opened once per media file and
  /// closed when the workspace closes.
  Future<String> engineUri(MediaRef m) => _engineUris.putIfAbsent('${m.id}|${m.uri}', () => controller.media.openForEngine(m.uri));

  /// Thumbnails (pts, image) sorted by pts, or null while loading.
  List<(int, ui.Image)>? thumbnails(MediaRef m) {
    final cached = _thumbs[m.id];
    if (cached != null) return cached;
    if (m.kind != MediaKind.audio && engine.available && !_failed.contains(m.id) && _loading.add('t${m.id}')) {
      unawaited(_loadThumbs(m));
    }
    return null;
  }

  Peaks? peaks(MediaRef m) {
    final cached = _peaks[m.id];
    if (cached != null) return cached;
    if (m.kind != MediaKind.image && m.hasAudio && engine.available && !_failed.contains('p${m.id}') && _loading.add('p${m.id}')) {
      unawaited(_loadPeaks(m));
    }
    return null;
  }

  Future<void> _loadThumbs(MediaRef m) async {
    try {
      final uri = await engineUri(m);
      final secs = m.durationTicks ~/ ticksPerSecond;
      final count = m.kind == MediaKind.image ? 1 : (secs ~/ 10).clamp(6, 180);
      final strip = await engine.thumbnails(uri, count, maxWidth: 96, maxHeight: 54);
      final images = <(int, ui.Image)>[];
      for (final f in strip.frames) {
        final c = Completer<ui.Image>();
        ui.decodeImageFromPixels(f.pixels, f.width, f.height, ui.PixelFormat.rgba8888, c.complete);
        images.add((f.ptsTicks, await c.future));
      }
      if (_disposed) {
        for (final (_, img) in images) {
          img.dispose();
        }
        return;
      }
      _thumbs[m.id] = images;
      notifyListeners();
    } on Object {
      _failed.add(m.id);
    } finally {
      _loading.remove('t${m.id}');
    }
  }

  Future<void> _loadPeaks(MediaRef m) async {
    try {
      final uri = await engineUri(m);
      final secs = (m.durationTicks ~/ ticksPerSecond).clamp(1, 1 << 30);
      final bps = (4000 ~/ secs).clamp(2, 50);
      final peaks = await engine.peaks(uri, bucketsPerSecond: bps);
      if (_disposed) return;
      _peaks[m.id] = peaks;
      notifyListeners();
    } on Object {
      _failed.add('p${m.id}');
    } finally {
      _loading.remove('p${m.id}');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final list in _thumbs.values) {
      for (final (_, img) in list) {
        img.dispose();
      }
    }
    for (final f in _engineUris.values) {
      unawaited(f.then(controller.media.closeForEngine).catchError((Object _) {}));
    }
    super.dispose();
  }
}
