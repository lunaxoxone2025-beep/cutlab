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
      return FfiMediaEngine._(b, EngineInfo(available: true, ffmpegVersion: m.ffmpeg, hardwareDecoders: m.hw));
    } finally {
      calloc.free(out);
    }
  }

  @override
  Future<ProbeInfo> probe(String engineUri) => _probeAsync(engineUri);

  @override
  Future<RgbaImage> frameAt(String engineUri, int ticks, {bool accurate = true, int maxWidth = 640, int maxHeight = 360}) =>
      _frameAsync(engineUri, ticks, accurate, maxWidth, maxHeight);

  @override
  Future<ThumbnailStrip> thumbnails(String engineUri, int count, {int maxWidth = 160, int maxHeight = 90}) =>
      _thumbnailsAsync(engineUri, count, maxWidth, maxHeight);

  @override
  Future<Peaks> peaks(String engineUri, {int bucketsPerSecond = 50}) => _peaksAsync(engineUri, bucketsPerSecond);

  @override
  PreviewPlayer openPlayer(String engineUri, {int maxWidth = 1280, int maxHeight = 720, bool hardware = true}) {
    final out = calloc<Pointer<Void>>();
    final uri = engineUri.toNativeUtf8();
    try {
      final status = _b.playerOpen(uri, maxWidth, maxHeight, hardware ? 0 : EngineBindings.flagSoftwareDecode, out);
      if (status != EngineBindings.statusOk) throw MediaEngineException(_b.lastErrorMessage);
      return _FfiPlayer(_b, out.value, maxWidth, maxHeight);
    } finally {
      calloc.free(uri);
      calloc.free(out);
    }
  }
}

class _InfoJson {
  _InfoJson(this.ffmpeg, this.hw);
  final String? ffmpeg;
  final List<String> hw;

  static _InfoJson parse(String json) {
    final ff = RegExp(r'"ffmpeg":"([^"]*)"').firstMatch(json)?.group(1);
    final hwList = RegExp(r'"hardwareDecoders":\[([^\]]*)\]').firstMatch(json)?.group(1) ?? '';
    final hw = RegExp(r'"([^"]+)"').allMatches(hwList).map((m) => m.group(1)!).toList();
    return _InfoJson(ff, hw);
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
