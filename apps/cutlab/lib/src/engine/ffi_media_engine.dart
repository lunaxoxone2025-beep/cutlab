import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'engine_bindings.dart';
import 'media_engine.dart';

/// The real engine. Blocking calls (probe, frames, thumbnails, peaks) run in
/// short-lived background isolates so the UI never waits on file I/O.
class FfiMediaEngine extends MediaEngine {
  FfiMediaEngine._(this._b, this.info);

  final EngineBindings _b;
  @override
  final EngineInfo info;

  /// Loads the native library; returns an [UnavailableMediaEngine] if it is
  /// not shipped with this build.
  static MediaEngine load() {
    final b = EngineBindings.tryLoad();
    if (b == null) return UnavailableMediaEngine('The media engine library could not be loaded on this device.');
    final out = calloc<Pointer<Utf8>>();
    try {
      final status = b.engineInfo(out);
      if (status != EngineBindings.statusOk) {
        return UnavailableMediaEngine(status == EngineBindings.statusUnavailable
            ? 'This build was made without the FFmpeg media engine.'
            : 'Media engine error: ${b.lastErrorMessage}');
      }
      final json = out.value.toDartString();
      b.free(out.value.cast());
      final m = _InfoJson.parse(json);
      return FfiMediaEngine._(b, EngineInfo(available: true, ffmpegVersion: m.ffmpeg, hardwareDecoders: m.hw, cpus: m.cpus));
    } finally {
      calloc.free(out);
    }
  }

  // Engine calls in flight per file (see [idle]).
  final Map<String, int> _busy = {};
  final Map<String, List<Completer<void>>> _idleWaiters = {};

  Future<T> _track<T>(String uri, Future<T> Function() op) async {
    _busy[uri] = (_busy[uri] ?? 0) + 1;
    try {
      return await op();
    } finally {
      final left = (_busy[uri] ?? 1) - 1;
      if (left > 0) {
        _busy[uri] = left;
      } else {
        _busy.remove(uri);
        for (final c in _idleWaiters.remove(uri) ?? const <Completer<void>>[]) {
          c.complete();
        }
      }
    }
  }

  @override
  Future<void> idle(String engineUri) {
    if (!_busy.containsKey(engineUri)) return Future.value();
    final c = Completer<void>();
    (_idleWaiters[engineUri] ??= []).add(c);
    return c.future;
  }

  @override
  Future<ProbeInfo> probe(String engineUri) => _track(engineUri, () => _probeAsync(engineUri));

  @override
  Future<RgbaImage> frameAt(String engineUri, int ticks, {bool accurate = true, int maxWidth = 640, int maxHeight = 360}) =>
      _track(engineUri, () => _frameAsync(engineUri, ticks, accurate, maxWidth, maxHeight));

  @override
  Future<ThumbnailStrip> thumbnails(String engineUri, int count, {int maxWidth = 160, int maxHeight = 90}) =>
      _track(engineUri, () => _thumbnailsAsync(engineUri, count, maxWidth, maxHeight));

  @override
  Future<Peaks> peaks(String engineUri, {int bucketsPerSecond = 50}) => _track(engineUri, () => _peaksAsync(engineUri, bucketsPerSecond));

  @override
  Future<PreviewPlayer> openPlayer(String engineUri, {int maxWidth = 1280, int maxHeight = 720, bool hardware = true}) =>
      _track(engineUri, () async {
        final flags = hardware ? 0 : EngineBindings.flagSoftwareDecode;
        final address = await _openPlayerAsync(engineUri, maxWidth, maxHeight, flags);
        return _FfiPlayer(_b, Pointer<Void>.fromAddress(address), maxWidth, maxHeight);
      });

  @override
  TimelineRenderer openTimeline({int maxWidth = 1280, int maxHeight = 720, bool nullAudio = false}) {
    final out = calloc<Pointer<Void>>();
    try {
      final status = _b.tlOpen(maxWidth, maxHeight, nullAudio ? EngineBindings.flagNullAudio : 0, out);
      if (status != EngineBindings.statusOk) throw MediaEngineException(_b.lastErrorMessage);
      return _FfiTimeline(_b, out.value, maxWidth, maxHeight);
    } finally {
      calloc.free(out);
    }
  }

  @override
  Future<List<EncoderInfo>> encoders({bool probe = false}) async => EncoderInfo.listFromJson(jsonDecode(await _encodersAsync(probe)));

  @override
  ExportJob startExport(String plan, String settings) {
    final p = plan.toNativeUtf8();
    final s = settings.toNativeUtf8();
    final out = calloc<Pointer<Void>>();
    try {
      if (_b.exportStart(p, s, out) != EngineBindings.statusOk) throw MediaEngineException(_b.lastErrorMessage);
      return _FfiExport(_b, out.value);
    } finally {
      calloc.free(p);
      calloc.free(s);
      calloc.free(out);
    }
  }

