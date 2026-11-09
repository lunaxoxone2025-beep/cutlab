/// Picture effects and transitions: the catalogue (types, parameters,
/// ranges, defaults — identical to the engine's, core/src/media/effects.cpp),
/// ready-made looks for beginner mode, and how a transition's duration is
/// shared between the two clips it joins.
library;

import 'model.dart';
import 'time.dart';
import 'timeline.dart';

/// One adjustable value of an effect.
class EffectParam {
  const EffectParam(this.name, this.label, this.min, this.max, this.defaultValue, {this.unit = '', this.integer = false});

  final String name;
  final String label;
  final double min;
  final double max;
  final double defaultValue;
  final String unit;

  /// Whole numbers only (filter look).
  final bool integer;

  double clamp(double v) {
    final c = v.isFinite ? v.clamp(min, max).toDouble() : defaultValue;
    return integer ? c.roundToDouble() : c;
  }
}

enum EffectGroup { light, color, detail, style }

class EffectSpec {
  const EffectSpec(this.type, this.label, this.group, this.params, {this.description = ''});

  final String type;
  final String label;
  final EffectGroup group;
  final List<EffectParam> params;
  final String description;

  EffectParam? param(String name) => params.where((p) => p.name == name).firstOrNull;
}

/// The filter looks, in the engine's order (param look = index).
const List<String> filterLooks = ['teal_orange', 'warm', 'cool', 'vintage', 'noir', 'vivid', 'bleach', 'matte'];
const Map<String, String> filterLookLabels = {
  'teal_orange': 'Teal & orange',
  'warm': 'Warm',
  'cool': 'Cool',
  'vintage': 'Vintage',
  'noir': 'Noir',
  'vivid': 'Vivid',
  'bleach': 'Bleach bypass',
  'matte': 'Matte',
};

const _amount = EffectParam('amount', 'Amount', -1, 1, 0);

/// Every effect the engine renders (same names, ranges and defaults).
const List<EffectSpec> effectCatalog = [
  EffectSpec('brightness', 'Brightness', EffectGroup.light, [_amount], description: 'Lighter or darker overall'),
  EffectSpec('contrast', 'Contrast', EffectGroup.light, [_amount], description: 'Distance between darks and brights'),
  EffectSpec('exposure', 'Exposure', EffectGroup.light, [EffectParam('stops', 'Stops', -3, 3, 0, unit: 'EV')],
      description: 'Like opening or closing the lens'),
  EffectSpec('gamma', 'Gamma', EffectGroup.light, [EffectParam('value', 'Gamma', 0.2, 5, 1)], description: 'Mid-tone brightness'),
  EffectSpec('highlights', 'Highlights', EffectGroup.light, [_amount], description: 'Bright areas only'),
  EffectSpec('shadows', 'Shadows', EffectGroup.light, [_amount], description: 'Dark areas only'),
  EffectSpec('saturation', 'Saturation', EffectGroup.color, [_amount], description: 'Colour intensity'),
  EffectSpec('vibrance', 'Vibrance', EffectGroup.color, [_amount], description: 'Boosts dull colours more than strong ones'),
  EffectSpec('temperature', 'Temperature', EffectGroup.color, [_amount], description: 'Cooler (blue) or warmer (orange)'),
  EffectSpec('tint', 'Tint', EffectGroup.color, [_amount], description: 'Green or magenta'),
  EffectSpec(
      'rgb',
      'RGB',
      EffectGroup.color,
      [
        EffectParam('red', 'Red', 0, 2, 1),
        EffectParam('green', 'Green', 0, 2, 1),
        EffectParam('blue', 'Blue', 0, 2, 1),
        EffectParam('red_offset', 'Red offset', -0.5, 0.5, 0),
        EffectParam('green_offset', 'Green offset', -0.5, 0.5, 0),
        EffectParam('blue_offset', 'Blue offset', -0.5, 0.5, 0),
      ],
      description: 'Gain and offset per channel'),
  EffectSpec('sharpen', 'Sharpen', EffectGroup.detail,
      [EffectParam('amount', 'Amount', 0, 3, 0.6), EffectParam('radius', 'Radius', 0.0005, 0.01, 0.0015, unit: '× height')],
      description: 'Crisper edges'),
  EffectSpec('blur', 'Blur', EffectGroup.detail, [EffectParam('radius', 'Radius', 0, 0.05, 0.006, unit: '× height')],
      description: 'Soft picture'),
  EffectSpec(
      'vignette',
      'Vignette',
      EffectGroup.style,
      [
        EffectParam('amount', 'Amount', 0, 1, 0.5),
        EffectParam('size', 'Size', 0.2, 1.5, 0.75),
        EffectParam('softness', 'Softness', 0.05, 1, 0.45),
      ],
      description: 'Darker corners'),
  EffectSpec('grayscale', 'Grayscale', EffectGroup.style, [EffectParam('amount', 'Amount', 0, 1, 1)], description: 'Shades of gray'),
  EffectSpec('black_white', 'Black & white', EffectGroup.style,
      [EffectParam('threshold', 'Threshold', 0, 1, 0.5), EffectParam('softness', 'Softness', 0, 0.5, 0.04)],
      description: 'Two tones only'),
  EffectSpec('sepia', 'Sepia', EffectGroup.style, [EffectParam('amount', 'Amount', 0, 1, 1)], description: 'Old photo brown'),
  EffectSpec('filter', 'Colour filter', EffectGroup.style,
      [EffectParam('look', 'Look', 0, 7, 0, integer: true), EffectParam('amount', 'Strength', 0, 1, 1)],
      description: 'Cinematic colour looks'),
];

