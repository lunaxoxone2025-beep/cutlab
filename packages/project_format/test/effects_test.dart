import 'dart:io';

import 'package:cutlab_project_format/cutlab_project_format.dart';
import 'package:test/test.dart';

const tps = ticksPerSecond;

IdGenerator counter() {
  var n = 0;
  return () => 'e${++n}';
}

/// Two adjacent clips of a long recording on v1 (plenty of media on both
/// sides of the cut), a photo after them, and a gap before a fourth clip.
Project twoClips({int aIn = 10 * tps, int bIn = 100 * tps}) {
  final p = Project.create(id: 'p', name: 'FX', now: DateTime.utc(2026));
  return p.copyWith(
    media: const [
      MediaRef(id: 'game', kind: MediaKind.video, uri: '/g.mp4', displayName: 'g.mp4', durationTicks: 3600 * tps, hasAudio: true),
      MediaRef(id: 'short', kind: MediaKind.video, uri: '/s.mp4', displayName: 's.mp4', durationTicks: 6 * tps, hasAudio: true),
      MediaRef(id: 'photo', kind: MediaKind.image, uri: '/p.png', displayName: 'p.png', durationTicks: 0),
    ],
    tracks: [
      p.tracks[0].copyWith(clips: [
        Clip(id: 'a', mediaId: 'game', startTicks: 0, durationTicks: 5 * tps, sourceInTicks: aIn),
        Clip(id: 'b', mediaId: 'game', startTicks: 5 * tps, durationTicks: 5 * tps, sourceInTicks: bIn),
        const Clip(id: 'c', mediaId: 'photo', startTicks: 10 * tps, durationTicks: 3 * tps),
        const Clip(id: 'd', mediaId: 'short', startTicks: 20 * tps, durationTicks: 3 * tps),
      ]),
      ...p.tracks.skip(1),
    ],
  );
}

Project valid(Project p) => const ProjectCodec().decode(const ProjectCodec().encode(p));
Clip clip(Project p, String id) => p.find(id)!.clip;

