// Timeline playback with the real engine, inside the real app:
//   Android: flutter test integration_test/timeline_playback_test.dart -d <emulator>
//            (media bundled as test-only assets, see android-tests.yml)
//   Windows: CUTLAB_TEST_MEDIA=<dir> flutter test integration_test/timeline_playback_test.dart -d windows
// Result lines start with "PLAYBACK-REPORT".
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
  print('PLAYBACK-REPORT $line');
}

const tps = ticksPerSecond;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late MediaEngine engine;
  late MediaPlatform media;
  final files = <String, String>{}; // name -> path

  setUpAll(() async {
    engine = FfiMediaEngine.load();
    media = Platform.isAndroid ? AndroidMediaPlatform() : DesktopMediaPlatform();
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

  /// What the engine opens: a descriptor on Android (as the app does), a path elsewhere.
  Future<String> open(String name) async =>
      Platform.isAndroid ? await media.openForEngine(Uri.file(files[name]!).toString()) : files[name]!;

  Project project(Map<String, String> uris, String videoA, String videoB, String sound) {
    final p = Project.create(id: 'it', name: 'Playback test', now: DateTime.utc(2026));
    return p.copyWith(media: [
      MediaRef(id: 'a', kind: MediaKind.video, uri: uris['a']!, displayName: videoA, durationTicks: 6 * tps, hasAudio: true),
      MediaRef(id: 'b', kind: MediaKind.video, uri: uris['b']!, displayName: videoB, durationTicks: 4 * tps, hasAudio: true),
      MediaRef(id: 's', kind: MediaKind.audio, uri: uris['s']!, displayName: sound, durationTicks: 3 * tps, hasAudio: true),
    ], tracks: [
      p.tracks[0].copyWith(clips: const [
        pf.Clip(id: 'c1', mediaId: 'a', startTicks: 0, durationTicks: 2 * tps, sourceInTicks: tps),
        pf.Clip(id: 'c2', mediaId: 'b', startTicks: 2 * tps, durationTicks: 2 * tps),
      ]),
      p.tracks[1].copyWith(clips: const [pf.Clip(id: 'c3', mediaId: 's', startTicks: tps ~/ 2, durationTicks: 2 * tps, fadeInTicks: tps ~/ 4)]),
    ]);
  }

  double rms(List<double> s) => s.isEmpty ? 0 : math.sqrt(s.fold<double>(0, (a, v) => a + v * v) / s.length);

  testWidgets('renderer: plays two clips with a sound track, mixer and seeks', (tester) async {
    await tester.runAsync(() async {
      final videoA = pick(['h264_1080p30.mp4', 'gray60.mp4']);
      final videoB = pick(['hevc_1080p60.mp4', 'h264_1080p60.mp4', 'gray120.mkv', 'gray60.mp4']);
      final sound = pick(['tone.mp3', 'tone1k.wav']);
      final uris = {'a': await open(videoA), 'b': await open(videoB), 's': await open(sound)};
      final p = project(uris, videoA, videoB, sound);
      final r = engine.openTimeline(maxWidth: 1280, maxHeight: 1280);
      try {
        var plan = buildTimelinePlan(p, uris, hardware: false);
        r.setPlan(plan.text);
        expect(r.durationTicks, 4 * tps);

        // The mix, offline: sound track from 0.5 s, faded in.
        final mid = r.renderAudio(tps + tps ~/ 2, 4800);
        final before = r.renderAudio(0, 4800);
        report('mix rms: before the sound ${rms(before.toList()).toStringAsFixed(3)}, during ${rms(mid.toList()).toStringAsFixed(3)}');
        expect(rms(mid.toList()), greaterThan(0.02));

        // Mute the sound track and the video track: silence.
        plan = buildTimelinePlan(p.updateTrack('a1', muted: true).updateTrack('v1', muted: true), uris, hardware: false);
        r.setPlan(plan.text);
        expect(rms(r.renderAudio(tps + tps ~/ 2, 4800).toList()), lessThan(1e-6));
        r.setPlan(buildTimelinePlan(p, uris, hardware: false).text);

        // Real-time playback of the whole timeline.
        r.seek(0);
        r.play();
        var pictures = 0, black = 0;
        var maxLevel = 0.0;
        final sw = Stopwatch()..start();
        int? lastPts;
        var backwards = 0;
        while (sw.elapsedMilliseconds < 5500 && (r.playing || sw.elapsedMilliseconds < 300)) {
          await Future<void>.delayed(const Duration(milliseconds: 16));
          final pic = r.pollFrame();
          if (pic != null) {
            pictures++;
            if (pic.image == null) black++;
            if (lastPts != null && pic.ptsTicks < lastPts) backwards++;
            lastPts = pic.ptsTicks;
          }
          final lv = r.levels();
          if (lv.isNotEmpty) maxLevel = math.max(maxLevel, lv.last);
        }
        final st = r.stats();
        report('played ${sw.elapsedMilliseconds} ms: $pictures pictures ($black black), master peak ${maxLevel.toStringAsFixed(2)}, '
            'dropped ${st.framesDropped}, late avg ${st.videoLateAvgMs.toStringAsFixed(1)} ms, underruns ${st.audioUnderruns}, '
            'transitions ${st.clipTransitions} (prepared ${st.preparedTransitions}), audio ${st.audioBackend}, decoder ${st.decoder}, '
            'rss ${st.rssKiB ~/ 1024} MB');
        expect(r.playing, isFalse, reason: 'stopped at the end');
        expect(r.positionTicks, 4 * tps);
        expect(pictures, greaterThan(20));
        expect(backwards, 0);
        expect(st.clipTransitions, greaterThanOrEqualTo(1));

        // Start/stop cycles and seeks.
        for (var i = 0; i < 30; i++) {
          r.seek((i * 37 % 40) * tps ~/ 10, accurate: i.isEven);
          r.play();
          await Future<void>.delayed(Duration(milliseconds: 10 + i % 25));
          r.pollFrame();
          r.pause();
        }
        report('30 start/stop cycles ok');
      } finally {
        r.dispose();
        for (final u in uris.values) {
          await media.closeForEngine(u);
        }
      }
    });
  });

  testWidgets('editor: play the timeline from the monitor, cursor moves, mixer meters', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    Future<void> wait(int ms) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      while (DateTime.now().isBefore(end)) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
    }

    final videoA = pick(['h264_1080p30.mp4', 'gray60.mp4']);
    final videoB = pick(['h264_1080p60.mp4', 'gray60.mp4']);
    final sound = pick(['tone.mp3', 'tone1k.wav']);
    String uri(String name) => Platform.isAndroid ? Uri.file(files[name]!).toString() : files[name]!;
    final services = AppServices(
      projects: ProjectStore(MemoryBackend()),
      settingsStore: SettingsStore(MemoryBackend()),
      media: media,
      engine: engine,
      settings: const AppSettings(hardwareDecoding: false),
    );
    final base = project({'a': uri(videoA), 'b': uri(videoB), 's': uri(sound)}, videoA, videoB, sound);
    await tester.runAsync(() => services.projects.save(base.copyWith(editorMode: EditorMode.advanced)));
    await tester.pumpWidget(CutlabApp(services: services));
    await wait(1500);
    await tester.tap(find.text('Playback test'));
    await wait(3000);
    expect(find.byKey(const Key('monitorPicture')), findsOneWidget, reason: 'the first frame is shown');
    await tester.tap(find.text('Mixer'));
    await wait(300);
    expect(find.byKey(const Key('meter-a1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tlPlay')));
    await wait(1500);
    expect(find.textContaining('00:00:00:00 /'), findsNothing, reason: 'the cursor moves while playing');
    await wait(3500);
    expect(find.textContaining('00:00:04:00 /'), findsWidgets, reason: 'played to the end; the cursor followed');
    await tester.tap(find.byKey(const Key('syncInfo')));
    await wait(300);
    expect(find.byKey(const Key('syncDiagnostics')), findsOneWidget);
    await tester.tap(find.text('Close'));
    await wait(300);
    report('editor playback ok');
    expect(tester.takeException(), isNull);
    await tester.pageBack();
    await wait(1500);
    expect(tester.takeException(), isNull);
  });
}
