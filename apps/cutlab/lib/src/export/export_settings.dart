import 'dart:math' as math;

import 'package:cutlab_project_format/cutlab_project_format.dart';

/// Video codecs offered for export.
enum ExportCodec {
  h264('H.264', 'Plays everywhere'),
  hevc('H.265 / HEVC', 'Smaller files, same quality'),
  vp9('VP9', 'WebM, good for the web'),
  av1('AV1', 'Smallest files, slow without hardware');

  const ExportCodec(this.label, this.hint);
  final String label;
  final String hint;

  /// File formats that can hold this codec, the usual one first.
  List<ExportContainer> get containers => switch (this) {
        ExportCodec.h264 => const [ExportContainer.mp4, ExportContainer.mkv, ExportContainer.mov],
        ExportCodec.hevc => const [ExportContainer.mp4, ExportContainer.mkv, ExportContainer.mov],
        ExportCodec.vp9 => const [ExportContainer.webm, ExportContainer.mkv],
        ExportCodec.av1 => const [ExportContainer.mp4, ExportContainer.webm, ExportContainer.mkv],
      };
}

enum ExportContainer {
  mp4('MP4', 'video/mp4'),
  mov('MOV', 'video/quicktime'),
  webm('WebM', 'video/webm'),
  mkv('MKV', 'video/x-matroska');

  const ExportContainer(this.label, this.mime);
  final String label;
  final String mime;

  /// Sound codec this format holds.
  String get audioCodec => this == ExportContainer.webm ? 'opus' : 'aac';
}

/// Quality presets. Values are the engine's 1–100 quality scale.
enum ExportQuality {
  best('Best', 90),
  high('High', 75),
  standard('Standard', 60),
  small('Small file', 40);

  const ExportQuality(this.label, this.value);
  final String label;
  final int value;
}

enum ExportSpeed {
  fast('Fast'),
  balanced('Balanced'),
  quality('Best quality');

  const ExportSpeed(this.label);
  final String label;
}

/// Export resolutions: the short side of the picture (the long side follows
/// the project's shape, so vertical projects stay vertical).
const exportResolutions = [480, 720, 1080, 1440, 2160];

String resolutionLabel(int shortSide) => shortSide == 2160 ? '4K' : '${shortSide}p';

const exportFrameRates = [Rational.fps24, Rational.fps30, Rational.fps60, Rational.fps120];

/// Everything that decides the exported file.
class VideoExportSettings {
  const VideoExportSettings({
    this.resolution = 1080,
    this.frameRate = Rational.fps30,
    this.codec = ExportCodec.h264,
    this.container = ExportContainer.mp4,
    this.quality = ExportQuality.high,
    this.bitrateKbps = 0,
    this.speed = ExportSpeed.balanced,
    this.hardware = true,
    this.audioKbps = 192,
    this.keyframeSeconds = 2,
    this.threads = 0,
  });

  /// Short side in pixels (480 … 2160).
  final int resolution;
  final Rational frameRate;
  final ExportCodec codec;
  final ExportContainer container;
  final ExportQuality quality;

  /// > 0: a fixed target bitrate (manual, advanced mode) instead of [quality].
  final int bitrateKbps;
  final ExportSpeed speed;

  /// Hardware encoders may be used (when they work on this device).
  final bool hardware;
  final int audioKbps;
  final double keyframeSeconds;

  /// Encoder threads, 0 = automatic. Fewer threads = cooler, slower.
  final int threads;

  /// Sensible defaults for [p]: its own frame rate when it is a standard one
  /// (60 fps gaming footage stays 60 fps), its resolution capped at 4K.
  factory VideoExportSettings.forProject(Project p) {
    final s = p.settings;
    final short = math.min(s.width, s.height);
    final res = exportResolutions.lastWhere((r) => r <= short, orElse: () => 480);
    final fps = exportFrameRates.firstWhere((r) => r == s.frameRate, orElse: () {
      final f = s.frameRate.num / s.frameRate.den;
      return f > 45 ? Rational.fps60 : Rational.fps30;
    });
    return VideoExportSettings(resolution: res, frameRate: fps);
  }

