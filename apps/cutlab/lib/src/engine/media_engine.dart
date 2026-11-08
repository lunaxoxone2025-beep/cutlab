import 'dart:convert';
import 'dart:typed_data';

import 'package:cutlab_project_format/cutlab_project_format.dart';

/// What the engine learned about a media file.
class ProbeInfo {
  const ProbeInfo({
    required this.container,
    required this.durationTicks,
    this.sizeBytes,
    this.videoCodec,
    this.width,
    this.height,
    this.rotation = 0,
    this.frameRate,
    this.variableFrameRate = false,
    this.bitDepth = 8,
    this.stillImage = false,
    this.audioCodec,
    this.sampleRate,
    this.channels,
  });

  final String container;
  final int durationTicks;
  final int? sizeBytes;
  final String? videoCodec;
  final int? width;
  final int? height;
  final int rotation;
  final Rational? frameRate;
  final bool variableFrameRate;
  final int bitDepth;
  final bool stillImage;
  final String? audioCodec;
  final int? sampleRate;
  final int? channels;

  bool get hasVideo => videoCodec != null && !stillImage;
  bool get hasAudio => audioCodec != null;

  /// Parses the JSON written by cutlab_media_probe.
  factory ProbeInfo.fromJson(String text) {
    final j = jsonDecode(text) as Map<String, Object?>;
    final v = j['video'] as Map<String, Object?>?;
    final a = j['audio'] as Map<String, Object?>?;
    Rational? rate(Object? r) {
      if (r is! Map<String, Object?>) return null;
      final n = r['num'], d = r['den'];
      return n is int && d is int && n > 0 && d > 0 ? Rational(n, d) : null;
    }

    final size = j['sizeBytes'];
    return ProbeInfo(
      container: j['container'] as String? ?? '',
      durationTicks: (j['durationTicks'] as num?)?.toInt() ?? 0,
      sizeBytes: size is int && size >= 0 ? size : null,
      videoCodec: v?['codec'] as String?,
      width: (v?['width'] as num?)?.toInt(),
      height: (v?['height'] as num?)?.toInt(),
      rotation: (v?['rotation'] as num?)?.toInt() ?? 0,
      frameRate: rate(v?['frameRate']),
      variableFrameRate: v?['variableFrameRate'] == true,
      bitDepth: (v?['bitDepth'] as num?)?.toInt() ?? 8,
      stillImage: v?['stillImage'] == true,
      audioCodec: a?['codec'] as String?,
      sampleRate: (a?['sampleRate'] as num?)?.toInt(),
      channels: (a?['channels'] as num?)?.toInt(),
    );
  }

  /// [m] with everything the probe measured filled in.
  MediaRef applyTo(MediaRef m) => MediaRef(
        id: m.id,
        kind: stillImage ? MediaKind.image : (videoCodec != null ? MediaKind.video : MediaKind.audio),
        uri: m.uri,
        displayName: m.displayName,
        durationTicks: stillImage ? 0 : durationTicks,
        width: width ?? m.width,
        height: height ?? m.height,
        frameRate: stillImage ? null : (frameRate ?? m.frameRate),
        hasAudio: hasAudio,
        fingerprint: m.fingerprint,
        proxyUri: m.proxyUri,
        sizeBytes: m.sizeBytes ?? sizeBytes,
        needsProbe: false,
      );

  /// Short human description, e.g. "H264 · 60 fps · AAC 48 kHz".
  String get summary {
    final parts = <String>[
      if (videoCodec != null) videoCodec!.toUpperCase(),
      if (bitDepth > 8) '$bitDepth-bit',
      if (frameRate != null && !stillImage) '${_fps(frameRate!)} fps${variableFrameRate ? ' (VFR)' : ''}',
      if (audioCodec != null) '${audioCodec!.toUpperCase()}${sampleRate != null ? ' ${sampleRate! ~/ 1000} kHz' : ''}',
    ];
    return parts.join(' · ');
  }

  static String _fps(Rational r) => r.den == 1 ? '${r.num}' : r.toDouble().toStringAsFixed(2);
}

/// Groups videos that a hardware decoder handles alike: codec, bit depth,
/// size class and frame-rate class ("hevc-10bit-2160p60"). The result of a
/// hardware decoding check is shared by every video with the same key.
String hardwareCheckKey(ProbeInfo? info, MediaRef m) {
  final codec = info?.videoCodec ?? 'unknown';
  final bits = info?.bitDepth ?? 8;
  final w = info?.width ?? m.width ?? 0;
  final h = info?.height ?? m.height ?? 0;
  final side = w > h ? w : h;
  final size = side <= 1280
      ? 720
      : side <= 1920
          ? 1080
          : side <= 2560
              ? 1440
              : side <= 3840
                  ? 2160
                  : 4320;
  final fps = (info?.frameRate ?? m.frameRate)?.toDouble() ?? 30;
  final rate = fps >= 100
      ? 120
      : fps >= 48
          ? 60
          : 30;
  return '$codec-${bits}bit-${size}p$rate';
}

