import 'package:cutlab_project_format/cutlab_project_format.dart';
import 'package:test/test.dart';

const tps = ticksPerSecond;

/// Deterministic ids: id1, id2, …
IdGenerator counter() {
  var n = 0;
  return () => 'id${++n}';
}

Project baseProject({Rational fps = Rational.fps30}) {
  final p = Project.create(id: 'p', name: 'T', settings: ProjectSettings(frameRate: fps), now: DateTime.utc(2026));
  return p.copyWith(media: const [
    MediaRef(id: 'gameplay', kind: MediaKind.video, uri: '/g.mp4', displayName: 'g.mp4', durationTicks: 3600 * tps, hasAudio: true),
    MediaRef(id: 'music', kind: MediaKind.audio, uri: '/m.mp3', displayName: 'm.mp3', durationTicks: 180 * tps, hasAudio: true),
    MediaRef(id: 'photo', kind: MediaKind.image, uri: '/p.png', displayName: 'p.png', durationTicks: 0),
    MediaRef(id: 'short', kind: MediaKind.video, uri: '/s.mp4', displayName: 's.mp4', durationTicks: 10 * tps),
  ]);
}

/// Round-trips through the codec: every edit must produce a valid file.
Project valid(Project p) => const ProjectCodec().decode(const ProjectCodec().encode(p));

Clip clip(Project p, String id) => p.find(id)!.clip;
Track trackOf(Project p, String id) => p.find(id)!.track;