  @override
  void initDiagnostics(String dir, String deviceInfo) {
    final d = dir.toNativeUtf8();
    final i = deviceInfo.toNativeUtf8();
    try {
      _b.diagInit(d, i);
    } finally {
      calloc.free(d);
      calloc.free(i);
    }
  }

  @override
  void note(String text) {
    final t = text.toNativeUtf8();
    try {
      _b.diagNote(t);
    } finally {
      calloc.free(t);
    }
  }

  @override
  String recentActivity() {
    final out = calloc<Pointer<Utf8>>();
    try {
      if (_b.diagRecent(out) != EngineBindings.statusOk) return '';
      final s = out.value.toDartString();
      _b.free(out.value.cast());
      return s;
    } finally {
      calloc.free(out);
    }
  }
}

class _InfoJson {
  _InfoJson(this.ffmpeg, this.hw, this.cpus);
  final String? ffmpeg;
  final List<String> hw;
  final int cpus;

  static _InfoJson parse(String json) {
    final ff = RegExp(r'"ffmpeg":"([^"]*)"').firstMatch(json)?.group(1);
    final hwList = RegExp(r'"hardwareDecoders":\[([^\]]*)\]').firstMatch(json)?.group(1) ?? '';
    final hw = RegExp(r'"([^"]+)"').allMatches(hwList).map((m) => m.group(1)!).toList();
    final cpus = int.tryParse(RegExp(r'"cpus":(\d+)').firstMatch(json)?.group(1) ?? '') ?? 0;
    return _InfoJson(ff, hw, cpus);
  }
}

// ----------------------------------------------- background-isolate helpers
// Top-level so the isolate closures capture only plain values. Each isolate
// loads the bindings itself (native function handles cannot be sent).

Future<ProbeInfo> _probeAsync(String uri) => Isolate.run(() => ProbeInfo.fromJson(_probeSync(uri)));

Future<RgbaImage> _frameAsync(String uri, int ticks, bool accurate, int maxW, int maxH) =>
    Isolate.run(() => _frameSync(uri, ticks, accurate, maxW, maxH));

Future<ThumbnailStrip> _thumbnailsAsync(String uri, int count, int maxW, int maxH) =>
    Isolate.run(() => _thumbnailsSync(uri, count, maxW, maxH));

Future<Peaks> _peaksAsync(String uri, int bps) => Isolate.run(() => _peaksSync(uri, bps));

Future<int> _openPlayerAsync(String uri, int maxW, int maxH, int flags) => Isolate.run(() => _openPlayerSync(uri, maxW, maxH, flags));

Future<String> _encodersAsync(bool probe) => Isolate.run(() {
      final b = _bindings();
      final out = calloc<Pointer<Utf8>>();
      try {
        if (b.exportEncoders(probe ? 1 : 0, out) != EngineBindings.statusOk) throw MediaEngineException(b.lastErrorMessage);
        final s = out.value.toDartString();
        b.free(out.value.cast());
        return s;
      } finally {
        calloc.free(out);
      }
    });

EngineBindings _bindings() {
  final b = EngineBindings.tryLoad();
  if (b == null) throw const MediaEngineException('media engine library not available');
  return b;
}

String _probeSync(String engineUri) {
  final b = _bindings();
  final uri = engineUri.toNativeUtf8();
  final out = calloc<Pointer<Utf8>>();
  try {
    if (b.probe(uri, out) != EngineBindings.statusOk) throw MediaEngineException(b.lastErrorMessage);
    final s = out.value.toDartString();
    b.free(out.value.cast());
    return s;
  } finally {
    calloc.free(uri);
    calloc.free(out);
  }
}

RgbaImage _frameSync(String engineUri, int ticks, bool accurate, int maxW, int maxH) {
  final b = _bindings();
  final uri = engineUri.toNativeUtf8();
  final px = calloc<Pointer<Uint8>>();
  final w = calloc<Int32>();
  final h = calloc<Int32>();
  final pts = calloc<Int64>();
  try {
    if (b.frame(uri, ticks, maxW, maxH, accurate ? 1 : 0, px, w, h, pts) != EngineBindings.statusOk) {
      throw MediaEngineException(b.lastErrorMessage);
    }
    final bytes = Uint8List.fromList(px.value.asTypedList(w.value * h.value * 4));
    b.free(px.value.cast());
    return RgbaImage(w.value, h.value, bytes, ptsTicks: pts.value);
  } finally {
    calloc.free(uri);
    calloc.free(px);
    calloc.free(w);
    calloc.free(h);
    calloc.free(pts);
  }
}