/// A decoded RGBA image (rows of width * 4 bytes).
class RgbaImage {
  const RgbaImage(this.width, this.height, this.pixels, {this.ptsTicks = 0});
  final int width;
  final int height;
  final Uint8List pixels;
  final int ptsTicks;
}

class ThumbnailStrip {
  const ThumbnailStrip(this.width, this.height, this.frames);
  final int width;
  final int height;
  final List<RgbaImage> frames;
}

/// Waveform: min/max pairs per bucket.
class Peaks {
  const Peaks(this.bucketsPerSecond, this.pairs);
  final int bucketsPerSecond;
  final Float32List pairs;
  int get length => pairs.length ~/ 2;
}

class EngineInfo {
  const EngineInfo({required this.available, this.ffmpegVersion, this.hardwareDecoders = const [], this.reason, this.cpus = 0});
  final bool available;
  final String? ffmpegVersion;
  final List<String> hardwareDecoders;
  final String? reason;
  final int cpus;
}

class MediaEngineException implements Exception {
  const MediaEngineException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PlayerStats {
  const PlayerStats({
    this.decoder = '',
    this.hardware = false,
    this.framesDecoded = 0,
    this.framesDropped = 0,
    this.audioDevice = false,
    this.hardwareFallback = '',
    this.error = '',
    this.decoderThreads = 0,
    this.rssKiB = 0,
    this.peakRssKiB = 0,
  });
  final String decoder;
  final bool hardware;
  final int framesDecoded;
  final int framesDropped;
  final bool audioDevice;

  /// Why hardware decoding was abandoned for this file ("" = it was not).
  final String hardwareFallback;

  /// A decoding problem that stopped playback ("" = none).
  final String error;
  final int decoderThreads;
  final int rssKiB;
  final int peakRssKiB;

  factory PlayerStats.fromJson(String text) {
    final j = jsonDecode(text) as Map<String, Object?>;
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    return PlayerStats(
      decoder: j['decoder'] as String? ?? '',
      hardware: j['hardware'] == true,
      framesDecoded: n('framesDecoded'),
      framesDropped: n('framesDropped'),
      audioDevice: j['audioDevice'] == true,
      hardwareFallback: j['hardwareFallback'] as String? ?? '',
      error: j['error'] as String? ?? '',
      decoderThreads: n('decoderThreads'),
      rssKiB: n('rssKiB'),
      peakRssKiB: n('peakRssKiB'),
    );
  }
}

/// Playback of one media file. Frames are pulled by the UI once per screen
/// refresh with [pollFrame]; decoding and audio run on native threads.
abstract class PreviewPlayer {
  int get durationTicks;
  int get positionTicks;
  bool get playing;
  void play();
  void pause();
  void seek(int ticks, {bool accurate = true});

  /// The frame due now if it changed since the last call, else null.
  RgbaImage? pollFrame();
  PlayerStats stats();
  void dispose();
}

/// Everything the app needs from the native media engine.
abstract class MediaEngine {
  EngineInfo get info;
  bool get available => info.available;

  Future<ProbeInfo> probe(String engineUri);
  Future<RgbaImage> frameAt(String engineUri, int ticks, {bool accurate = true, int maxWidth = 640, int maxHeight = 360});
  Future<ThumbnailStrip> thumbnails(String engineUri, int count, {int maxWidth = 160, int maxHeight = 90});
  Future<Peaks> peaks(String engineUri, {int bucketsPerSecond = 50});

  /// Opens a player in the background (opening can take a moment for big
  /// files and must never block the UI).
  Future<PreviewPlayer> openPlayer(String engineUri, {int maxWidth = 1280, int maxHeight = 720, bool hardware = true});

  /// Completes when no engine call is still reading [engineUri], so the
  /// file descriptor behind it can be closed safely.
  Future<void> idle(String engineUri) async {}

  /// Installs the native crash handler (reports in [dir]) and FFmpeg logging.
  void initDiagnostics(String dir, String deviceInfo) {}

  /// Adds a line to the engine activity log (shown in crash reports).
  void note(String text) {}

  /// Recent engine activity and memory use, for the diagnostics screen.
  String recentActivity() => '';
}

/// Used when the native library is missing (e.g. widget tests): every
/// operation fails with a clear message and [available] is false.
class UnavailableMediaEngine extends MediaEngine {
  UnavailableMediaEngine([this.reason = 'The media engine is not included in this build.']);
  final String reason;

  @override
  EngineInfo get info => EngineInfo(available: false, reason: reason);

  Never _fail() => throw MediaEngineException(reason);

  @override
  Future<ProbeInfo> probe(String engineUri) async => _fail();
  @override
  Future<RgbaImage> frameAt(String engineUri, int ticks, {bool accurate = true, int maxWidth = 640, int maxHeight = 360}) async => _fail();
  @override
  Future<ThumbnailStrip> thumbnails(String engineUri, int count, {int maxWidth = 160, int maxHeight = 90}) async => _fail();
  @override
  Future<Peaks> peaks(String engineUri, {int bucketsPerSecond = 50}) async => _fail();
  @override
  Future<PreviewPlayer> openPlayer(String engineUri, {int maxWidth = 1280, int maxHeight = 720, bool hardware = true}) async => _fail();
}
