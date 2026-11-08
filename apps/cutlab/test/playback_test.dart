import 'package:cutlab/src/editor/editor_controller.dart';
import 'package:cutlab/src/playback/timeline_plan.dart';
import 'package:cutlab/src/storage/project_store.dart';
import 'package:cutlab/src/storage/store_backend.dart';
import 'package:cutlab/src/timeline/mixer_panel.dart';
import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:cutlab_project_format/cutlab_project_format.dart' as pf show Clip;
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const tps = ticksPerSecond;

Project project() {
  final p = Project.create(id: 'p', name: 'Mix', now: DateTime.utc(2026));
  const media = [
    MediaRef(id: 'game', kind: MediaKind.video, uri: '/v/game 1.mp4', displayName: 'game 1.mp4', durationTicks: 600 * tps, hasAudio: true),
    MediaRef(id: 'mute', kind: MediaKind.video, uri: '/v/silent.mp4', displayName: 'silent.mp4', durationTicks: 60 * tps),
    MediaRef(id: 'song', kind: MediaKind.audio, uri: '/a/song.mp3', displayName: 'song.mp3', durationTicks: 180 * tps, hasAudio: true),
    MediaRef(id: 'pic', kind: MediaKind.image, uri: '/i/pic.png', displayName: 'pic.png', durationTicks: 0),
  ];
  return p.copyWith(media: media, tracks: [
    p.tracks[0].copyWith(clips: const [
      pf.Clip(id: 'c1', mediaId: 'game', startTicks: 0, durationTicks: 10 * tps, sourceInTicks: 5 * tps),
      pf.Clip(id: 'c2', mediaId: 'mute', startTicks: 10 * tps, durationTicks: 5 * tps),
    ]),
    p.tracks[1].copyWith(clips: const [
      pf.Clip(
          id: 'c3', mediaId: 'song', startTicks: 2 * tps, durationTicks: 20 * tps, volume: 0.5, fadeInTicks: tps, fadeOutTicks: 2 * tps),
    ]),
    p.tracks[2].copyWith(clips: const [
      pf.Clip(id: 'txt', startTicks: 0, durationTicks: 3 * tps, data: {'text': 'Hi'}),
    ]),
    const Track(
        id: 'i1',
        kind: TrackKind.image,
        clips: [pf.Clip(id: 'c4', mediaId: 'pic', startTicks: 0, durationTicks: 2 * tps, sourceInTicks: 7)]),
  ]);
}

const uris = {'game': 'fd:41', 'mute': '/v/silent.mp4', 'song': 'fd:42', 'pic': '/i/pic.png'};

void main() {
  test('the plan lists picture and sound tracks with every clip setting', () {
    final plan = buildTimelinePlan(project().updateTrack('a1', volume: 1.5, solo: true).setMasterVolume(0.8), uris, hardware: true);
    final lines = plan.text.trim().split('\n');
    expect(lines.first, 'cutlab-timeline 1');
    expect(lines, contains('master 0.8000'));
    expect(lines, contains('hardware 1'));
    expect(plan.trackIds, ['v1', 'a1', 'i1'], reason: 'text tracks are drawn by the monitor, not the renderer');
    expect(lines, contains('track v1 video 0 0 0 1.0000'));
    expect(lines, contains('track a1 audio 0 1 0 1.5000'));
    // id start duration in volume fadeIn fadeOut audio still speed uri
    expect(lines, contains('clip c1 0 ${10 * tps} ${5 * tps} 1.0000 0 0 1 0 1 fd:41'));
    expect(lines, contains('clip c2 ${10 * tps} ${5 * tps} 0 1.0000 0 0 0 0 1 /v/silent.mp4'), reason: 'a video without sound');
    expect(lines, contains('clip c3 ${2 * tps} ${20 * tps} 0 0.5000 $tps ${2 * tps} 1 0 1 fd:42'));
    expect(lines, contains('clip c4 0 ${2 * tps} 0 1.0000 0 0 0 1 1 /i/pic.png'), reason: 'photos: still, no sound, no in-point');
    expect(plan.clipCount, 4);
  });

  test('clips whose media cannot be opened are left out; mute and hide are passed on', () {
    final p = project().updateTrack('v1', muted: true, hidden: true);
    final plan = buildTimelinePlan(p, {'song': 'fd:42'}, hardware: false);
    expect(plan.text, contains('hardware 0'));
    expect(plan.text, contains('track v1 video 1 0 1 1.0000'));
    expect(plan.clipCount, 1);
    expect(plan.text, isNot(contains('clip c1')));
  });

  test('uris with spaces stay one field at the end of the line', () {
    final plan = buildTimelinePlan(project(), {'game': '/v/game 1.mp4'}, hardware: false);
    expect(plan.text, contains(' 1 /v/game 1.mp4\n'));
  });

  test('gain labels and live edits that undo in one step', () async {
    expect(gainLabel(1), '0.0 dB');
    expect(gainLabel(2), '+6.0 dB');
    expect(gainLabel(0.5), '−6.0 dB');
    expect(gainLabel(0), '−∞ dB');

    final store = ProjectStore(MemoryBackend());
    final c = EditorController(project: project(), store: store, media: FakeMediaPlatform());
    for (final v in [0.9, 0.7, 0.4]) {
      c.editLive((p) => p.updateTrack('a1', volume: v));
    }
    expect(c.project.trackById('a1')!.volume, 0.4, reason: 'applied while dragging');
    c.commitLive();
    expect(c.canUndo, isTrue);
    c.undo();
    expect(c.project.trackById('a1')!.volume, 1.0, reason: 'the whole drag is one undo step');
    c.dispose();
  });
}
