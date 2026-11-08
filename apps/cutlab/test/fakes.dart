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

  @override
  Future<void> closeForEngine(String engineUri) async {}

  @override
  Future<bool> saveProjectFile(String suggestedName, String text) async {
    savedDocuments.add((suggestedName, text));
    return true;
  }
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
  int probeCalls = 0;

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
  PreviewPlayer openPlayer(String engineUri, {int maxWidth = 1280, int maxHeight = 720, bool hardware = true}) {
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
