import 'dart:async';
import 'dart:typed_data';

import 'package:cutlab/src/editor/editor_controller.dart';
import 'package:cutlab/src/engine/bmp.dart';
import 'package:cutlab/src/engine/media_engine.dart';
import 'package:cutlab/src/media/media_platform.dart';
import 'package:cutlab/src/storage/project_store.dart';
import 'package:cutlab/src/storage/store_backend.dart';
import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

// Exactly what cutlab_media_probe returns for a 60 fps H.264 + AAC file.
const probeJson = '{"container":"mov,mp4,m4a,3gp,3g2,mj2","durationTicks":7056000000,"startTicks":0,"bitRate":26592,'
    '"sizeBytes":33231,"video":{"codec":"h264","width":320,"height":180,"codedWidth":320,"codedHeight":180,"rotation":0,'
    '"frameRate":{"num":60,"den":1},"baseFrameRate":{"num":60,"den":1},"variableFrameRate":false,"frameCount":600,'
    '"pixelFormat":"yuv420p","bitDepth":8,"stillImage":false},"audio":{"codec":"aac","sampleRate":48000,"channels":2,'
    '"channelLayout":"stereo"}}';

void main() {
  group('ProbeInfo', () {
    test('parses engine JSON', () {
      final p = ProbeInfo.fromJson(probeJson);
      expect(p.durationTicks, 10 * ticksPerSecond);
      expect(p.width, 320);
      expect(p.frameRate, Rational.fps60);
      expect(p.hasAudio, isTrue);
      expect(p.hasVideo, isTrue);
      expect(p.sizeBytes, 33231);
      expect(p.summary, 'H264 · 60 fps · AAC 48 kHz');
    });

    test('audio-only, still images and VFR', () {
      final a = ProbeInfo.fromJson('{"container":"mp3","durationTicks":2116800000,"sizeBytes":-1,"video":null,'
          '"audio":{"codec":"mp3","sampleRate":44100,"channels":2,"channelLayout":"stereo"}}');
      expect(a.hasVideo, isFalse);
      expect(a.sizeBytes, isNull);
      final img = ProbeInfo.fromJson('{"container":"png_pipe","durationTicks":0,"video":{"codec":"png","width":64,"height":48,'
          '"frameRate":{"num":25,"den":1},"stillImage":true},"audio":null}');
      expect(img.stillImage, isTrue);
      const m = MediaRef(id: 'i', kind: MediaKind.image, uri: '/a.png', displayName: 'a.png', durationTicks: 0, needsProbe: true);
      final applied = img.applyTo(m);
      expect(applied.kind, MediaKind.image);
      expect(applied.frameRate, isNull);
      expect(applied.needsProbe, isFalse);
      final vfr = ProbeInfo.fromJson('{"container":"matroska,webm","durationTicks":1,"video":{"codec":"h264","width":2,"height":2,'
          '"frameRate":{"num":60,"den":1},"variableFrameRate":true,"bitDepth":10},"audio":null}');
      expect(vfr.summary, 'H264 · 10-bit · 60 fps (VFR)');
    });

    test('applyTo fills what PC imports could not know', () {
      const before = MediaRef(
        id: 'm',
        kind: MediaKind.video,
        uri: 'C:/rec/match.mkv',
        displayName: 'match.mkv',
        durationTicks: 0,
        sizeBytes: 7000000000,
        fingerprint: '7000000000:1',
        needsProbe: true,
      );
      final after = videoProbe().applyTo(before);
      expect(after.durationTicks, 7200 * ticksPerSecond);
      expect(after.width, 2560);
      expect(after.frameRate, Rational.fps60);
      expect(after.hasAudio, isTrue);
      expect(after.needsProbe, isFalse);
      expect(after.sizeBytes, 7000000000, reason: 'the file size from the OS is kept');
      expect(after.fingerprint, before.fingerprint);
    });
  });

  test('BMP wrapper', () {
    final rgba = Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255]); // 3x1: red, green, blue
    final bmp = encodeBmp(RgbaImage(3, 1, rgba));
    final d = ByteData.sublistView(bmp);
    expect(String.fromCharCodes(bmp.sublist(0, 2)), 'BM');
    expect(d.getUint32(2, Endian.little), bmp.length);
    expect(d.getInt32(18, Endian.little), 3);
    expect(d.getInt32(22, Endian.little), -1);
    expect(d.getUint16(28, Endian.little), 24);
    expect(bmp.sublist(54, 63), [0, 0, 255, 0, 255, 0, 255, 0, 0]); // BGR order
    expect(bmp.length, 54 + 12, reason: '9 bytes padded to 12');
  });

  test('PlayerStats parses engine JSON', () {
    final s = PlayerStats.fromJson('{"positionTicks":1,"decoder":"h264 (d3d11va)","hardware":true,"framesDecoded":76,'
        '"framesDropped":2,"audioDevice":true}');
    expect(s.hardware, isTrue);
    expect(s.decoder, 'h264 (d3d11va)');
    expect(s.framesDropped, 2);
  });

  test('unavailable engine fails clearly', () async {
    final e = UnavailableMediaEngine('no engine here');
    expect(e.available, isFalse);
    await expectLater(e.probe('x'), throwsA(isA<MediaEngineException>()));
  });

  group('controller + engine', () {
    late ProjectStore store;
    late FakeMediaPlatform media;
    late FakeMediaEngine engine;

    setUp(() {
      store = ProjectStore(MemoryBackend());
      media = FakeMediaPlatform();
      engine = FakeMediaEngine();
    });

    test('imported media is probed without adding undo steps', () async {
      final p = await store.create(name: 'Probe');
      final c = EditorController(project: p, store: store, media: media, engine: engine, autosaveDelay: const Duration(hours: 1));
      const raw = PickedMedia(uri: 'C:/rec/ranked.mkv', name: 'ranked.mkv', kind: MediaKind.video, sizeBytes: 123);
      engine.probes['C:/rec/ranked.mkv'] = videoProbe();
      media.picks.add([raw]);
      await c.importMedia();
      expect(c.project.media.single.needsProbe, isTrue, reason: 'probing runs in the background');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final m = c.project.media.single;
      expect(m.needsProbe, isFalse);
      expect(m.durationTicks, 7200 * ticksPerSecond);
      expect(m.frameRate, Rational.fps60);
      expect(c.probeInfo(m.id)?.videoCodec, 'h264');
      c.undo();
      expect(c.project.media, isEmpty, reason: 'one undo removes the import; probing added no steps');
      c.dispose();
    });

    test('unreadable media is reported, not fatal', () async {
      final p = await store.create(name: 'Broken');
      final c = EditorController(project: p, store: store, media: media, engine: engine, autosaveDelay: const Duration(hours: 1));
      media.picks.add([const PickedMedia(uri: '/x/broken.mp4', name: 'broken.mp4', kind: MediaKind.video)]);
      await c.importMedia();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final id = c.project.media.single.id;
      expect(c.probeError(id), contains('cannot open'));
      expect(c.project.media.single.needsProbe, isTrue);
      c.dispose();
    });

    test('opening a project probes media that still needs it', () async {
      final p = await store.create(name: 'Old');
      await store.save(p.copyWith(media: [
        const MediaRef(id: 'a', kind: MediaKind.video, uri: '/v/a.mp4', displayName: 'a.mp4', durationTicks: 0, needsProbe: true),
      ]));
      engine.probes['/v/a.mp4'] = videoProbe(seconds: 30);
      final c = EditorController(project: await store.open(p.id), store: store, media: media, engine: engine);
      await c.checkMedia();
      expect(c.project.media.single.durationTicks, 30 * ticksPerSecond);
      expect(c.saveState, SaveState.unsaved, reason: 'measured values get saved');
      await c.close();
      expect((await store.open(p.id)).media.single.needsProbe, isFalse);
    });
  });

  test('PlayerStats carries the hardware fallback, decoding errors and memory', () {
    final s = PlayerStats.fromJson('{"decoder":"hevc","hardware":false,"hardwareFallback":"hevc_mediacodec could not start: x",'
        '"error":"video: out of memory while decoding video","decoderThreads":3,"rssKiB":204800,"peakRssKiB":409600}');
    expect(s.hardwareFallback, contains('hevc_mediacodec'));
    expect(s.error, contains('out of memory'));
    expect(s.decoderThreads, 3);
    expect(s.rssKiB, 204800);
    expect(s.peakRssKiB, 409600);
  });

  test('hardware decoding checks are shared by videos of the same kind', () {
    const m = MediaRef(id: 'a', kind: MediaKind.video, uri: 'x', displayName: 'x', durationTicks: 0);
    expect(
        hardwareCheckKey(
            const ProbeInfo(
                container: 'mp4',
                durationTicks: 0,
                videoCodec: 'hevc',
                width: 3840,
                height: 2160,
                bitDepth: 10,
                frameRate: Rational.fps59_94),
            m),
        'hevc-10bit-2160p60');
    expect(
        hardwareCheckKey(
            const ProbeInfo(container: 'mp4', durationTicks: 0, videoCodec: 'h264', width: 1080, height: 1920, frameRate: Rational.fps30),
            m),
        'h264-8bit-1080p30');
    expect(hardwareCheckKey(null, m), 'unknown-8bit-720p30');
  });

  test('an engine call in progress delays closing the file', () async {
    final media = FakeMediaPlatform();
    final engine = _SlowEngine();
    final store = ProjectStore(MemoryBackend());
    final p = await store.create(name: 'x');
    final c = EditorController(project: p, store: store, media: media, engine: engine);
    final release = c.releaseEngineUri('fd:7');
    await Future<void>.delayed(Duration.zero);
    expect(media.closed, isEmpty, reason: 'a thumbnail is still reading fd:7');
    engine.finish();
    await release;
    expect(media.closed, ['fd:7']);
    c.dispose();
  });
}

class _SlowEngine extends FakeMediaEngine {
  final _done = Completer<void>();
  void finish() => _done.complete();
  @override
  Future<void> idle(String engineUri) => _done.future;
}
