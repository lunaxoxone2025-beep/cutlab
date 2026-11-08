import 'dart:convert';

import 'package:cutlab_project_format/cutlab_project_format.dart';
import 'package:test/test.dart';

void main() {
  Project project() => Project.create(id: 'p', name: 'Mix', now: DateTime.utc(2026));

  test('track volume, solo and master volume are stored and clamped', () {
    var p = project().updateTrack('a1', volume: 1.5, solo: true).setMasterVolume(3);
    expect(p.trackById('a1')!.volume, 1.5);
    expect(p.trackById('a1')!.solo, isTrue);
    expect(p.masterVolume, 2.0);
    p = p.updateTrack('a1', volume: -1).setMasterVolume(-1);
    expect(p.trackById('a1')!.volume, 0.0);
    expect(p.masterVolume, 0.0);
  });

  test('solo and mute decide which tracks are heard', () {
    var p = project();
    expect(p.isAudible(p.trackById('v1')!), isTrue);
    p = p.updateTrack('a1', solo: true);
    expect(p.isAudible(p.trackById('a1')!), isTrue);
    expect(p.isAudible(p.trackById('v1')!), isFalse, reason: 'another track is soloed');
    p = p.updateTrack('a1', muted: true);
    expect(p.isAudible(p.trackById('a1')!), isFalse, reason: 'mute wins over solo');
  });

  test('mix settings survive saving; v2 files read with defaults', () {
    const codec = ProjectCodec();
    final p = project().updateTrack('a1', volume: 0.5, solo: true).setMasterVolume(1.25);
    final back = codec.decode(codec.encode(p));
    expect(back.trackById('a1')!.volume, 0.5);
    expect(back.trackById('a1')!.solo, isTrue);
    expect(back.masterVolume, 1.25);

    final d = jsonDecode(codec.encode(project())) as Map<String, Object?>;
    d['formatVersion'] = 2;
    final body = d['project'] as Map<String, Object?>;
    body.remove('masterVolume');
    for (final t in body['tracks'] as List<Object?>) {
      (t as Map<String, Object?>)
        ..remove('volume')
        ..remove('solo');
    }
    final old = codec.decode(jsonEncode(d));
    expect(old.masterVolume, 1.0);
    expect(old.tracks.every((t) => t.volume == 1.0 && !t.solo), isTrue);
  });
}