void main() {
  test('the catalogue is the engine catalogue (types, parameters, ranges, defaults)', () {
    // core/src/media/effects.cpp lists {"type", {{"name", lo, hi, def}, ...}}.
    final src = File('../../core/src/media/effects.cpp').readAsStringSync();
    final block = src.substring(src.indexOf('static const std::vector<EffectSpec> s = {'), src.indexOf('  return s;\n}'));
    final engine = <String, List<(String, double, double, double)>>{};
    for (final m in RegExp(r'\{"(\w+)",\s*\{((?:\{"\w+",\s*[-\d.]+,\s*[-\d.]+,\s*[-\d.]+\},?\s*)+)\}\}').allMatches(block)) {
      engine[m[1]!] = [
        for (final p in RegExp(r'\{"(\w+)",\s*([-\d.]+),\s*([-\d.]+),\s*([-\d.]+)\}').allMatches(m[2]!))
          (p[1]!, double.parse(p[2]!), double.parse(p[3]!), double.parse(p[4]!)),
      ];
    }
    expect(engine.keys.toSet(), {for (final s in effectCatalog) s.type});
    expect(engine.length, effectCatalog.length);
    for (final s in effectCatalog) {
      expect([for (final p in s.params) (p.name, p.min, p.max, p.defaultValue)], engine[s.type], reason: s.type);
    }
    // Looks and transitions in the same order as the engine.
    expect(src, contains('{"teal_orange", "warm", "cool", "vintage", "noir", "vivid", "bleach", "matte"}'));
    expect(filterLooks, ['teal_orange', 'warm', 'cool', 'vintage', 'noir', 'vivid', 'bleach', 'matte']);
    for (final t in transitionCatalog) {
      expect(src, contains('{"${t.type}", TransitionKind::${t.type}}'), reason: t.type);
    }
    // Every look preset uses known effects with in-range values.
    for (final look in lookPresets) {
      for (final (type, params) in look.effects) {
        final spec = effectSpec(type);
        expect(spec, isNotNull, reason: '${look.id}: $type');
        for (final e in params.entries) {
          final p = spec!.param(e.key)!;
          expect(e.value, inInclusiveRange(p.min, p.max), reason: '${look.id}: $type.${e.key}');
        }
      }
    }
  });

  group('effects on a clip', () {
    test('add, edit, enable/disable, reorder and remove', () {
      final ids = counter();
      var p = twoClips();
      p = p.addEffects('a', [newEffect('brightness', ids()), newEffect('vignette', ids())]);
      p = p.addEffects('a', [newEffect('sepia', ids())], index: 0);
      expect([for (final e in clip(p, 'a').effects) e.type], ['sepia', 'brightness', 'vignette']);
      p = p.updateEffect('a', 'e1', params: {'amount': 0.4});
      expect(effectParam(clip(p, 'a').effects[1], 'amount'), 0.4);
      p = p.updateEffect('a', 'e1', params: {'amount': 7});
      expect(effectParam(clip(p, 'a').effects[1], 'amount'), 1, reason: 'clamped to the range');
      p = p.updateEffect('a', 'e2', enabled: false);
      expect(clip(p, 'a').effects[2].enabled, isFalse);
      expect(effectRenders(clip(p, 'a').effects[2]), isFalse);
      p = p.moveEffect('a', 'e2', 0);
      expect([for (final e in clip(p, 'a').effects) e.id], ['e2', 'e3', 'e1']);
      p = p.removeEffect('a', 'e3');
      expect([for (final e in clip(p, 'a').effects) e.id], ['e2', 'e1']);
      p = valid(p);
      expect(clip(p, 'a').effects.first.enabled, isFalse, reason: 'saved and read back');
      expect(effectParam(clip(p, 'a').effects.last, 'amount'), 1);
      expect(clip(p, 'b').effects, isEmpty, reason: 'other clips untouched');
    });

    test('looks replace the stack; copying gives every clip its own ids', () {
      final ids = counter();
      var p = twoClips();
      final cinematic = lookPresets.firstWhere((l) => l.id == 'cinematic');
      p = p.setEffects('a', cinematic.build(ids));
      expect([for (final e in clip(p, 'a').effects) e.type], ['filter', 'contrast', 'vignette']);
      p = p.copyEffects('a', ['a', 'b', 'c', 'd'], ids);
      expect(clip(p, 'b').effects.length, 3);
      expect(clip(p, 'c').effects.length, 3, reason: 'photos take effects too');
      expect(clip(p, 'b').effects.first.id, isNot(clip(p, 'a').effects.first.id));
      p = p.setEffects('a', const []);
      expect(clip(p, 'a').effects, isEmpty);
      valid(p);
    });

    test('effects stay with both halves of a split; audio clips take none', () {
      final ids = counter();
      var p = twoClips().addEffects('a', [newEffect('grayscale', ids())]);
      final (split, right) = p.split(2 * tps, ids, clipIds: ['a']);
      expect(clip(split, 'a').effects.single.type, 'grayscale');
      expect(clip(split, right.single).effects.single.type, 'grayscale');
      final withAudio = p.copyWith(tracks: [
        for (final t in p.tracks)
          if (t.id == 'a1') t.copyWith(clips: const [Clip(id: 'snd', mediaId: 'game', startTicks: 0, durationTicks: tps)]) else t,
      ]);
      expect(() => withAudio.addEffects('snd', [newEffect('blur', ids())]), throwsA(isA<EditException>()));
    });

    test('effects from older or newer files are kept as they are', () {
      const odd = Effect(id: 'x', type: 'color.basic', params: {'brightness': 0.1});
      var p = twoClips();
      p = p.addEffects('a', [odd]);
      p = valid(p);
      expect(clip(p, 'a').effects.single.type, 'color.basic');
      expect(clip(p, 'a').effects.single.params, {'brightness': 0.1});
      expect(effectRenders(clip(p, 'a').effects.single), isFalse, reason: 'not drawn, not lost');
    });
  });

  group('video fades', () {
    test('snapped to frames and fitted in the clip; split keeps the outer ones', () {
      final ids = counter();
      var p = twoClips().setVideoFades('a', fadeInTicks: tps + 1234, fadeOutTicks: 2 * tps);
      expect(clip(p, 'a').videoFadeInTicks, tps);
      expect(clip(p, 'a').videoFadeOutTicks, 2 * tps);
      p = p.setVideoFades('a', fadeInTicks: 4 * tps);
      expect(clip(p, 'a').videoFadeInTicks + clip(p, 'a').videoFadeOutTicks, 5 * tps);
      p = twoClips().setVideoFades('a', fadeInTicks: tps, fadeOutTicks: tps);
      final (sp, right) = p.split(2 * tps, ids, clipIds: ['a']);
      expect(clip(sp, 'a').videoFadeInTicks, tps);
      expect(clip(sp, 'a').videoFadeOutTicks, 0);
      expect(clip(sp, right.single).videoFadeInTicks, 0);
      expect(clip(sp, right.single).videoFadeOutTicks, tps);
      p = valid(p.trimEnd('a', tps ~/ 2));
      expect(clip(p, 'a').videoFadeInTicks + clip(p, 'a').videoFadeOutTicks, lessThanOrEqualTo(clip(p, 'a').durationTicks));
    });
  });

  group('transitions', () {
    test('need the clip right before on the same track', () {
      final p = twoClips();
      expect(p.clipBefore('b')!.id, 'a');
      expect(p.clipBefore('a'), isNull);
      expect(p.clipBefore('d'), isNull, reason: 'gap before it');
      expect(() => p.setTransition('a', const Transition(type: 'dissolve', durationTicks: tps)), throwsA(isA<EditException>()));
      expect(() => p.setTransition('d', const Transition(type: 'dissolve', durationTicks: tps)), throwsA(isA<EditException>()));
      expect(() => p.setTransition('b', const Transition(type: 'spin', durationTicks: tps)), throwsA(isA<EditException>()));
    });

    test('centred on the cut, snapped to frames, at least two frames, and saved', () {
      var p = twoClips();
      p = p.setTransition('b', const Transition(type: 'wipe', durationTicks: tps + 777, direction: 'up'));
      final tr = clip(p, 'b').transitionIn!;
      expect(tr.durationTicks, tps);
      expect(tr.direction, 'up');
      final span = p.transitionInto('b')!;
      expect((span.left, span.right), (tps ~/ 2, tps ~/ 2));
      expect(span.spec.directional, isTrue);
      p = p.setTransition('b', tr.copyWith(durationTicks: 1));
      expect(clip(p, 'b').transitionIn!.durationTicks, 2 * p.frameTicks);
      p = valid(p.setTransition('b', const Transition(type: 'zoom_in', durationTicks: 2 * tps)));
      expect(clip(p, 'b').transitionIn, const Transition(type: 'zoom_in', durationTicks: 2 * tps));
      p = p.setTransition('b', null);
      expect(clip(p, 'b').transitionIn, isNull);
    });

    test('at most half of each clip; overlaps stop where the media runs out', () {
      // B starts at the very beginning of its file: no media before the cut.
      var p = twoClips(bIn: 0);
      p = p.setTransition('b', const Transition(type: 'dissolve', durationTicks: 2 * tps));
      final span = p.transitionInto('b')!;
      expect(span.left, 0, reason: 'nothing of B before its in-point');
      expect(span.right, tps);
      // Dips need no extra media: the whole length plays.
      p = p.setTransition('b', const Transition(type: 'dip_black', durationTicks: 2 * tps));
      expect((p.transitionInto('b')!.left, p.transitionInto('b')!.right), (tps, tps));
      // Longer than the clips allow: capped at half of each clip.
      p = twoClips().setTransition('b', const Transition(type: 'dissolve', durationTicks: 30 * tps));
      expect(clip(p, 'b').transitionIn!.durationTicks, 5 * tps);
      expect(p.transitionInto('b')!.durationTicks, 5 * tps);
      // A short clip whose file ends right at its out-point, before a photo.
      final q = p.copyWith(tracks: [
        p.tracks[0].copyWith(clips: const [
          Clip(id: 's', mediaId: 'short', startTicks: 0, durationTicks: 6 * tps),
          Clip(id: 'ph', mediaId: 'photo', startTicks: 6 * tps, durationTicks: 3 * tps),
        ]),
        ...p.tracks.skip(1),
      ]);
      expect(() => q.setTransition('ph', const Transition(type: 'dissolve', durationTicks: tps)), returnsNormally,
          reason: 'the photo has no in-point limit');
      final qs = q.setTransition('ph', const Transition(type: 'dissolve', durationTicks: tps));
      expect(qs.transitionInto('ph')!.right, 0, reason: 'the short file has no frames after its end');
      expect(qs.transitionInto('ph')!.left, tps ~/ 2);
    });

    test('a transition that cannot play is reported, not drawn', () {
      final p = twoClips(aIn: 0, bIn: 0).copyWith(media: const [
        MediaRef(id: 'game', kind: MediaKind.video, uri: '/g.mp4', displayName: 'g.mp4', durationTicks: 5 * tps, hasAudio: true),
        MediaRef(id: 'short', kind: MediaKind.video, uri: '/s.mp4', displayName: 's.mp4', durationTicks: 6 * tps, hasAudio: true),
        MediaRef(id: 'photo', kind: MediaKind.image, uri: '/p.png', displayName: 'p.png', durationTicks: 0),
      ]);
      expect(() => p.setTransition('b', const Transition(type: 'dissolve', durationTicks: tps)), throwsA(isA<EditException>()));
      expect(p.setTransition('b', const Transition(type: 'dip_white', durationTicks: tps)).transitionInto('b')!.active, isTrue);
    });

    test('moving a clip away keeps its transition but it stops playing', () {
      final ids = counter();
      var p = twoClips().setTransition('b', const Transition(type: 'dissolve', durationTicks: tps));
      p = p.moveClip('b', 14 * tps, ids);
      expect(clip(p, 'b').transitionIn, isNotNull);
      expect(p.transitionInto('b'), isNull);
    });

    test('older names and version 3 files still open', () {
      final p = twoClips().copyWith(tracks: [
        twoClips().tracks[0].copyWith(clips: [
          ...twoClips().tracks[0].clips.take(1),
          twoClips().tracks[0].clips[1].copyWith(transitionIn: const Transition(type: 'crossfade', durationTicks: tps)),
        ]),
        ...twoClips().tracks.skip(1),
      ]);
      expect(p.transitionInto('b')!.spec.type, 'dissolve');
      final v3 = const ProjectCodec().encode(p).replaceFirst('"formatVersion": $currentFormatVersion', '"formatVersion": 3');
      expect(currentFormatVersion, 4);
      final back = const ProjectCodec().decode(v3);
      expect(clip(back, 'b').transitionIn!.type, 'crossfade');
      expect(clip(back, 'b').transitionIn!.direction, 'left');
      expect(clip(back, 'a').videoFadeInTicks, 0);
    });
  });
}
