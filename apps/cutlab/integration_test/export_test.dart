// Video export with the real engine, inside the real app:
//   Android: flutter test integration_test/export_test.dart -d <emulator>
//            (media bundled as test-only assets, see android-tests.yml)
//   Windows: CUTLAB_TEST_MEDIA=<dir> flutter test integration_test/export_test.dart -d windows
// Result lines start with "EXPORT-REPORT".
import 'dart:io';
import 'dart:math' as math;

import 'package:cutlab/src/app.dart';
import 'package:cutlab/src/engine/ffi_media_engine.dart';
import 'package:cutlab/src/engine/media_engine.dart';
import 'package:cutlab/src/media/android_media_platform.dart';
import 'package:cutlab/src/media/desktop_media_platform.dart';
import 'package:cutlab/src/media/media_platform.dart';
import 'package:cutlab/src/playback/timeline_plan.dart';
import 'package:cutlab/src/services.dart';
import 'package:cutlab/src/storage/app_settings.dart';
import 'package:cutlab/src/storage/project_store.dart';
import 'package:cutlab/src/storage/store_backend.dart';
import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:cutlab_project_format/cutlab_project_format.dart' as pf show Clip;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void report(String line) {
  // ignore: avoid_print
  print('EXPORT-REPORT $line');
}

const tps = ticksPerSecond;

/// PC: no save dialog in a test; exports go to a temporary folder.
class _TestDesktopPlatform extends DesktopMediaPlatform {
  _TestDesktopPlatform(this.dir);
  final Directory dir;

  @override
  Future<String?> exportTarget(String fileName) async => '${dir.path}${Platform.pathSeparator}$fileName';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late MediaEngine engine;
  late MediaPlatform media;
  late Directory out;
  final files = <String, String>{}; // name -> path

  setUpAll(() async {
    engine = FfiMediaEngine.load();
    out = await (await getTemporaryDirectory()).createTemp('exports');
    media = Platform.isAndroid ? AndroidMediaPlatform() : _TestDesktopPlatform(out);
    if (Platform.isAndroid) {
      final dir = await getTemporaryDirectory();
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      for (final key in manifest.listAssets()) {
        if (!key.startsWith('integration_test/media/')) continue;
        final name = key.substring('integration_test/media/'.length);
        final data = await rootBundle.load(key);
        final f = File('${dir.path}/$name');
        await f.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
        files[name] = f.path;
      }
    } else {
      final dir = Platform.environment['CUTLAB_TEST_MEDIA'];
      if (dir != null) {
        for (final e in Directory(dir).listSync().whereType<File>()) {
          files[e.uri.pathSegments.last] = e.path;
        }
      }
    }
    report('engine ${engine.available} ${engine.info.ffmpegVersion}; media: ${files.keys.join(', ')}');
  });

  String pick(List<String> names) => names.firstWhere(files.containsKey, orElse: () => fail('none of $names available'));
  String uriOf(String name) => Platform.isAndroid ? Uri.file(files[name]!).toString() : files[name]!;

  double rms(List<double> s) => s.isEmpty ? 0 : math.sqrt(s.fold<double>(0, (a, v) => a + v * v) / s.length);