EffectSpec? effectSpec(String type) => effectCatalog.where((s) => s.type == type).firstOrNull;

/// The value of [name] in [e] (its default when missing or not a number),
/// clamped to the parameter's range.
double effectParam(Effect e, String name) {
  final p = effectSpec(e.type)?.param(name);
  final v = e.params[name];
  final d = v is num ? v.toDouble() : (p?.defaultValue ?? 0);
  return p == null ? d : p.clamp(d);
}

/// A new effect of [type] with default values.
Effect newEffect(String type, String id, {Map<String, double> params = const {}}) {
  final spec = effectSpec(type);
  if (spec == null) throw ArgumentError.value(type, 'type', 'unknown effect');
  return Effect(id: id, type: type, params: {for (final p in spec.params) p.name: params[p.name] ?? p.defaultValue});
}

/// True when the engine will draw [e] (enabled and of a known type).
bool effectRenders(Effect e) => e.enabled && effectSpec(e.type) != null;

// ------------------------------------------------------------------ looks

/// A ready-made look: a list of effects (type + values) applied together.
class LookPreset {
  const LookPreset(this.id, this.label, this.effects);
  final String id;
  final String label;
  final List<(String, Map<String, double>)> effects;

  List<Effect> build(String Function() ids) => [for (final (type, p) in effects) newEffect(type, ids(), params: p)];
}

const List<LookPreset> lookPresets = [
  LookPreset('cinematic', 'Cinematic', [
    ('filter', {'look': 0, 'amount': 0.8}),
    ('contrast', {'amount': 0.15}),
    ('vignette', {'amount': 0.35, 'size': 0.8, 'softness': 0.5}),
  ]),
  LookPreset('vivid', 'Vivid', [
    ('vibrance', {'amount': 0.5}),
    ('contrast', {'amount': 0.1}),
    ('sharpen', {'amount': 0.4}),
  ]),
  LookPreset('warm', 'Warm', [
    ('temperature', {'amount': 0.35}),
    ('vibrance', {'amount': 0.15}),
  ]),
  LookPreset('cool', 'Cool', [
    ('temperature', {'amount': -0.35}),
    ('tint', {'amount': -0.05}),
  ]),
  LookPreset('vintage', 'Vintage', [
    ('filter', {'look': 3, 'amount': 1}),
    ('vignette', {'amount': 0.45}),
  ]),
  LookPreset('noir', 'Noir', [
    ('filter', {'look': 4, 'amount': 1}),
    ('vignette', {'amount': 0.5, 'size': 0.7}),
  ]),
  LookPreset('bw', 'Black & white', [
    ('grayscale', {'amount': 1}),
    ('contrast', {'amount': 0.1}),
  ]),
  LookPreset('sepia', 'Sepia', [
    ('sepia', {'amount': 0.85}),
  ]),
  LookPreset('matte', 'Matte', [
    ('filter', {'look': 7, 'amount': 1}),
  ]),
  LookPreset('punchy', 'Game punch', [
    ('vibrance', {'amount': 0.4}),
    ('contrast', {'amount': 0.2}),
    ('shadows', {'amount': 0.2}),
    ('sharpen', {'amount': 0.6}),
  ]),
];

