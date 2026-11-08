import 'dart:io';

import 'package:cutlab/src/engine/media_engine.dart';
import 'package:cutlab/src/export/export_controller.dart';
import 'package:cutlab/src/export/export_screen.dart';
import 'package:cutlab/src/export/export_settings.dart';
import 'package:cutlab/src/export/titles.dart';
import 'package:cutlab/src/media/media_platform.dart';
import 'package:cutlab/src/theme.dart';
import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:cutlab_project_format/cutlab_project_format.dart' as pf show Clip;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const tps = ticksPerSecond;

Widget themed(Widget child) => MaterialApp(theme: buildCutlabTheme(), home: child);

Project project({ProjectSettings settings = const ProjectSettings(frameRate: Rational.fps60), EditorMode mode = EditorMode.beginner}) {
  final p = Project.create(id: 'p', name: 'Ranked', now: DateTime.utc(2026), settings: settings);
  const media = [
    MediaRef(id: 'game', kind: MediaKind.video, uri: '/v/game.mp4', displayName: 'game.mp4', durationTicks: 600 * tps, hasAudio: true),
    MediaRef(id: 'song', kind: MediaKind.audio, uri: '/a/song.mp3', displayName: 'song.mp3', durationTicks: 180 * tps, hasAudio: true),
    MediaRef(id: 'gone', kind: MediaKind.video, uri: '/v/gone.mp4', displayName: 'gone.mp4', durationTicks: 60 * tps),
  ];
  return p.copyWith(media: media, editorMode: mode, tracks: [
    p.tracks[0].copyWith(clips: const [
      pf.Clip(id: 'c1', mediaId: 'game', startTicks: 0, durationTicks: 10 * tps, sourceInTicks: 5 * tps),
      pf.Clip(id: 'c2', mediaId: 'gone', startTicks: 10 * tps, durationTicks: 2 * tps),
    ]),
    p.tracks[1].copyWith(clips: const [pf.Clip(id: 'c3', mediaId: 'song', startTicks: 2 * tps, durationTicks: 8 * tps)]),
  ]);
}

ExportController controller(Project p, FakeMediaPlatform media, FakeMediaEngine engine, {bool hwDecode = true}) => ExportController(
      project: p,
      media: media,
      engine: engine,
      engineUri: (m) async => 'fd:${m.id}',
      isAvailable: (id) => id != 'gone',
      hardwareDecoding: () async => hwDecode,
      workDir: () async => Directory.systemTemp,
      clock: () => DateTime(2026, 11, 8, 18, 30, 5),
    );

ProbeInfo exported({int w = 1920, int h = 1080, Rational fps = Rational.fps60, int seconds = 12, String codec = 'h264'}) => ProbeInfo(
      container: 'mov,mp4',
      durationTicks: seconds * tps,
      sizeBytes: 123456,
      videoCodec: codec,
      width: w,
      height: h,
      frameRate: fps,
      audioCodec: 'aac',
      sampleRate: 48000,
      channels: 2,
    );