  testWidgets('encoders on this device (hardware ones tested safely)', (tester) async {
    await tester.runAsync(() async {
      final list = await media.testedEncoders(force: true) ?? await engine.encoders(probe: true);
      for (final e in list) {
        report('encoder ${e.codec} ${e.name} ${e.hardware ? 'hardware' : 'software'} ${e.usable ? 'usable' : 'NOT usable: ${e.note}'}');
      }
      expect(list.where((e) => e.usable && e.codec == 'h264'), isNotEmpty, reason: 'an H.264 encoder works');

      // Every usable video encoder: a 2-second export, read back.
      final src = pick(['h264_1080p30.mp4', 'gray60.mp4']);
      final srcUri = await media.openForEngine(uriOf(src));
      try {
        for (final e in list.where((e) => e.usable && const {'h264', 'hevc', 'vp9', 'av1'}.contains(e.codec))) {
          final p = Project.create(id: 'enc', name: 'enc', now: DateTime.utc(2026));
          final project = p.copyWith(
            media: [MediaRef(id: 'a', kind: MediaKind.video, uri: uriOf(src), displayName: src, durationTicks: 4 * tps, hasAudio: true)],
            tracks: [
              p.tracks[0].copyWith(clips: const [pf.Clip(id: 'c1', mediaId: 'a', startTicks: 0, durationTicks: 2 * tps)]),
              ...p.tracks.skip(1),
            ],
          );
          final container = e.codec == 'vp9' ? 'webm' : 'mp4';
          final path = '${out.path}${Platform.pathSeparator}enc_${e.name}_${e.hardware ? 'hw' : 'sw'}.$container';
          final plan = '${buildTimelinePlan(project, {'a': srcUri}, hardware: false).text}duration ${2 * tps}\n';
          final settings = 'path $path\ncontainer $container\nvideo ${e.codec}\nencoder ${e.name}\nsize 1280x720\nfps 30\nquality 75\n'
              'speed fast\nhardware ${e.hardware ? 1 : 0}\naudio ${container == 'webm' ? 'opus' : 'aac'}\n';
          final sw = Stopwatch()..start();
          final job = engine.startExport(plan, settings);
          var st = job.status();
          while (!st.finished && sw.elapsed < const Duration(minutes: 3)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            st = job.status();
          }
          job.dispose();
          if (st.state != ExportState.done) {
            report('${e.name}: ${st.state.name} ${st.error} ${st.warnings.join('; ')}');
            expect(e.hardware, isTrue, reason: 'software encoders must work: ${e.name} ${st.error}');
            continue;
          }
          final info = await engine.probe(path);
          report('${e.name} (${e.hardware ? 'hardware' : 'software'}): ${sw.elapsedMilliseconds} ms, used ${st.encoder}, '
              '${info.videoCodec} ${info.width}x${info.height} ${info.frameRate?.num}/${info.frameRate?.den} '
              '${(info.durationTicks / tps).toStringAsFixed(3)} s, ${info.audioCodec}, ${info.sizeBytes} bytes '
              '${st.warnings.isEmpty ? '' : st.warnings.join('; ')}');
          expect(info.videoCodec, e.codec);
          expect((info.width, info.height), (1280, 720));
          expect(info.durationTicks / tps, closeTo(2.0, 0.07));
          try {
            final frame = await engine.frameAt(path, tps, maxWidth: 320, maxHeight: 180);
            expect(frame.width, 320);
          } on MediaEngineException catch (err) {
            // AV1 on devices without an AV1 decoder for the engine (the emulator's MediaCodec one fails).
            if (e.codec != 'av1') rethrow;
            report('${e.name}: picture not decodable here ($err); size, codec and length checked above');
          }
          File(path).deleteSync();
        }
      } finally {
        await media.closeForEngine(srcUri);
      }
    });
  });