void main() {
  late IdGenerator ids;
  setUp(() => ids = counter());

  group('adding', () {
    test('media goes to the matching track kind at a frame boundary', () {
      var p = baseProject();
      final String v, a, i;
      (p, v) = p.addMediaClip('gameplay', tps + 1234, ids);
      (p, a) = p.addMediaClip('music', 0, ids);
      (p, i) = p.addMediaClip('photo', 0, ids);
      p = valid(p);
      expect(trackOf(p, v).kind, TrackKind.video);
      expect(trackOf(p, a).kind, TrackKind.audio);
      expect(trackOf(p, i).kind, TrackKind.image);
      expect(clip(p, v).startTicks, tps, reason: 'snapped to the 30 fps grid');
      expect(clip(p, v).durationTicks, 3600 * tps);
      expect(clip(p, i).durationTicks, defaultStillDurationTicks);
    });

    test('a busy spot creates a second track instead of overwriting', () {
      var p = baseProject();
      final String a, b;
      (p, a) = p.addMediaClip('short', 0, ids);
      (p, b) = p.addMediaClip('short', 5 * tps, ids);
      p = valid(p);
      expect(trackOf(p, a).id, isNot(trackOf(p, b).id));
      expect(p.tracks.where((t) => t.kind == TrackKind.video), hasLength(2));
    });

    test('media still being analysed cannot be placed yet', () {
      var p = baseProject();
      p = p.copyWith(media: [
        ...p.media,
        const MediaRef(id: 'new', kind: MediaKind.video, uri: '/n.mkv', displayName: 'n.mkv', durationTicks: 0, needsProbe: true),
      ]);
      expect(() => p.addMediaClip('new', 0, ids), throwsA(isA<EditException>()));
    });

    test('text clips', () {
      var p = baseProject();
      final String t;
      (p, t) = p.addTextClip('GG', 2 * tps, ids);
      p = valid(p);
      expect(trackOf(p, t).kind, TrackKind.text);
      expect(clip(p, t).data['text'], 'GG');
      p = p.setText(t, 'Victory');
      expect(clip(p, t).data['text'], 'Victory');
    });
  });

  group('frame accuracy at every project rate', () {
    for (final fps in [Rational.fps24, Rational.fps29_97, Rational.fps30, Rational.fps60, Rational.fps120]) {
      test('split lands exactly on a frame at $fps fps', () {
        var p = baseProject(fps: fps);
        final String v;
        (p, v) = p.addMediaClip('gameplay', 0, ids);
        final target = framesToTicks(12345, fps) + 17; // a little after frame 12345
        final List<String> right;
        (p, right) = p.split(target, ids, clipIds: [v]);
        p = valid(p);
        final l = clip(p, v), r = clip(p, right.single);
        expect(l.endTicks, framesToTicks(12345, fps));
        expect(r.startTicks, l.endTicks);
        expect(r.sourceInTicks, l.sourceInTicks + l.durationTicks);
        expect(l.durationTicks + r.durationTicks, framesToTicks(ticksToFrames(3600 * tps, fps), fps));
      });
    }
  });

  group('moving', () {
    test('moves in time and to another track of the same kind', () {
      var p = baseProject();
      final String v;
      (p, v) = p.addMediaClip('short', 0, ids);
      final String t2;
      (p, t2) = p.addTrack(TrackKind.video, ids);
      p = valid(p.moveClip(v, 2 * tps + 5, ids, targetTrackId: t2));
      expect(clip(p, v).startTicks, 2 * tps);
      expect(trackOf(p, v).id, t2);
      expect(trackOf(p, v).kind, TrackKind.video);
    });

    test('never crosses into a different kind of track', () {
      var p = baseProject();
      final String v;
      (p, v) = p.addMediaClip('short', 0, ids);
      final audioTrack = p.tracks.firstWhere((t) => t.kind == TrackKind.audio).id;
      p = valid(p.moveClip(v, 0, ids, targetTrackId: audioTrack));
      expect(trackOf(p, v).kind, TrackKind.video);
    });

    test('dropping onto another clip puts it on a free track, nothing is overwritten', () {
      var p = baseProject();
      final String a, b;
      (p, a) = p.addMediaClip('short', 0, ids);
      (p, b) = p.addMediaClip('short', 20 * tps, ids);
      final before = clip(p, b);
      p = valid(p.moveClip(a, 22 * tps, ids, targetTrackId: trackOf(p, b).id));
      expect(clip(p, b).toJson(), before.toJson());
      expect(trackOf(p, a).id, isNot(trackOf(p, b).id));
      expect(clip(p, a).startTicks, 22 * tps);
    });

    test('group move keeps relative positions and refuses collisions', () {
      var p = baseProject();
      final String a, b, m;
      (p, a) = p.addMediaClip('short', 0, ids);
      (p, b) = p.addMediaClip('short', 10 * tps, ids);
      (p, m) = p.addMediaClip('music', 100 * tps, ids);
      p = valid(p.moveClipsBy([a, b], 30 * tps));
      expect(clip(p, a).startTicks, 30 * tps);
      expect(clip(p, b).startTicks, 40 * tps);
      expect(() => p.moveClipsBy([m], -95 * tps), returnsNormally);
      final (p2, c) = p.addMediaClip('short', 60 * tps, ids);
      expect(() => p2.moveClipsBy([c], -15 * tps), throwsA(isA<EditException>()));
      // Never before zero.
      expect(clip(p.moveClipsBy([a, b], -999 * tps), a).startTicks, 0);
    });

    test('locked tracks cannot be changed', () {
      var p = baseProject();
      final String v;
      (p, v) = p.addMediaClip('short', 0, ids);
      p = p.updateTrack(trackOf(p, v).id, locked: true);
      expect(() => p.moveClip(v, tps, ids), throwsA(isA<EditException>()));
      expect(() => p.trimEnd(v, tps), throwsA(isA<EditException>()));
      expect(() => p.deleteClips([v]), throwsA(isA<EditException>()));
      expect(() => p.split(5 * tps, ids, clipIds: [v]), throwsA(isA<EditException>()));
      // Splitting "everything" skips locked tracks.
      expect(() => p.split(5 * tps, ids), throwsA(isA<EditException>()));
    });
  });

  group('trimming', () {
    test('trim start moves the source in-point with the edge', () {
      var p = baseProject();
      final String v;
      (p, v) = p.addMediaClip('short', 0, ids);
      p = valid(p.trimStart(v, 3 * tps));
      expect(clip(p, v).startTicks, 3 * tps);
      expect(clip(p, v).sourceInTicks, 3 * tps);
      expect(clip(p, v).durationTicks, 7 * tps);
      // Cannot extend before the start of the file.
      p = valid(p.trimStart(v, -50 * tps));
      expect(clip(p, v).startTicks, 0);
      expect(clip(p, v).sourceInTicks, 0);
    });

    test('trim end is limited by the file and the next clip', () {
      var p = baseProject();
      final String a, b;
      (p, a) = p.addMediaClip('short', 0, ids);
      p = valid(p.trimEnd(a, 4 * tps));
      expect(clip(p, a).durationTicks, 4 * tps);
      p = valid(p.trimEnd(a, 99 * tps));
      expect(clip(p, a).durationTicks, 10 * tps, reason: 'the file is only 10 s long');
      p = p.trimEnd(a, 4 * tps);
      (p, b) = p.addMediaClip('short', 6 * tps, ids, trackId: trackOf(p, a).id);
      expect(trackOf(p, b).id, trackOf(p, a).id);
      p = valid(p.trimEnd(a, 9 * tps));
      expect(clip(p, a).endTicks, 6 * tps, reason: 'stops at the next clip');
      p = valid(p.trimEnd(a, 0));
      expect(clip(p, a).durationTicks, p.frameTicks, reason: 'at least one frame');
    });

    test('photos and titles get any duration', () {
      var p = baseProject();
      final String i;
      (p, i) = p.addMediaClip('photo', 0, ids);
      p = valid(p.setDuration(i, 42 * tps));
      expect(clip(p, i).durationTicks, 42 * tps);
      final String v;
      (p, v) = p.addMediaClip('short', 0, ids);
      expect(() => p.setDuration(v, tps), throwsA(isA<EditException>()));
    });
  });

  group('split, delete, duplicate, copy & paste', () {
    test('split everything under the playhead', () {
      var p = baseProject();
      final String v, m;
      (p, v) = p.addMediaClip('gameplay', 0, ids);
      (p, m) = p.addMediaClip('music', 0, ids);
      final List<String> created;
      (p, created) = p.split(60 * tps, ids);
      p = valid(p);
      expect(created, hasLength(2));
      expect(clip(p, v).endTicks, 60 * tps);
      expect(clip(p, m).endTicks, 60 * tps);
      expect(() => p.split(999999 * tps, ids), throwsA(isA<EditException>()));
    });

    test('ripple delete closes the gap on that track only', () {
      var p = baseProject();
      final String a, b, music;
      (p, a) = p.addMediaClip('short', 0, ids);
      (p, b) = p.addMediaClip('short', 10 * tps, ids, trackId: trackOf(p, a).id);
      (p, music) = p.addMediaClip('music', 15 * tps, ids);
      final plain = valid(p.deleteClips([a]));
      expect(clip(plain, b).startTicks, 10 * tps);
      final rippled = valid(p.deleteClips([a], ripple: true));
      expect(rippled.find(a), isNull);
      expect(clip(rippled, b).startTicks, 0);
      expect(clip(rippled, music).startTicks, 15 * tps);
    });

    test('duplicate places copies right after the selection', () {
      var p = baseProject();
      final String a;
      (p, a) = p.addMediaClip('short', 2 * tps, ids);
      final List<String> copies;
      (p, copies) = p.duplicate([a], ids);
      p = valid(p);
      expect(clip(p, copies.single).startTicks, 12 * tps);
      expect(clip(p, copies.single).mediaId, 'short');
    });

    test('copy & paste at the playhead keeps relative timing and links', () {
      var p = baseProject();
      final String v, a;
      (p, v) = p.addMediaClip('short', 0, ids);
      (p, a) = p.detachAudio(v, ids);
      final board = p.copy([v]);
      expect(board.items, hasLength(2), reason: 'linked audio is copied too');
      final List<String> pasted;
      (p, pasted) = p.paste(board, 100 * tps, ids);
      p = valid(p);
      final pv = pasted.map((id) => clip(p, id)).toList();
      expect(pv.map((c) => c.startTicks).toSet(), {100 * tps});
      expect(pv[0].linkId, isNotNull);
      expect(pv[0].linkId, pv[1].linkId);
      expect(pv[0].linkId, isNot(clip(p, a).linkId), reason: 'a fresh link for the copies');
    });
  });

  group('audio', () {
    test('detached audio is linked: moves, trims and splits with the video', () {
      var p = baseProject();
      final String v, a;
      (p, v) = p.addMediaClip('gameplay', 0, ids);
      (p, a) = p.detachAudio(v, ids);
      p = valid(p);
      expect(clip(p, v).volume, 0, reason: 'video clip muted');
      expect(clip(p, a).volume, 1);
      expect(trackOf(p, a).kind, TrackKind.audio);

      p = valid(p.moveClip(v, 5 * tps, ids));
      expect(clip(p, a).startTicks, 5 * tps);
      p = valid(p.trimStart(a, 8 * tps));
      expect(clip(p, v).startTicks, 8 * tps);
      expect(clip(p, v).sourceInTicks, clip(p, a).sourceInTicks);
      final List<String> right;
      (p, right) = p.split(20 * tps, ids, clipIds: [v]);
      p = valid(p);
      expect(right, hasLength(2));
      expect(clip(p, right[0]).linkId, clip(p, right[1]).linkId);
      expect(clip(p, right[0]).linkId, isNot(clip(p, v).linkId));
      p = valid(p.deleteClips([v]));
      expect(p.find(a), isNull, reason: 'deleting the video deletes its linked audio');
    });

    test('unlinked audio can be nudged frame by frame for sync', () {
      var p = baseProject(fps: Rational.fps60);
      final String v, a;
      (p, v) = p.addMediaClip('gameplay', 10 * tps, ids);
      (p, a) = p.detachAudio(v, ids);
      expect(() => p.nudge([a], 2), throwsA(isA<EditException>()), reason: 'linked: would break sync silently');
      p = p.unlink([a]);
      expect(clip(p, v).linkId, isNull);
      p = valid(p.nudge([a], 3));
      expect(clip(p, a).startTicks - clip(p, v).startTicks, framesToTicks(3, Rational.fps60));
      p = valid(p.nudge([a], -3));
      expect(clip(p, a).startTicks, clip(p, v).startTicks);
      p = valid(p.link([v, a], ids));
      expect(clip(p, a).linkId, clip(p, v).linkId);
    });

    test('volume and fades', () {
      var p = baseProject();
      final String m;
      (p, m) = p.addMediaClip('music', 0, ids);
      p = valid(p.setVolume([m], 3.0));
      expect(clip(p, m).volume, 2.0);
      p = valid(p.setFades(m, fadeInTicks: 2 * tps + 1, fadeOutTicks: 5 * tps));
      expect(clip(p, m).fadeInTicks, 2 * tps);
      expect(clip(p, m).fadeOutTicks, 5 * tps);
      p = p.trimEnd(m, 4 * tps);
      expect(clip(p, m).fadeOutTicks, lessThanOrEqualTo(4 * tps));
      p = valid(p.setFades(m, fadeInTicks: 4 * tps));
      expect(clip(p, m).fadeInTicks + clip(p, m).fadeOutTicks, lessThanOrEqualTo(clip(p, m).durationTicks));
      expect(() => p.detachAudio(m, ids), throwsA(isA<EditException>()));
    });
  });

  group('tracks', () {
    test('add, hide, mute, rename, reorder, remove', () {
      var p = baseProject();
      final String t;
      (p, t) = p.addTrack(TrackKind.video, ids);
      p = p.updateTrack(t, hidden: true, muted: true, name: 'Facecam');
      expect(p.trackById(t)!.name, 'Facecam');
      expect(p.trackById(t)!.hidden, isTrue);
      p = p.reorderTrack(t, 0);
      expect(p.tracks.first.id, t);
      p = valid(p.removeTrack(t));
      expect(p.trackById(t), isNull);
    });

    test('the top visible picture wins in the preview', () {
      var p = baseProject();
      final String bottom, top;
      (p, bottom) = p.addMediaClip('short', 0, ids);
      (p, top) = p.addMediaClip('photo', 0, ids);
      expect(p.topVisualAt(tps)!.clip.id, top);
      p = p.updateTrack(trackOf(p, top).id, hidden: true);
      expect(p.topVisualAt(tps)!.clip.id, bottom);
      expect(p.sourceTimeAt(clip(p, bottom), 2 * tps), 2 * tps);
    });
  });

  test('snapping', () {
    final points = [0, 10 * tps, 20 * tps];
    expect(snapTo(10 * tps + 100, points, 1000), 10 * tps);
    expect(snapTo(10 * tps + 5000, points, 1000), 10 * tps + 5000);
    // A 3 s clip dragged so its end is near 20 s snaps by its end.
    expect(snapRange(17 * tps - 50, 3 * tps, points, 100), 17 * tps);
    var p = baseProject();
    final String v;
    (p, v) = p.addMediaClip('short', 0, counter());
    expect(p.snapPoints(playhead: 7 * tps), containsAll([0, 7 * tps, 10 * tps]));
    expect(p.snapPoints(exclude: {v}), [0]);
  });

  test('a two-hour project with many clips stays fast', () {
    var p = baseProject(fps: Rational.fps60);
    final String v;
    (p, v) = p.addMediaClip('gameplay', 0, ids);
    final sw = Stopwatch()..start();
    // 300 cuts across one hour of gameplay.
    for (var i = 1; i <= 300; i++) {
      (p, _) = p.split(i * 12 * tps, ids, clipIds: [p.clipsAt(i * 12 * tps).single.clip.id]);
    }
    p = p.deleteClips([v], ripple: true);
    final json = const ProjectCodec().encode(p);
    final back = const ProjectCodec().decode(json);
    sw.stop();
    expect(back.tracks.firstWhere((t) => t.kind == TrackKind.video).clips, hasLength(300));
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });

  test('version 1 files still open', () {
    final v1 = const ProjectCodec().encode(baseProject()).replaceFirst('"formatVersion": 2', '"formatVersion": 1');
    expect(const ProjectCodec().decode(v1).media, hasLength(4));
  });
}