  VideoExportSettings copyWith({
    int? resolution,
    Rational? frameRate,
    ExportCodec? codec,
    ExportContainer? container,
    ExportQuality? quality,
    int? bitrateKbps,
    ExportSpeed? speed,
    bool? hardware,
    int? audioKbps,
    double? keyframeSeconds,
    int? threads,
  }) {
    final c = codec ?? this.codec;
    var k = container ?? this.container;
    if (!c.containers.contains(k)) k = c.containers.first;
    return VideoExportSettings(
      resolution: resolution ?? this.resolution,
      frameRate: frameRate ?? this.frameRate,
      codec: c,
      container: k,
      quality: quality ?? this.quality,
      bitrateKbps: bitrateKbps ?? this.bitrateKbps,
      speed: speed ?? this.speed,
      hardware: hardware ?? this.hardware,
      audioKbps: audioKbps ?? this.audioKbps,
      keyframeSeconds: keyframeSeconds ?? this.keyframeSeconds,
      threads: threads ?? this.threads,
    );
  }

  /// Output size for a project of [width] × [height]: the short side becomes
  /// [resolution], the long side keeps the shape; both even.
  (int, int) sizeFor(int width, int height) {
    final landscape = width >= height;
    final short = landscape ? height : width;
    final long = landscape ? width : height;
    final outLong = ((long * resolution / short) / 2).round() * 2;
    return landscape ? (outLong, resolution) : (resolution, outLong);
  }

  double get fps => frameRate.num / frameRate.den;

  String get fpsLabel => frameRate.den == 1 ? '${frameRate.num}' : fps.toStringAsFixed(2);

  /// Target video bitrate in bit/s: the manual one, or the one the quality
  /// stands for (the engine's quality_bitrate formula, docs/EXPORT.md).
  int videoBitrate(int width, int height) {
    if (bitrateKbps > 0) return bitrateKbps * 1000;
    final bpp = 0.111 * math.pow(2.0, (quality.value - 75) / 20.0);
    final factor = switch (codec) {
      ExportCodec.hevc || ExportCodec.vp9 => 0.65,
      ExportCodec.av1 => 0.5,
      ExportCodec.h264 => 1.0,
    };
    final bps = bpp * width * height * 30.0 * math.pow(fps / 30.0, 0.8) * factor;
    return math.max(200000, bps.round());
  }

  /// Approximate file size for [durationTicks] of video at [width] × [height].
  int estimatedBytes(int durationTicks, int width, int height) {
    final seconds = durationTicks / ticksPerSecond;
    return ((videoBitrate(width, height) + audioKbps * 1000) * seconds / 8).round();
  }

  /// The settings text the engine reads (cutlab_export_start).
  String engineText({required String path, required int width, required int height}) {
    final b = StringBuffer()
      ..writeln('path $path')
      ..writeln('container ${container.name}')
      ..writeln('video ${codec.name}')
      ..writeln('size ${width}x$height')
      ..writeln('fps ${frameRate.num}/${frameRate.den}')
      ..writeln('quality ${quality.value}')
      ..writeln('speed ${speed.name}')
      ..writeln('hardware ${hardware ? 1 : 0}')
      ..writeln('keyframes ${keyframeSeconds.toStringAsFixed(2)}')
      ..writeln('audio ${container.audioCodec}')
      ..writeln('audio_bitrate $audioKbps')
      ..writeln('threads $threads');
    if (bitrateKbps > 0) b.writeln('bitrate $bitrateKbps');
    return b.toString();
  }

  /// File name for an export of [projectName] (no folder).
  String fileName(String projectName, DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return '$projectName $stamp.${container.name}';
  }
}

/// "1.2 GB", "350 MB".
String formatBytes(int bytes) {
  if (bytes >= 1000 * 1000 * 1000) return '${(bytes / 1e9).toStringAsFixed(2)} GB';
  if (bytes >= 1000 * 1000) return '${(bytes / 1e6).toStringAsFixed(bytes >= 1e8 ? 0 : 1)} MB';
  return '${(bytes / 1000).toStringAsFixed(0)} kB';
}

/// Ticks as a Duration (millisecond precision).
Duration ticksToDuration(int ticks) => Duration(milliseconds: ticks ~/ (ticksPerSecond ~/ 1000));

/// "1:02:03" / "4:05".
String formatDuration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}
