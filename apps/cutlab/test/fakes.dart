import 'dart:typed_data';

import 'package:cutlab/src/engine/media_engine.dart';
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
  Future<String> openForEngine(String uri) async => uri;

  final List<String> closed = [];
  @override
  Future<void> closeForEngine(String engineUri) async => closed.add(engineUri);

  HardwareCheck hardwareCheck = const HardwareCheck(ok: true);
  final List<String> hardwareCheckKeys = [];
  @override
  Future<HardwareCheck> checkHardwareDecoding(String uri, String key) async {
    hardwareCheckKeys.add(key);
    return hardwareCheck;
  }

  @override
  Future<void> resetHardwareChecks() async {}

  @override
  Future<Map<String, Object?>> deviceInfo() async => {'platform': 'test'};

  @override
  Future<bool> saveProjectFile(String suggestedName, String text) async {
    savedDocuments.add((suggestedName, text));
    return true;
  }

  // ------------------------------------------------------------ export

  /// What exportTarget answers (null = the user cancelled the save dialog).
  String? exportPath = '/exports/out.mp4';
  final List<String> exportNames = [];
  final List<String> background = [];
  final List<ExportedFile> opened = [];
  DeviceCondition condition = DeviceCondition.unknown;

  /// testedEncoders(): null = ask the engine.
  List<EncoderInfo>? encoderList;

  @override
  Future<String?> exportTarget(String fileName) async {
    exportNames.add(fileName);
    return exportPath;
  }

  @override
  Future<ExportedFile> publishExport(String path, String fileName, String mime) async =>
      ExportedFile(uri: path, location: 'Movies/CUTLAB/$fileName', gallery: true);

  @override
  Future<bool> openExported(ExportedFile file) async {
    opened.add(file);
    return true;
  }

  @override
  Future<void> startBackgroundWork(String text) async => background.add('start $text');

  @override
  Future<void> updateBackgroundWork(String text, double progress) async => background.add('update $text');

  @override
  Future<void> stopBackgroundWork() async => background.add('stop');

  @override
  Future<DeviceCondition> deviceCondition() async => condition;

  @override
  Future<List<EncoderInfo>?> testedEncoders({bool force = false}) async => encoderList;
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

/// Scripted media engine: probe results per uri and a controllable player.
class FakeMediaEngine extends MediaEngine {
  final Map<String, ProbeInfo> probes = {};
  final List<FakePlayer> players = [];
  final List<FakeTimeline> timelines = [];

  @override
  TimelineRenderer openTimeline({int maxWidth = 1280, int maxHeight = 720, bool nullAudio = false}) {
    final t = FakeTimeline();
    timelines.add(t);
    return t;
  }

  int probeCalls = 0;

  List<EncoderInfo> encoderList = const [
    EncoderInfo(codec: 'h264', name: 'h264_fakehw', hardware: true),
    EncoderInfo(codec: 'h264', name: 'libopenh264', hardware: false),
    EncoderInfo(codec: 'hevc', name: 'libkvazaar', hardware: false),
    EncoderInfo(codec: 'vp9', name: 'libvpx-vp9', hardware: false),
  ];
  final List<FakeExport> exports = [];

  @override
  Future<List<EncoderInfo>> encoders({bool probe = false}) async => encoderList;

  @override
  ExportJob startExport(String plan, String settings) {
    final e = FakeExport(plan, settings);
    exports.add(e);
    return e;
  }

  @override
  EngineInfo get info => const EngineInfo(available: true, ffmpegVersion: 'fake', hardwareDecoders: ['fakehw']);

  @override
  Future<ProbeInfo> probe(String engineUri) async {
    probeCalls++;
    final p = probes[engineUri];
    if (p == null) throw MediaEngineException('cannot open $engineUri');
    return p;
  }

  @override
  Future<RgbaImage> frameAt(String engineUri, int ticks, {bool accurate = true, int maxWidth = 640, int maxHeight = 360}) async =>
      RgbaImage(2, 2, Uint8List(16), ptsTicks: ticks);

  @override
  Future<ThumbnailStrip> thumbnails(String engineUri, int count, {int maxWidth = 160, int maxHeight = 90}) async =>
      ThumbnailStrip(2, 2, [for (var i = 0; i < count; i++) RgbaImage(2, 2, Uint8List(16), ptsTicks: i * ticksPerSecond)]);

