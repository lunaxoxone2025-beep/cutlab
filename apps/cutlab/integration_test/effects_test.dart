// Effects and transitions with the real engine, inside the real app:
//   Android: flutter test integration_test/effects_test.dart -d <emulator>
//            (media bundled as test-only assets, see android-tests.yml)
//   Windows: CUTLAB_TEST_MEDIA=<dir> flutter test integration_test/effects_test.dart -d windows
// Checks rendered pictures, not widgets: the preview picture and every
// exported frame are compared with the engine's composed picture, and a look
// and a transition picked in the editor are found in the exported video.
// Result lines start with "EFFECTS-REPORT".
import 'dart:convert';
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
import 'package:cutlab/src/timeline/timeline_state.dart';
import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:cutlab_project_format/cutlab_project_format.dart' as pf show Clip;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void report(String line) {
  // ignore: avoid_print
  print('EFFECTS-REPORT $line');
}

const tps = ticksPerSecond;

/// Mean absolute difference of two RGBA pictures of the same size (RGB).
double diff(RgbaImage a, RgbaImage b) {
  expect((a.width, a.height), (b.width, b.height));
  var sum = 0;
  for (var i = 0; i < a.pixels.length; i++) {
    if (i % 4 == 3) continue;
    sum += (a.pixels[i] - b.pixels[i]).abs();
  }
  return sum / (a.pixels.length * 0.75);
}

/// Average colour spread (max - min channel): 0 for gray pictures.
double colourfulness(RgbaImage f) {
  var s = 0;
  for (var i = 0; i < f.pixels.length; i += 4) {
    final r = f.pixels[i], g = f.pixels[i + 1], b = f.pixels[i + 2];
    s += math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
  }
  return s / (f.pixels.length / 4);
}

double mean(RgbaImage f) {
  var s = 0;
  for (var i = 0; i < f.pixels.length; i += 4) {
    s += f.pixels[i] + f.pixels[i + 1] + f.pixels[i + 2];
  }
  return s / (f.pixels.length / 4 * 3);
}

