import 'dart:convert';

import 'package:cutlab_project_format/cutlab_project_format.dart';
import 'package:test/test.dart';

Project sampleProject() {
  final base = Project.create(
    id: 'p1',
    name: 'Gameplay montage',
    settings: ProjectSettings.vertical1080p.copyWith(frameRate: Rational.fps59_94),
    now: DateTime.utc(2026, 11, 8, 12),
  );
  const media = MediaRef(
    id: 'm1',
    kind: MediaKind.video,
    uri: 'media/match01.mp4',
    displayName: 'match01.mp4',
    durationTicks: 2 * 3600 * ticksPerSecond, // a 2-hour recording
    width: 1920,
    height: 1080,
    frameRate: Rational.fps60,
    hasAudio: true,
    fingerprint: '7340032000:1762600000',
  );
  final clipA = Clip(
    id: 'c1',
    mediaId: 'm1',
    startTicks: 0,
    durationTicks: framesToTicks(300, Rational.fps59_94),
    sourceInTicks: 3600 * ticksPerSecond,
    effects: const [
      Effect(id: 'e1', type: 'color.basic', params: {'brightness': 0.1, 'saturation': 0.25}),
    ],
    keyframes: const {
      'transform.scale': [
        Keyframe(timeTicks: 0, value: 1.0),
        Keyframe(timeTicks: 705600000, value: 1.3, interpolation: Interpolation.bezier, bezier: [0.4, 0.0, 0.2, 1.0]),
      ],
    },
  );
  final clipB = Clip(
    id: 'c2',
    mediaId: 'm1',
    startTicks: clipA.endTicks,
    durationTicks: ticksPerSecond * 4,
    speed: Rational(1, 4), // slow motion
    transitionIn: const Transition(type: 'crossfade', durationTicks: ticksPerSecond ~/ 2),
  );
  final tracks = [
    base.tracks[0].copyWith(clips: [clipA, clipB]),
    base.tracks[1],
    base.tracks[2].copyWith(clips: [
      const Clip(id: 'txt1', startTicks: 0, durationTicks: 3 * ticksPerSecond, data: {'text': 'ACE!', 'font': 'Inter'}),
    ]),
  ];
  return base.copyWith(
    media: [media],
    tracks: tracks,
    markers: const [Marker(id: 'k1', timeTicks: 705600000, label: 'Triple kill')],
    editorMode: EditorMode.advanced,
  );
}