ThumbnailStrip _thumbnailsSync(String engineUri, int count, int maxW, int maxH) {
  final b = _bindings();
  final uri = engineUri.toNativeUtf8();
  final px = calloc<Pointer<Uint8>>();
  final w = calloc<Int32>();
  final h = calloc<Int32>();
  final n = calloc<Int32>();
  final pts = calloc<Int64>(count);
  try {
    if (b.thumbnails(uri, count, maxW, maxH, px, w, h, n, pts) != EngineBindings.statusOk) {
      throw MediaEngineException(b.lastErrorMessage);
    }
    final each = w.value * h.value * 4;
    final all = px.value.asTypedList(each * n.value);
    final frames = [
      for (var i = 0; i < n.value; i++)
        RgbaImage(w.value, h.value, Uint8List.fromList(all.sublist(i * each, (i + 1) * each)), ptsTicks: pts[i]),
    ];
    b.free(px.value.cast());
    return ThumbnailStrip(w.value, h.value, frames);
  } finally {
    calloc.free(uri);
    calloc.free(px);
    calloc.free(w);
    calloc.free(h);
    calloc.free(n);
    calloc.free(pts);
  }
}

/// Opens a native player; returns its address (pointers cannot be sent
/// between isolates, plain integers can).
int _openPlayerSync(String engineUri, int maxW, int maxH, int flags) {
  final b = _bindings();
  final uri = engineUri.toNativeUtf8();
  final out = calloc<Pointer<Void>>();
  try {
    final status = b.playerOpen(uri, maxW, maxH, flags, out);
    if (status != EngineBindings.statusOk) throw MediaEngineException(b.lastErrorMessage);
    return out.value.address;
  } finally {
    calloc.free(uri);
    calloc.free(out);
  }
}

Peaks _peaksSync(String engineUri, int bps) {
  final b = _bindings();
  final uri = engineUri.toNativeUtf8();
  final out = calloc<Pointer<Float>>();
  final count = calloc<Int64>();
  try {
    if (b.peaks(uri, bps, nullptr, nullptr, out, count) != EngineBindings.statusOk) throw MediaEngineException(b.lastErrorMessage);
    final pairs = Float32List.fromList(out.value.asTypedList(count.value * 2));
    b.free(out.value.cast());
    return Peaks(bps, pairs);
  } finally {
    calloc.free(uri);
    calloc.free(out);
    calloc.free(count);
  }
}

// ------------------------------------------------------------------ player

class _FfiPlayer implements PreviewPlayer {
  _FfiPlayer(this._b, this._h, int maxW, int maxH)
      : _capacity = maxW * maxH * 4,
        _buf = calloc<Uint8>(maxW * maxH * 4),
        _serial = calloc<Uint64>(),
        _w = calloc<Int32>(),
        _hh = calloc<Int32>(),
        _pts = calloc<Int64>();

  final EngineBindings _b;
  final Pointer<Void> _h;
  final int _capacity;
  final Pointer<Uint8> _buf;
  final Pointer<Uint64> _serial;
  final Pointer<Int32> _w;
  final Pointer<Int32> _hh;
  final Pointer<Int64> _pts;
  bool _disposed = false;

  @override
  int get durationTicks => _disposed ? 0 : _b.playerDuration(_h);
  @override
  int get positionTicks => _disposed ? 0 : _b.playerPosition(_h);
  @override
  bool get playing => !_disposed && _b.playerPlaying(_h) != 0;
  @override
  void play() {
    if (!_disposed) _b.playerPlay(_h);
  }

  @override
  void pause() {
    if (!_disposed) _b.playerPause(_h);
  }

  @override
  void seek(int ticks, {bool accurate = true}) {
    if (!_disposed) _b.playerSeek(_h, ticks, accurate ? 1 : 0);
  }

  @override
  RgbaImage? pollFrame() {
    if (_disposed) return null;
    if (_b.playerFrame(_h, _serial, _buf, _capacity, _w, _hh, _pts) == 0) return null;
    final bytes = Uint8List.fromList(_buf.asTypedList(_w.value * _hh.value * 4));
    return RgbaImage(_w.value, _hh.value, bytes, ptsTicks: _pts.value);
  }