/// Two clips of [m] back to back on Video 1 with media on both sides of the
/// cut at 1.5 s: A shows 0.5..2.0 s of the file, B 2.5..4.0 s.
Project twoClips(MediaRef m, {String id = 'fx', String name = 'Effects test'}) {
  final p = Project.create(id: id, name: name, now: DateTime.utc(2026), settings: const ProjectSettings(width: 1280, height: 720));
  return p.copyWith(
    media: [m],
    tracks: [
      p.tracks[0].copyWith(clips: [
        pf.Clip(id: 'a', mediaId: m.id, startTicks: 0, durationTicks: 3 * tps ~/ 2, sourceInTicks: tps ~/ 2),
        pf.Clip(id: 'b', mediaId: m.id, startTicks: 3 * tps ~/ 2, durationTicks: 3 * tps ~/ 2, sourceInTicks: 5 * tps ~/ 2),
      ]),
      ...p.tracks.skip(1),
    ],
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late MediaEngine engine;
  late MediaPlatform media;
  late Directory out;
  final files = <String, String>{};

  setUpAll(() async {
    engine = FfiMediaEngine.load();
    out = await (await getTemporaryDirectory()).createTemp('effects');
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
  String uriOf(String name) => Platform.isAndroid ? Uri.file(files[name]!).toString() : files[name]!;

  Future<String> exportTo(String plan, String path, {int w = 640, int h = 360}) async {
    final settings = 'path $path\ncontainer mp4\nvideo h264\nsize ${w}x$h\nfps 30\nquality 90\nspeed fast\nhardware 0\naudio aac\n';
    final job = engine.startExport(plan, settings);
    final sw = Stopwatch()..start();
    var st = job.status();
    while (!st.finished && sw.elapsed < const Duration(minutes: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      st = job.status();
    }
    job.dispose();
    report('export $path: ${st.state.name} in ${sw.elapsedMilliseconds} ms, ${st.encoder} ${st.error} ${st.warnings.join('; ')}');
    expect(st.state, ExportState.done, reason: st.error);
    return path;
  }

  testWidgets('the engine renders the same effects the editor offers', (tester) async {
    final json = jsonDecode(engine.effectCatalogJson()) as Map<String, Object?>;
    final list = (json['effects']! as List<Object?>).cast<Map<String, Object?>>();
    expect({for (final e in list) e['type']}, {for (final s in effectCatalog) s.type});
    for (final e in list) {
      final spec = effectSpec(e['type']! as String)!;
      final params = (e['params']! as List<Object?>).cast<Map<String, Object?>>();
      expect([for (final p in params) p['name']], [for (final p in spec.params) p.name]);
      for (final p in params) {
        final mine = spec.param(p['name']! as String)!;
        expect((p['min']! as num).toDouble(), closeTo(mine.min, 1e-9));
        expect((p['max']! as num).toDouble(), closeTo(mine.max, 1e-9));
        expect((p['default']! as num).toDouble(), closeTo(mine.defaultValue, 1e-9));
      }
    }
    expect(json['looks'], filterLooks);
    expect(json['transitions'], [for (final t in transitionCatalog) t.type]);
    report('catalogue: ${list.length} effects, ${filterLooks.length} looks, ${transitionCatalog.length} transitions (same as the editor)');
  });

  testWidgets('preview picture = composed picture = exported frame; sound continues across the transition', (tester) async {
    await tester.runAsync(() async {
      final src = pick(['h264_1080p60.mp4', 'h264_1080p30.mp4', 'gray60.mp4']);
      final srcUri = await media.openForEngine(uriOf(src));
      try {
        final info = await engine.probe(srcUri);
        final m = MediaRef(
            id: 'm', kind: MediaKind.video, uri: uriOf(src), displayName: src, durationTicks: info.durationTicks, hasAudio: info.audioCodec != null);
        expect(info.durationTicks, greaterThanOrEqualTo(4 * tps), reason: 'needs media beyond the cut');
        var ids = 0;
        String id() => 'fx${++ids}';
        var p = twoClips(m);
        p = p.setEffects('a', lookPresets.firstWhere((l) => l.id == 'cinematic').build(id));
        p = p.addEffects('b', [newEffect('grayscale', id(), params: {'amount': 0.8}), newEffect('vignette', id())]);
        p = p.setVideoFades('b', fadeOutTicks: tps ~/ 2);
        p = p.setTransition('b', const Transition(type: 'dissolve', durationTicks: tps));
        expect(p.transitionInto('b')!.durationTicks, tps);
        final plan = buildTimelinePlan(p, {'m': srcUri}, hardware: false).text;
        final plain = buildTimelinePlan(twoClips(m), {'m': srcUri}, hardware: false).text;
        report('plan:\n${plan.split('\n').where((l) => !l.startsWith('clip ')).join('\n')}');
        final times = [tps ~/ 2, 5 * tps ~/ 4, 3 * tps ~/ 2, 7 * tps ~/ 4, 5 * tps ~/ 2];

        // The preview (the timeline renderer the editor uses).
        final r = engine.openTimeline(maxWidth: 640, maxHeight: 360, nullAudio: true);
        try {
          r.setPlan(plan);
          for (final t in times) {
            r.seek(t);
            RgbaImage? shown;
            final sw = Stopwatch()..start();
            while (shown == null && sw.elapsedMilliseconds < 8000) {
              await Future<void>.delayed(const Duration(milliseconds: 15));
              final pic = r.pollFrame();
              if (pic != null && pic.ptsTicks == t) shown = pic.image;
            }
            expect(shown, isNotNull, reason: 'a picture at ${t / tps} s');
            final want = await engine.renderFrame(plan, t, shown!.width, shown.height);
            final d = diff(shown, want);
            report('preview at ${(t / tps).toStringAsFixed(2)} s (${shown.width}x${shown.height}): differs from the composed picture by ${d.toStringAsFixed(3)}');
            expect(d, lessThan(0.5), reason: 'the preview shows the composed picture');
          }
        } finally {
          r.dispose();
        }

        // The export: every checked frame is the composed picture.
        final path = await exportTo('${plan}duration ${p.durationTicks}\n', '${out.path}${Platform.pathSeparator}effects.mp4');
        for (final t in times) {
          final got = await engine.frameAt(path, t + tps ~/ 60, maxWidth: 640, maxHeight: 360);
          final want = await engine.renderFrame(plan, t, got.width, got.height);
          final bare = await engine.renderFrame(plain, t, got.width, got.height);
          final d = diff(got, want), d0 = diff(got, bare);
          report('export at ${(t / tps).toStringAsFixed(2)} s: ${d.toStringAsFixed(2)} from the composed picture, ${d0.toStringAsFixed(2)} from the plain one');
          expect(d, lessThan(8));
          expect(d0, greaterThan(d + 2), reason: 'effects are in the file');
        }
        final end = await engine.frameAt(path, p.durationTicks - tps ~/ 60, maxWidth: 640, maxHeight: 360);
        expect(mean(end), lessThan(25), reason: 'faded out to black');

        // Sound: the exported mix follows the preview mix through the cross-fade.
        if (m.hasAudio) {
          final pr = engine.openTimeline(maxWidth: 64, maxHeight: 64, nullAudio: true);
          final er = engine.openTimeline(maxWidth: 64, maxHeight: 64, nullAudio: true);
          try {
            pr.setPlan(plan);
            er.setPlan('cutlab-timeline 1\ntrack x audio 0 0 0 1\nclip x 0 ${10 * tps} 0 1 0 0 1 0 1 $path\n');
            final a = pr.renderAudio(tps, 48000);
            final b = er.renderAudio(tps, 48000);
            double rmsOf(List<double> s, int i, int n) => math.sqrt([for (var k = i; k < i + n; k++) s[2 * k] * s[2 * k]].fold<double>(0, (x, y) => x + y) / n);
            var worst = 0.0;
            for (var i = 0; i + 2400 <= 48000; i += 2400) {
              worst = math.max(worst, (rmsOf(a, i, 2400) - rmsOf(b, i, 2400)).abs());
            }
            report('sound across the dissolve: exported vs preview mix, worst 50 ms RMS difference ${worst.toStringAsFixed(4)}');
            expect(worst, lessThan(0.05));
          } finally {
            pr.dispose();
            er.dispose();
          }
        }
      } finally {
        await media.closeForEngine(srcUri);
      }
    });
  });

  testWidgets('a look and a transition picked in the editor are in the exported video', (tester) async {
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

    final src = pick(['h264_1080p30.mp4', 'h264_1080p60.mp4', 'gray60.mp4']);
    final services = AppServices(
      projects: ProjectStore(MemoryBackend()),
      settingsStore: SettingsStore(MemoryBackend()),
      media: media,
      engine: engine,
      settings: const AppSettings(hardwareDecoding: false),
    );
    final m = MediaRef(id: 'm', kind: MediaKind.video, uri: uriOf(src), displayName: src, durationTicks: 6 * tps, hasAudio: true);
    final project = twoClips(m, id: 'ui', name: 'Effects UI');
    await tester.runAsync(() => services.projects.save(project));
    await tester.pumpWidget(CutlabApp(services: services));
    await wait(1500);
    await tester.tap(find.text('Effects UI'));
    await wait(2500);

    // Select the second clip (2.25 s at 40 px/s) on the video row, open Effects.
    final origin = tester.getTopLeft(find.byKey(const Key('timelineCanvas')));
    await tester.tapAt(origin + Offset(2.25 * 40, rulerHeight + trackHeight(TrackKind.text) + 2 + 20));
    await wait(300);
    await tester.tap(find.byKey(const Key('tlEffects')));
    await wait(500);
    await tester.ensureVisible(find.byKey(const Key('look-noir')));
    await wait(300);
    await tester.tap(find.byKey(const Key('look-noir')));
    await wait(300);
    final scrollable = find.descendant(of: find.byKey(const Key('fxPanel')), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.byKey(const Key('trType-dip_black')), 150, scrollable: scrollable);
    await tester.ensureVisible(find.byKey(const Key('trType-dip_black')));
    await wait(400);
    await tester.tap(find.byKey(const Key('trType-dip_black')));
    await wait(1500); // the preview renders it meanwhile
    expect(find.byKey(const Key('trSpan')), findsOneWidget, reason: 'the dip is set and plays');
    expect(tester.takeException(), isNull);
    await tester.pageBack();
    await wait(1000);

    await tester.runAsync(() async {
      final saved = await services.projects.open('ui');
      final b = saved.find('b')!.clip;
      report('saved: effects ${[for (final e in b.effects) e.type]}, transition ${b.transitionIn?.type} ${b.transitionIn?.durationTicks}');
      expect([for (final e in b.effects) e.type], ['filter', 'vignette']);
      expect(b.transitionIn?.type, 'dip_black');
      final srcUri = await media.openForEngine(uriOf(src));
      try {
        final plan = buildTimelinePlan(saved, {'m': srcUri}, hardware: false).text;
        final path = await exportTo('${plan}duration ${saved.durationTicks}\n', '${out.path}${Platform.pathSeparator}ui.mp4');
        final before = await engine.frameAt(path, tps ~/ 2, maxWidth: 320, maxHeight: 180);
        final atCut = await engine.frameAt(path, 3 * tps ~/ 2 + tps ~/ 60, maxWidth: 320, maxHeight: 180);
        final after = await engine.frameAt(path, 5 * tps ~/ 2, maxWidth: 320, maxHeight: 180);
        report('exported: colour before ${colourfulness(before).toStringAsFixed(1)}, after (noir) ${colourfulness(after).toStringAsFixed(1)}; '
            'brightness at the cut (dip to black) ${mean(atCut).toStringAsFixed(1)}');
        expect(colourfulness(after), lessThan(4), reason: 'noir is black and white');
        expect(mean(atCut), lessThan(25), reason: 'the dip reaches black at the cut');
        expect(diff(after, await engine.renderFrame(plan, 5 * tps ~/ 2, after.width, after.height)), lessThan(8));
      } finally {
        await media.closeForEngine(srcUri);
      }
    });
  });
}