void main() {
  const codec = ProjectCodec();

  test('encode → decode round trip preserves everything', () {
    final p = sampleProject();
    final text = codec.encode(p);
    final back = codec.decode(text);
    expect(back.toJson(), p.toJson());
    expect(codec.encode(back), text);
  });

  test('envelope carries format id and version', () {
    final doc = jsonDecode(codec.encode(sampleProject())) as Map<String, Object?>;
    expect(doc['format'], 'cutlab-project');
    expect(doc['formatVersion'], currentFormatVersion);
  });

  test('duration covers the longest track', () {
    final p = sampleProject();
    expect(p.durationTicks, p.tracks[0].clips.last.endTicks);
  });

  test('switching editor mode never drops data', () {
    final p = sampleProject();
    final beginner = p.copyWith(editorMode: EditorMode.beginner);
    final back = codec.decode(codec.encode(beginner)).copyWith(editorMode: EditorMode.advanced);
    expect(back.toJson(), p.toJson());
  });

  group('rejects bad input with a JSON path', () {
    Map<String, Object?> doc() => jsonDecode(codec.encode(sampleProject())) as Map<String, Object?>;
    // The second clip of the first track in the decoded JSON document.
    Map<String, Object?> secondClip(Map<String, Object?> d) {
      final project = d['project'] as Map<String, Object?>;
      final track = (project['tracks'] as List<Object?>)[0] as Map<String, Object?>;
      return (track['clips'] as List<Object?>)[1] as Map<String, Object?>;
    }

    Matcher failsAt(String path) => throwsA(isA<ProjectFormatException>().having((e) => e.path, 'path', path));

    test('not JSON', () => expect(() => codec.decode('{nope'), throwsA(isA<ProjectFormatException>())));

    test('wrong format id', () {
      final d = doc()..['format'] = 'something-else';
      expect(() => codec.decode(jsonEncode(d)), failsAt(r'$.format'));
    });

    test('newer format version', () {
      final d = doc()..['formatVersion'] = currentFormatVersion + 1;
      expect(() => codec.decode(jsonEncode(d)), failsAt(r'$.formatVersion'));
    });

    test('negative duration', () {
      final d = doc();
      secondClip(d)['durationTicks'] = -5;
      expect(() => codec.decode(jsonEncode(d)), failsAt(r'$.project.tracks[0].clips[1].durationTicks'));
    });

    test('overlapping clips', () {
      final d = doc();
      secondClip(d)['startTicks'] = 10;
      expect(() => codec.decode(jsonEncode(d)), failsAt(r'$.project.tracks[0].clips[1].startTicks'));
    });

    test('unknown media reference', () {
      final d = doc();
      secondClip(d)['mediaId'] = 'ghost';
      expect(() => codec.decode(jsonEncode(d)), failsAt(r'$.project.tracks[0].clips[1].mediaId'));
    });

    test('unknown enum value', () {
      final d = doc();
      (((d['project'] as Map<String, Object?>)['tracks'] as List<Object?>)[0] as Map<String, Object?>)['kind'] = 'hologram';
      expect(() => codec.decode(jsonEncode(d)), failsAt(r'$.project.tracks[0].kind'));
    });
  });

  test('older versions are upgraded through the migration chain', () {
    // Pretend the current layout is version 2 and version 1 lacked "markers"
    // but had "bookmarks"; the codec must apply the migration before reading.
    final v2 = ProjectCodec(
      targetVersion: 2,
      migrations: {
        1: (p) => p
          ..['markers'] = p.remove('bookmarks') ?? <Object?>[]
          ..['name'] = '${p['name']} (migrated)',
      },
    );
    final d = jsonDecode(codec.encode(sampleProject())) as Map<String, Object?>;
    final body = d['project'] as Map<String, Object?>;
    body['bookmarks'] = body.remove('markers');
    final p = v2.decode(jsonEncode(d));
    expect(p.name, 'Gameplay montage (migrated)');
    expect(p.markers.single.label, 'Triple kill');
    expect(() => const ProjectCodec(targetVersion: 3).decode(jsonEncode(d)), throwsA(isA<ProjectFormatException>()));
  });

  test('media flags round trip and relinking keeps the id', () {
    const unprobed = MediaRef(
      id: 'm2',
      kind: MediaKind.video,
      uri: 'C:/Videos/raw.mkv',
      displayName: 'raw.mkv',
      durationTicks: 0,
      sizeBytes: 123456789,
      needsProbe: true,
    );
    final p = sampleProject().copyWith(media: [...sampleProject().media, unprobed]);
    final back = codec.decode(codec.encode(p));
    expect(back.media.last.needsProbe, isTrue);
    expect(back.media.last.sizeBytes, 123456789);
    expect(back.media.first.needsProbe, isFalse);

    final moved = back.media.first.relinkedTo(const MediaRef(
      id: 'ignored',
      kind: MediaKind.video,
      uri: 'D:/new/match01.mp4',
      displayName: 'match01.mp4',
      durationTicks: 42,
    ));
    expect(moved.id, 'm1');
    expect(moved.uri, 'D:/new/match01.mp4');
    expect(back.clipsUsingMedia('m1'), 2);
    expect(back.clipsUsingMedia('m2'), 0);
  });

  test('copyWith can assign a new identity (duplicate project)', () {
    final p = sampleProject();
    final copy = p.copyWith(id: 'p2', name: 'Copy', createdAt: DateTime.utc(2027));
    expect(copy.id, 'p2');
    expect(copy.createdAt, DateTime.utc(2027));
    expect(copy.tracks.length, p.tracks.length);
  });
}