void main() {
  setUp(() => ExportController.lastSettings = null);

  group('settings', () {
    test('defaults follow the project: 60 fps gaming footage stays 60 fps, 1080p', () {
      final s = VideoExportSettings.forProject(project());
      expect(s.resolution, 1080);
      expect(s.frameRate, Rational.fps60);
      expect(s.codec, ExportCodec.h264);
      expect(s.container, ExportContainer.mp4);
      expect(
          VideoExportSettings.forProject(project(settings: const ProjectSettings(frameRate: Rational.fps29_97))).frameRate, Rational.fps30);
      expect(VideoExportSettings.forProject(project(settings: const ProjectSettings(width: 3840, height: 2160))).resolution, 2160);
    });

    test('sizes keep the project shape (vertical stays vertical)', () {
      const s = VideoExportSettings(resolution: 720);
      expect(s.sizeFor(1920, 1080), (1280, 720));
      expect(s.sizeFor(1080, 1920), (720, 1280));
      expect(const VideoExportSettings(resolution: 2160).sizeFor(1920, 1080), (3840, 2160));
      expect(const VideoExportSettings(resolution: 1080).sizeFor(1080, 1350), (1080, 1350));
      expect(const VideoExportSettings(resolution: 480).sizeFor(1920, 1080), (854, 480));
    });

    test('codec picks a file format that can hold it', () {
      var s = const VideoExportSettings();
      s = s.copyWith(codec: ExportCodec.vp9);
      expect(s.container, ExportContainer.webm);
      expect(s.container.audioCodec, 'opus');
      s = s.copyWith(codec: ExportCodec.av1);
      expect(s.container, ExportContainer.webm, reason: 'AV1 fits in WebM too');
      s = s.copyWith(codec: ExportCodec.h264);
      expect(s.container, ExportContainer.mp4);
      expect(s.container.audioCodec, 'aac');
    });

    test('bitrate and size estimate (the engine formula)', () {
      const s = VideoExportSettings(frameRate: Rational(60, 1));
      // High quality H.264 1080p60 ≈ 12 Mbit/s (engine quality_bitrate).
      expect(s.videoBitrate(1920, 1080), closeTo(12.0e6, 0.2e6));
      expect(s.copyWith(quality: ExportQuality.best).videoBitrate(1920, 1080), greaterThan(s.videoBitrate(1920, 1080)));
      expect(s.copyWith(codec: ExportCodec.hevc).videoBitrate(1920, 1080), lessThan(s.videoBitrate(1920, 1080)));
      expect(s.copyWith(bitrateKbps: 8000).videoBitrate(1920, 1080), 8000000);
      // 60 s: (12 Mbit + 192 kbit) × 60 / 8 ≈ 91 MB.
      expect(s.estimatedBytes(60 * tps, 1920, 1080), closeTo(91e6, 2e6));
      expect(formatBytes(1500000000), '1.50 GB');
      expect(formatBytes(91000000), '91.0 MB');
      expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
    });

    test('engine settings text', () {
      const s = VideoExportSettings(resolution: 720, frameRate: Rational.fps29_97, codec: ExportCodec.hevc, hardware: false, threads: 2);
      final t = s.engineText(path: '/out/a b.mp4', width: 1280, height: 720).split('\n');
      expect(
          t,
          containsAll([
            'path /out/a b.mp4',
            'container mp4',
            'video hevc',
            'size 1280x720',
            'fps 30000/1001',
            'quality 75',
            'hardware 0',
            'audio aac',
            'audio_bitrate 192',
            'threads 2'
          ]));
      expect(t.any((l) => l.startsWith('bitrate')), isFalse);
      expect(s.copyWith(bitrateKbps: 20000).engineText(path: 'x', width: 2, height: 2), contains('bitrate 20000'));
      expect(s.fileName('Ranked', DateTime(2026, 1, 2, 3, 4, 5)), 'Ranked 20260102-030405.mp4');
    });
  });

  group('titles', () {
    test('spans: titles at the same time are joined, hidden tracks left out', () {
      final p = Project.create(id: 'p', name: 'T', now: DateTime.utc(2026));
      final text = p.tracks.firstWhere((t) => t.kind == TrackKind.text);
      final q = p.copyWith(tracks: [
        for (final t in p.tracks)
          if (t.id == text.id)
            t.copyWith(clips: const [
              pf.Clip(id: 'a', startTicks: 0, durationTicks: 4 * tps, data: {'text': 'GG'}),
              pf.Clip(id: 'b', startTicks: 6 * tps, durationTicks: 2 * tps, data: {'text': ' '}),
            ])
          else
            t,
        const Track(id: 't2', kind: TrackKind.text, clips: [
          pf.Clip(id: 'c', startTicks: 2 * tps, durationTicks: 4 * tps, data: {'text': 'Clutch'})
        ]),
        const Track(id: 't3', kind: TrackKind.text, hidden: true, clips: [
          pf.Clip(id: 'd', startTicks: 0, durationTicks: 9 * tps, data: {'text': 'x'})
        ]),
      ]);
      final spans = titleSpans(q);
      expect([for (final s in spans) (s.start ~/ tps, s.end ~/ tps, s.text)], [(0, 2, 'GG'), (2, 4, 'GG\nClutch'), (4, 6, 'Clutch')]);
    });

    testWidgets('titles are drawn into RGBA files placed like the monitor shows them', (tester) async {
      final dir = Directory.systemTemp.createTempSync('cutlab_titles');
      addTearDown(() => dir.deleteSync(recursive: true));
      final lines =
          await tester.runAsync(() => renderTitleOverlays(const [TitleSpan(0, tps, 'GG'), TitleSpan(tps, 2 * tps, 'GG')], 1280, 720, dir));
      expect(lines, hasLength(2));
      final f = lines![0].split(' ');
      expect(f[0], 'overlay');
      expect(int.parse(f[1]), 0);
      expect(int.parse(f[2]), tps);
      final x = int.parse(f[3]), y = int.parse(f[4]), w = int.parse(f[5]), h = int.parse(f[6]);
      expect(x + w / 2, closeTo(640, 2), reason: 'centred');
      expect(y + h / 2, greaterThan(720 * 0.75), reason: 'near the bottom, as in the monitor');
      expect(File(f.sublist(7).join(' ')).lengthSync(), w * h * 4);
      expect(lines[1].split(' ').last, f.last, reason: 'the same title is drawn once');
    });
  });

  group('controller', () {
    testWidgets('starts the engine with the timeline, the titles, the settings and the encoder order', (tester) async {
      final media = FakeMediaPlatform();
      final engine = FakeMediaEngine();
      final c = controller(project(), media, engine);
      addTearDown(c.dispose);
      await c.loadEncoders();
      expect(c.codecAvailable(ExportCodec.h264), isTrue);
      expect(c.codecAvailable(ExportCodec.av1), isFalse, reason: 'no AV1 encoder in the list');
      expect(c.encoder?.name, 'h264_fakehw');
      expect(await c.start(), isTrue);
      final job = engine.exports.single;
      expect(job.plan, startsWith('cutlab-timeline 1'));
      expect(job.plan, contains('clip c1 0 ${10 * tps} ${5 * tps}'));
      expect(job.plan, contains('duration ${12 * tps}'));
      expect(job.plan, contains('hardware 1'));
      expect(job.plan, isNot(contains('clip c2')), reason: 'missing media is left out');
      expect(c.missingMedia, ['gone.mp4']);
      expect(job.setting('path'), '/exports/out.mp4');
      expect(job.setting('size'), '1920x1080');
      expect(job.setting('fps'), '60/1');
      expect(job.setting('encoder'), 'h264_fakehw,libopenh264');
      expect(media.exportNames.single, 'Ranked 20261108-183005.mp4');
      expect(media.background.first, startsWith('start'));
      expect(c.phase, ExportPhase.rendering);

      job.advance(40);
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.status.framesDone, 40);
      c.togglePause();
      expect(job.paused, isTrue);
      c.togglePause();
      expect(job.paused, isFalse);

      engine.probes['/exports/out.mp4'] = exported();
      job.finish(warnings: const ['clip c9: something']);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(c.phase, ExportPhase.done);
      expect(c.result!.location, 'Movies/CUTLAB/Ranked 20261108-183005.mp4');
      expect(c.verified!.width, 1920);
      expect(c.verifyProblems, isEmpty);
      expect(job.disposed, isTrue);
      expect(media.background.last, 'stop');
      expect(ExportController.lastSettings, isNotNull, reason: 'remembered for the next export');
    });

    testWidgets('software only: hardware encoders are not passed; hardware decoding follows the check', (tester) async {
      final media = FakeMediaPlatform();
      final engine = FakeMediaEngine();
      final c = controller(project(), media, engine, hwDecode: false);
      addTearDown(c.dispose);
      await c.loadEncoders();
      c.update(c.settings.copyWith(hardware: false, codec: ExportCodec.vp9));
      expect(c.encoder?.name, 'libvpx-vp9');
      await c.start();
      final job = engine.exports.single;
      expect(job.setting('encoder'), 'libvpx-vp9');
      expect(job.setting('container'), 'webm');
      expect(job.setting('audio'), 'opus');
      expect(job.plan, contains('hardware 0'));
      job.cancel();
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('a hot device pauses the export until it cools down', (tester) async {
      final media = FakeMediaPlatform();
      final engine = FakeMediaEngine();
      var now = DateTime(2026);
      final c = ExportController(
        project: project(),
        media: media,
        engine: engine,
        engineUri: (m) async => m.uri,
        isAvailable: (_) => true,
        hardwareDecoding: () async => false,
        workDir: () async => Directory.systemTemp,
        conditionInterval: const Duration(milliseconds: 500),
        clock: () => now,
      );
      addTearDown(c.dispose);
      await c.loadEncoders();
      await c.start();
      final job = engine.exports.single;
      Future<void> later() async {
        now = now.add(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 300));
      }

      media.condition = const DeviceCondition(thermal: 3, battery: 80);
      await later();
      expect(c.pausedForHeat, isTrue);
      expect(job.paused, isTrue);
      media.condition = const DeviceCondition(thermal: 1, battery: 80);
      await later();
      expect(c.pausedForHeat, isFalse);
      expect(job.paused, isFalse);
      job.cancel();
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.phase, ExportPhase.setup, reason: 'cancelled: back to the settings');
    });

    testWidgets('failure, retry in software, wrong file and cancelled save dialog', (tester) async {
      final media = FakeMediaPlatform();
      final engine = FakeMediaEngine();
      final c = controller(project(), media, engine);
      addTearDown(c.dispose);
      await c.loadEncoders();
      media.exportPath = null;
      expect(await c.start(), isFalse);
      expect(c.phase, ExportPhase.setup);
      expect(engine.exports, isEmpty);

      media.exportPath = '/exports/out.mp4';
      await c.start();
      engine.exports.last.finish(state: ExportState.failed, error: 'h264_fakehw failed');
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.phase, ExportPhase.failed);
      expect(c.error, 'h264_fakehw failed');

      await c.retryInSoftware();
      expect(engine.exports.last.setting('hardware'), '0');
      expect(engine.exports.last.setting('encoder'), 'libopenh264');
      engine.probes['/exports/out.mp4'] = exported(w: 1280, fps: Rational.fps30);
      engine.exports.last.finish();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(c.phase, ExportPhase.done);
      expect(c.verifyProblems, hasLength(2), reason: 'size and frame rate do not match: shown, not hidden');
    });
  });

  testWidgets('export screen: choose settings, watch progress, see the checked result', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final media = FakeMediaPlatform();
    final engine = FakeMediaEngine();
    final c = controller(project(mode: EditorMode.advanced), media, engine);
    addTearDown(c.dispose);
    await tester.pumpWidget(themed(ExportScreen(controller: c)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('exportSummary')), findsOneWidget);
    expect(find.textContaining('1920 × 1080 · 60 fps · H.264'), findsOneWidget);
    expect(find.textContaining('hardware (h264_fakehw)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('exportResolution-720')));
    await tester.tap(find.byKey(const Key('exportQuality-best')));
    await tester.pump();
    expect(find.textContaining('1280 × 720 · 60 fps'), findsOneWidget);
    expect(find.byKey(const Key('exportEstimate')), findsOneWidget);
    final av1 = tester.widget<RadioListTile<ExportCodec>>(find.byKey(const Key('exportCodec-av1')));
    expect(av1.onChanged, isNull, reason: 'no AV1 encoder: not offered');

    await tester.scrollUntilVisible(find.byKey(const Key('exportStart')), 300);
    await tester.tap(find.byKey(const Key('exportStart')));
    await tester.pump();
    await tester.pump();
    final job = engine.exports.single;
    expect(job.setting('quality'), '90');
    job.advance(25, etaMs: 65000);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('25.0 %  ·  frame 25 of 100'), findsOneWidget);
    expect(find.textContaining('120.0 frames/s'), findsOneWidget);
    expect(find.text('1:05'), findsOneWidget, reason: 'time left');
    await tester.tap(find.byKey(const Key('exportPause')));
    await tester.pump();
    expect(job.paused, isTrue);
    expect(find.text('Resume'), findsOneWidget);
    await tester.tap(find.byKey(const Key('exportPause')));
    await tester.pump();

    engine.probes['/exports/out.mp4'] = exported(w: 1280, h: 720);
    job.finish();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('exportDone')), findsOneWidget);
    expect(find.text('Video exported and checked'), findsOneWidget);
    expect(find.textContaining('H264 1280 × 720 · 60 fps'), findsOneWidget);
    await tester.tap(find.byKey(const Key('exportOpen')));
    expect(media.opened, hasLength(1));
  });

  testWidgets('stopping an export asks first and leaves the settings', (tester) async {
    final media = FakeMediaPlatform();
    final engine = FakeMediaEngine();
    final c = controller(project(), media, engine);
    addTearDown(c.dispose);
    await tester.pumpWidget(themed(ExportScreen(controller: c)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('exportStart')), 300);
    await tester.tap(find.byKey(const Key('exportStart')));
    await tester.pump();
    await tester.pump();
    await tester.scrollUntilVisible(find.byKey(const Key('exportCancel')), 300);
    await tester.tap(find.byKey(const Key('exportCancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('exportStopConfirm')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(engine.exports.single.cancelled, isTrue);
    expect(c.phase, ExportPhase.setup);
    expect(find.byKey(const Key('exportResolution-1080')), findsOneWidget, reason: 'back to the settings');
  });
}