  testWidgets('export from the editor: settings, progress, the checked file', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    Future<void> wait(int ms) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      while (DateTime.now().isBefore(end)) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump();
      }
    }

    final videoA = pick(['h264_1080p30.mp4', 'gray60.mp4']);
    final videoB = pick(['hevc_1080p60.mp4', 'h264_1080p60.mp4', 'gray60.mp4']);
    final sound = pick(['tone.mp3', 'tone1k.wav']);
    final services = AppServices(
      projects: ProjectStore(MemoryBackend()),
      settingsStore: SettingsStore(MemoryBackend()),
      media: media,
      engine: engine,
      settings: const AppSettings(hardwareDecoding: false),
    );
    final p = Project.create(id: 'ex', name: 'Export test', now: DateTime.utc(2026), settings: const ProjectSettings(width: 1280, height: 720));
    final text = p.tracks.indexWhere((t) => t.kind == TrackKind.text);
    final project = p.copyWith(
      editorMode: EditorMode.advanced,
      media: [
        MediaRef(id: 'a', kind: MediaKind.video, uri: uriOf(videoA), displayName: videoA, durationTicks: 6 * tps, hasAudio: true),
        MediaRef(id: 'b', kind: MediaKind.video, uri: uriOf(videoB), displayName: videoB, durationTicks: 4 * tps, hasAudio: true),
        MediaRef(id: 's', kind: MediaKind.audio, uri: uriOf(sound), displayName: sound, durationTicks: 3 * tps, hasAudio: true),
      ],
      tracks: [
        for (var i = 0; i < p.tracks.length; i++)
          switch (p.tracks[i].kind) {
            TrackKind.video when i == 0 => p.tracks[i].copyWith(clips: const [
                pf.Clip(id: 'c1', mediaId: 'a', startTicks: 0, durationTicks: 2 * tps, sourceInTicks: tps),
                pf.Clip(id: 'c2', mediaId: 'b', startTicks: 2 * tps, durationTicks: 2 * tps),
              ]),
            TrackKind.audio => p.tracks[i].copyWith(clips: const [
                pf.Clip(id: 'c3', mediaId: 's', startTicks: tps ~/ 2, durationTicks: 2 * tps, fadeInTicks: tps ~/ 4, volume: 0.8),
              ]),
            TrackKind.text when i == text => p.tracks[i].copyWith(clips: const [
                pf.Clip(id: 't1', startTicks: tps, durationTicks: tps, data: {'text': 'CLUTCH'}),
              ]),
            _ => p.tracks[i],
          },
      ],
    );
    await tester.runAsync(() => services.projects.save(project));
    await tester.pumpWidget(CutlabApp(services: services));
    await wait(1500);
    await tester.tap(find.text('Export test'));
    await wait(2500);
    await tester.tap(find.byKey(const Key('exportButton')));
    await wait(1000);
    // Wait for the encoder check (Android: in the separate test process).
    final sw0 = Stopwatch()..start();
    while (sw0.elapsedMilliseconds < 60000 && find.textContaining('Checking which encoders').evaluate().isNotEmpty) {
      await wait(250);
    }
    await tester.tap(find.byKey(const Key('exportResolution-720')));
    await tester.tap(find.byKey(const Key('exportFps-30')));
    await wait(200);
    await tester.scrollUntilVisible(find.byKey(const Key('exportSummary')), 300);
    final summary = (find.byKey(const Key('exportSummary')).evaluate().single.widget as Text).data;
    report('settings: $summary');
    expect(summary, contains('1280 × 720 · 30 fps'));
    await tester.scrollUntilVisible(find.byKey(const Key('exportStart')), 300);
    await tester.ensureVisible(find.byKey(const Key('exportStart')));
    await wait(300);
    await tester.tap(find.byKey(const Key('exportStart')));
    final sw = Stopwatch()..start();
    var lastPct = '';
    while (sw.elapsedMilliseconds < 300000 &&
        find.byKey(const Key('exportDone')).evaluate().isEmpty &&
        find.byKey(const Key('exportError')).evaluate().isEmpty) {
      await wait(250);
      final pct = find.byKey(const Key('exportPercent')).evaluate().map((e) => (e.widget as Text).data).join();
      if (pct.isNotEmpty && pct != lastPct) lastPct = pct;
    }
    if (find.byKey(const Key('exportError')).evaluate().isNotEmpty) {
      final err = (find.byKey(const Key('exportError')).evaluate().single.widget as SelectableText).data;
      report('export failed: $err');
      fail('export failed: $err');
    }
    expect(find.byKey(const Key('exportDone')), findsOneWidget, reason: 'finished in time (last progress: $lastPct)');
    final texts = find
        .descendant(of: find.byKey(const Key('exportDone')), matching: find.byType(Text))
        .evaluate()
        .map((e) => (e.widget as Text).data ?? '')
        .where((t) => t.isNotEmpty)
        .toList();
    report('editor export in ${sw.elapsedMilliseconds} ms: ${texts.join(' | ')}');
    expect(find.text('Video exported and checked'), findsOneWidget, reason: texts.join(' | '));
    final location = (find
            .descendant(of: find.byKey(const Key('exportLocation')), matching: find.byType(Text))
            .evaluate()
            .last
            .widget as Text)
        .data!;
    expect(texts.join(' '), contains('1280 × 720 · 30 fps'));

    // Read the file back: picture with the title, sound where the track is.
    await tester.runAsync(() async {
      final uri = Platform.isAndroid && location.startsWith('Movies/') ? null : location;
      if (uri == null) {
        report('saved in the gallery: $location (checked by the app above)');
        return;
      }
      final euri = await media.openForEngine(uri);
      try {
        final title = await engine.frameAt(euri, 1500 * tps ~/ 1000, maxWidth: 640, maxHeight: 360);
        final plain = await engine.frameAt(euri, 500 * tps ~/ 1000, maxWidth: 640, maxHeight: 360);
        double brightBottom(RgbaImage f) {
          var n = 0;
          for (var y = (f.height * 0.8).round(); y < (f.height * 0.95).round(); y++) {
            for (var x = 0; x < f.width; x++) {
              final i = (y * f.width + x) * 4;
              if (f.pixels[i] > 240 && f.pixels[i + 1] > 240 && f.pixels[i + 2] > 240) n++;
            }
          }
          return n / (f.width * f.height);
        }

        report('white pixels in the title area: with title ${brightBottom(title).toStringAsFixed(4)}, without ${brightBottom(plain).toStringAsFixed(4)}');
        expect(brightBottom(title), greaterThan(brightBottom(plain) + 0.0005), reason: 'the title is in the video');
        final r = engine.openTimeline(maxWidth: 64, maxHeight: 64, nullAudio: true);
        try {
          r.setPlan('cutlab-timeline 1\ntrack x audio 0 0 0 1\nclip x 0 ${10 * tps} 0 1 0 0 1 0 1 $euri\n');
          final before = rms(r.renderAudio(200 * tps ~/ 1000, 4800).toList());
          final during = rms(r.renderAudio(1500 * tps ~/ 1000, 4800).toList());
          report('exported sound rms: before the track ${before.toStringAsFixed(4)}, during ${during.toStringAsFixed(4)}');
          expect(during, greaterThan(0.02));
        } finally {
          r.dispose();
        }
      } finally {
        await media.closeForEngine(euri);
      }
    });
    await tester.pageBack();
    await wait(800);
    expect(tester.takeException(), isNull);
  });
}