  @override
  PlayerStats stats() {
    if (_disposed) return const PlayerStats();
    final out = calloc<Pointer<Utf8>>();
    try {
      if (_b.playerStats(_h, out) != EngineBindings.statusOk) return const PlayerStats();
      final s = out.value.toDartString();
      _b.free(out.value.cast());
      return PlayerStats.fromJson(s);
    } finally {
      calloc.free(out);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _b.playerClose(_h);
    calloc.free(_buf);
    calloc.free(_serial);
    calloc.free(_w);
    calloc.free(_hh);
    calloc.free(_pts);
  }
}

// ---------------------------------------------------------------- timeline

class _FfiTimeline implements TimelineRenderer {
  _FfiTimeline(this._b, this._h, int maxW, int maxH)
      : _capacity = maxW * maxH * 4,
        _buf = calloc<Uint8>(maxW * maxH * 4),
        _serial = calloc<Uint64>(),
        _w = calloc<Int32>(),
        _hh = calloc<Int32>(),
        _pts = calloc<Int64>(),
        _levels = calloc<Float>(_maxLevels);

  static const _maxLevels = 64;
  final EngineBindings _b;
  final Pointer<Void> _h;
  final int _capacity;
  final Pointer<Uint8> _buf;
  final Pointer<Uint64> _serial;
  final Pointer<Int32> _w;
  final Pointer<Int32> _hh;
  final Pointer<Int64> _pts;
  final Pointer<Float> _levels;
  bool _disposed = false;

  @override
  void setPlan(String plan) {
    if (_disposed) return;
    final p = plan.toNativeUtf8();
    try {
      if (_b.tlSetPlan(_h, p) != EngineBindings.statusOk) throw MediaEngineException(_b.lastErrorMessage);
    } finally {
      calloc.free(p);
    }
  }

  @override
  void play() {
    if (!_disposed) _b.tlPlay(_h);
  }

  @override
  void pause() {
    if (!_disposed) _b.tlPause(_h);
  }

  @override
  bool get playing => !_disposed && _b.tlPlaying(_h) != 0;

  @override
  void seek(int ticks, {bool accurate = true}) {
    if (!_disposed) _b.tlSeek(_h, ticks, accurate ? 1 : 0);
  }

  @override
  int get positionTicks => _disposed ? 0 : _b.tlPosition(_h);

  @override
  int get durationTicks => _disposed ? 0 : _b.tlDuration(_h);

  @override
  TimelinePicture? pollFrame() {
    if (_disposed) return null;
    if (_b.tlFrame(_h, _serial, _buf, _capacity, _w, _hh, _pts) == 0) return null;
    final w = _w.value, h = _hh.value;
    if (w <= 0 || h <= 0) return TimelinePicture(null, _pts.value);
    return TimelinePicture(RgbaImage(w, h, Uint8List.fromList(_buf.asTypedList(w * h * 4)), ptsTicks: _pts.value), _pts.value);
  }

  @override
  List<double> levels() {
    if (_disposed) return const [];
    final n = _b.tlLevels(_h, _levels, _maxLevels);
    return [for (var i = 0; i < n; i++) _levels[i]];
  }

  @override
  TimelineStats stats() {
    if (_disposed) return const TimelineStats();
    final out = calloc<Pointer<Utf8>>();
    try {
      if (_b.tlStats(_h, out) != EngineBindings.statusOk) return const TimelineStats();
      final s = out.value.toDartString();
      _b.free(out.value.cast());
      return TimelineStats.fromJson(s);
    } finally {
      calloc.free(out);
    }
  }

  @override
  Float32List renderAudio(int startTicks, int frames) {
    final buf = calloc<Float>(frames * 2);
    try {
      if (_disposed || _b.tlRenderAudio(_h, startTicks, frames, buf, nullptr, 0) != EngineBindings.statusOk) {
        throw MediaEngineException(_disposed ? 'closed' : _b.lastErrorMessage);
      }
      return Float32List.fromList(buf.asTypedList(frames * 2));
    } finally {
      calloc.free(buf);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _b.tlClose(_h);
    calloc.free(_buf);
    calloc.free(_serial);
    calloc.free(_w);
    calloc.free(_hh);
    calloc.free(_pts);
    calloc.free(_levels);
  }
}

class _FfiExport implements ExportJob {
  _FfiExport(this._b, this._h);

  final EngineBindings _b;
  final Pointer<Void> _h;
  bool _disposed = false;
  ExportStatus _last = const ExportStatus();

  @override
  ExportStatus status() {
    if (_disposed) return _last;
    final out = calloc<Pointer<Utf8>>();
    try {
      if (_b.exportStatus(_h, out) != EngineBindings.statusOk) return _last;
      final s = out.value.toDartString();
      _b.free(out.value.cast());
      return _last = ExportStatus.fromJson(jsonDecode(s) as Map<String, Object?>);
    } finally {
      calloc.free(out);
    }
  }

  @override
  void pause(bool paused) {
    if (!_disposed) _b.exportPause(_h, paused ? 1 : 0);
  }

  @override
  void cancel() {
    if (!_disposed) _b.exportCancel(_h);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _b.exportClose(_h);
  }
}