  @override
  Future<Peaks> peaks(String engineUri, {int bucketsPerSecond = 50}) async => Peaks(bucketsPerSecond, Float32List(20));

  @override
  Future<PreviewPlayer> openPlayer(String engineUri, {int maxWidth = 1280, int maxHeight = 720, bool hardware = true}) async {
    final p = FakePlayer(engineUri, hardware);
    players.add(p);
    return p;
  }
}

class FakePlayer implements PreviewPlayer {
  FakePlayer(this.uri, this.hardware);
  final String uri;
  final bool hardware;
  bool _playing = false;
  bool disposed = false;
  int position = 0;
  final List<(int, bool)> seeks = [];

  @override
  int get durationTicks => 90 * ticksPerSecond;
  @override
  int get positionTicks => position;
  @override
  bool get playing => _playing;
  @override
  void play() => _playing = true;
  @override
  void pause() => _playing = false;
  @override
  void seek(int ticks, {bool accurate = true}) {
    position = ticks;
    seeks.add((ticks, accurate));
  }

  @override
  RgbaImage? pollFrame() => null;
  @override
  PlayerStats stats() => PlayerStats(decoder: 'h264', hardware: hardware);
  @override
  void dispose() => disposed = true;
}

ProbeInfo videoProbe({int seconds = 7200, Rational fps = Rational.fps60}) => ProbeInfo(
      container: 'mov,mp4,m4a,3gp,3g2,mj2',
      durationTicks: seconds * ticksPerSecond,
      videoCodec: 'h264',
      width: 2560,
      height: 1440,
      frameRate: fps,
      audioCodec: 'aac',
      sampleRate: 48000,
      channels: 2,
    );

/// Records what the playback controller asks of the timeline renderer.
class FakeTimeline implements TimelineRenderer {
  final List<String> plans = [];
  final List<(int, bool)> seeks = [];
  bool _playing = false;
  int position = 0;
  List<double> nextLevels = const [];
  bool disposed = false;

  String get plan => plans.isEmpty ? '' : plans.last;

  @override
  void setPlan(String plan) => plans.add(plan);
  @override
  void play() => _playing = true;
  @override
  void pause() => _playing = false;
  @override
  bool get playing => _playing;
  set playing(bool v) => _playing = v;
  @override
  void seek(int ticks, {bool accurate = true}) {
    seeks.add((ticks, accurate));
    position = ticks;
  }

  @override
  int get positionTicks => position;
  @override
  int get durationTicks => 0;
  @override
  TimelinePicture? pollFrame() => null;
  @override
  List<double> levels() => nextLevels;
  @override
  TimelineStats stats() => const TimelineStats(framesShown: 10, decoder: 'fake');
  @override
  Float32List renderAudio(int startTicks, int frames) => Float32List(frames * 2);
  @override
  void dispose() => disposed = true;
}

/// A scripted export job: tests move it along with [advance] / [finish].
class FakeExport implements ExportJob {
  FakeExport(this.plan, this.settings);

  final String plan;
  final String settings;
  ExportStatus current = const ExportStatus(state: ExportState.rendering, framesTotal: 100, encoder: 'h264_fakehw', hardware: true);
  bool paused = false;
  bool cancelled = false;
  bool disposed = false;

  String setting(String key) =>
      settings.split('\n').firstWhere((l) => l.startsWith('$key '), orElse: () => '$key ').substring(key.length + 1);

  void advance(int frames, {int etaMs = 5000}) => current = ExportStatus(
        state: ExportState.rendering,
        framesDone: frames,
        framesTotal: current.framesTotal,
        fps: 120,
        speed: 2,
        etaMs: etaMs,
        bytes: frames * 1000,
        encoder: current.encoder,
        hardware: current.hardware,
        paused: paused,
      );

  void finish({ExportState state = ExportState.done, String error = '', List<String> warnings = const []}) => current = ExportStatus(
        state: state,
        framesDone: state == ExportState.done ? current.framesTotal : current.framesDone,
        framesTotal: current.framesTotal,
        bytes: 123456,
        encoder: current.encoder,
        hardware: current.hardware,
        error: error,
        warnings: warnings,
      );

  @override
  ExportStatus status() => current;

  @override
  void pause(bool p) => paused = p;

  @override
  void cancel() {
    cancelled = true;
    finish(state: ExportState.cancelled);
  }

  @override
  void dispose() => disposed = true;
}