// ------------------------------------------------------------ transitions

class TransitionSpec {
  const TransitionSpec(this.type, this.label, {this.directional = false, this.overlaps = true});

  final String type;
  final String label;

  /// Takes a direction (wipes and slides).
  final bool directional;

  /// Shows both clips at once, so it needs media beyond the cut (handles).
  final bool overlaps;
}

const List<TransitionSpec> transitionCatalog = [
  TransitionSpec('dissolve', 'Cross dissolve'),
  TransitionSpec('dip_black', 'Dip to black', overlaps: false),
  TransitionSpec('dip_white', 'Dip to white', overlaps: false),
  TransitionSpec('wipe', 'Wipe', directional: true),
  TransitionSpec('slide', 'Slide', directional: true),
  TransitionSpec('zoom_in', 'Zoom in'),
  TransitionSpec('zoom_out', 'Zoom out'),
  TransitionSpec('blur', 'Smooth blur'),
];

const List<String> transitionDirections = ['left', 'right', 'up', 'down'];

/// Older names kept readable.
const Map<String, String> _transitionAliases = {'crossfade': 'dissolve', 'cross_dissolve': 'dissolve'};

TransitionSpec? transitionSpec(String type) {
  final t = _transitionAliases[type] ?? type;
  return transitionCatalog.where((s) => s.type == t).firstOrNull;
}

/// How a transition into the clip at [index] of [track] actually plays:
/// [left] ticks before the cut and [right] after it. Each side is at most
/// half of its clip (so a clip's two transitions never overlap), and an
/// overlapping transition also stops where the media runs out (no frozen
/// frames). Zero when nothing plays (no transition, no adjacent clip, an
/// unknown type, or no media to overlap with).
class TransitionSpan {
  const TransitionSpan(this.spec, this.left, this.right, this.direction);

  final TransitionSpec spec;
  final int left;
  final int right;
  final String direction;

  int get durationTicks => left + right;
  bool get active => left + right > 0;
}

TransitionSpan? transitionSpan(Project p, Track track, int index) {
  if (index <= 0 || index >= track.clips.length) return null;
  if (track.kind != TrackKind.video && track.kind != TrackKind.image) return null;
  final b = track.clips[index];
  final a = track.clips[index - 1];
  final tr = b.transitionIn;
  if (tr == null || a.endTicks != b.startTicks) return null;
  final spec = transitionSpec(tr.type);
  if (spec == null) return null;
  final half = tr.durationTicks ~/ 2;
  var left = half;
  var right = tr.durationTicks - half;
  if (left > a.durationTicks ~/ 2) left = a.durationTicks ~/ 2;
  if (right > b.durationTicks ~/ 2) right = b.durationTicks ~/ 2;
  if (spec.overlaps) {
    // B is shown from before its in-point, A past its out-point.
    final mb = p.mediaById(b.mediaId);
    final ma = p.mediaById(a.mediaId);
    final bStill = mb?.kind == MediaKind.image;
    final aStill = ma?.kind == MediaKind.image;
    if (!bStill) left = left.clamp(0, b.sourceInTicks);
    if (!aStill) {
      final int room = ma == null || ma.durationTicks <= 0 ? 0 : ma.durationTicks - (a.sourceInTicks + a.sourceDurationTicks);
      right = right.clamp(0, room < 0 ? 0 : room);
    }
    // Speed changes are not rendered yet: no overlap for such clips.
    if (a.speed != Rational.one || b.speed != Rational.one) left = right = 0;
  }
  final dir = transitionDirections.contains(tr.direction) ? tr.direction : 'left';
  return TransitionSpan(spec, left, right, dir);
}

/// Longest transition the cut before [index] can take ([transitionSpan]
/// limits), for the duration controls.
int maxTransitionTicks(Project p, Track track, int index, String type) {
  if (index <= 0 || index >= track.clips.length) return 0;
  final b = track.clips[index];
  final probe = b.copyWith(transitionIn: Transition(type: type, durationTicks: 1 << 50));
  final clips = [...track.clips]..[index] = probe;
  final span = transitionSpan(p, track.copyWith(clips: clips), index);
  return span == null ? 0 : span.durationTicks;
}
