import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:cutlab_project_format/cutlab_project_format.dart' as pf show Clip;
import 'package:flutter/material.dart';

import '../editor/editor_controller.dart';
import '../format.dart';
import '../theme.dart';
import 'timeline_actions.dart';
import 'timeline_state.dart';

/// Effects, video fades and the transition into the selected clip.
///
/// Beginner mode: ready-made looks, four quick sliders, transition type and
/// a few durations. Advanced mode: the full effect stack (add, reorder,
/// enable/disable, remove, every parameter), frame-exact fades and
/// transition timing. Every change is rendered by the engine for the
/// preview and the export alike; dragging a slider shows the result live
/// and the whole drag is one undo step.
class EffectsPanel extends StatelessWidget {
  const EffectsPanel({super.key, required this.controller, required this.state, required this.actions});

  final EditorController controller;
  final TimelineState state;
  final TimelineActions actions;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, state]),
      builder: (context, _) {
        final p = controller.project;
        final pc = actions.visual;
        if (pc == null) {
          return const Center(
            key: Key('fxPanelEmpty'),
            child: Padding(
              padding: EdgeInsets.all(CutlabSpacing.lg),
              child: Text('Select one video or photo clip to add effects and transitions.',
                  textAlign: TextAlign.center, style: TextStyle(color: CutlabColors.textMuted, fontSize: 12)),
            ),
          );
        }
        final advanced = p.editorMode == EditorMode.advanced;
        final c = pc.clip;
        return ListView(
          key: const Key('fxPanel'),
          padding: const EdgeInsets.all(CutlabSpacing.md),
          children: [
            const _Header('Look'),
            _Looks(clip: c, actions: actions),
            const SizedBox(height: CutlabSpacing.md),
            if (!advanced) ...[
              const _Header('Adjust'),
              for (final q in _quick) _QuickSlider(key: ValueKey('quick-${q.$1}-${c.id}'), clip: c, spec: q, actions: actions),
            ] else
              _Stack(clip: c, actions: actions),
            const Divider(height: CutlabSpacing.xl),
            const _Header('Fade from / to black'),
            _Fades(project: p, clip: c, actions: actions, advanced: advanced),
            const Divider(height: CutlabSpacing.xl),
            const _Header('Transition from the previous clip'),
            _TransitionEditor(project: p, clip: c, actions: actions, advanced: advanced),
          ],
        );
      },
    );
  }
}

/// Beginner quick sliders: (effect type, parameter, label).
const _quick = [
  ('brightness', 'amount', 'Brightness'),
  ('contrast', 'amount', 'Contrast'),
  ('saturation', 'amount', 'Saturation'),
  ('temperature', 'amount', 'Warmth'),
];

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: CutlabSpacing.xs),
        child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CutlabColors.textMuted)),
      );
}

class _Looks extends StatelessWidget {
  const _Looks({required this.clip, required this.actions});
  final pf.Clip clip;
  final TimelineActions actions;

  @override
  Widget build(BuildContext context) {
    final effects = clip.effects;
    return Wrap(
      spacing: CutlabSpacing.xs,
      runSpacing: CutlabSpacing.xs,
      children: [
        ChoiceChip(
          key: const Key('lookNone'),
          label: const Text('None'),
          selected: effects.isEmpty,
          onSelected: (_) => actions.applyLook(null),
        ),
        for (final look in lookPresets)
          ChoiceChip(
            key: Key('look-${look.id}'),
            label: Text(look.label),
            selected: _matches(effects, look),
            onSelected: (_) => actions.applyLook(look),
          ),
      ],
    );
  }

  static bool _matches(List<Effect> effects, LookPreset look) {
    if (effects.length != look.effects.length) return false;
    for (var i = 0; i < effects.length; i++) {
      if (effects[i].type != look.effects[i].$1) return false;
    }
    return true;
  }
}

/// A slider that reports while dragging (live preview) and once at the end.
class _LiveSlider extends StatefulWidget {
  const _LiveSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.format,
    required this.onLive,
    required this.onEnd,
    this.divisions,
    this.enabled = true,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String Function(double v) format;
  final ValueChanged<double> onLive;
  final ValueChanged<double> onEnd;
  final bool enabled;

  @override
  State<_LiveSlider> createState() => _LiveSliderState();
}

class _LiveSliderState extends State<_LiveSlider> {
  late double _v = widget.value;
  bool _dragging = false;

  @override
  void didUpdateWidget(_LiveSlider old) {
    super.didUpdateWidget(old);
    if (!_dragging && old.value != widget.value) _v = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    final lo = widget.min, hi = widget.max > widget.min ? widget.max : widget.min + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: Text(widget.label, style: const TextStyle(fontSize: 12))),
          Text(widget.format(_v), style: const TextStyle(fontSize: 12, color: CutlabColors.textMuted, fontFeatures: [FontFeature.tabularFigures()])),
        ]),
        SizedBox(
          height: 32,
          child: Slider(
            value: _v.clamp(lo, hi),
            min: lo,
            max: hi,
            divisions: widget.divisions,
            onChangeStart: (_) => _dragging = true,
            onChanged: widget.enabled && widget.max > widget.min
                ? (v) {
                    setState(() => _v = v);
                    widget.onLive(v);
                  }
                : null,
            onChangeEnd: (v) {
              _dragging = false;
              widget.onEnd(v);
            },
          ),
        ),
      ],
    );
  }
}

String _signed(double v) => v == 0 ? '0' : '${v > 0 ? '+' : '−'}${(v.abs() * 100).round()}';

class _QuickSlider extends StatelessWidget {
  const _QuickSlider({super.key, required this.clip, required this.spec, required this.actions});
  final pf.Clip clip;
  final (String, String, String) spec;
  final TimelineActions actions;

  @override
  Widget build(BuildContext context) {
    final (type, param, label) = spec;
    final e = clip.effects.where((e) => e.type == type && e.enabled).firstOrNull;
    final value = e == null ? 0.0 : effectParam(e, param);
    final p = effectSpec(type)!.param(param)!;
    return _LiveSlider(
      key: Key('quick-$type'),
      label: label,
      value: value,
      min: p.min,
      max: p.max,
      divisions: 40,
      format: _signed,
      onLive: (v) => actions.setQuickAdjust(type, param, v, commit: false),
      onEnd: (v) => actions.setQuickAdjust(type, param, v),
    );
  }
}

/// Advanced: the clip's effect stack.
class _Stack extends StatelessWidget {
  const _Stack({required this.clip, required this.actions});
  final pf.Clip clip;
  final TimelineActions actions;

  @override
  Widget build(BuildContext context) {
    final effects = clip.effects;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(child: _Header('Effects (${effects.length}) · applied top to bottom')),
          PopupMenuButton<String>(
            key: const Key('fxAdd'),
            tooltip: 'Add effect',
            icon: const Icon(Icons.add_circle_outline, size: 20, color: CutlabColors.accent),
            onSelected: actions.addEffect,
            itemBuilder: (_) => [
              for (final g in EffectGroup.values) ...[
                PopupMenuItem<String>(enabled: false, height: 28, child: Text(_groupName(g), style: const TextStyle(fontSize: 11))),
                for (final s in effectCatalog.where((s) => s.group == g))
                  PopupMenuItem<String>(key: Key('fxAddItem-${s.type}'), value: s.type, height: 36, child: Text(s.label)),
              ],
            ],
          ),
          PopupMenuButton<String>(
            key: const Key('fxMore'),
            tooltip: 'More',
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (v) {
              if (v == 'copy') actions.copyEffectsToTrack();
              if (v == 'clear') actions.applyLook(null);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'copy', child: Text('Copy these effects to the whole track')),
              PopupMenuItem(value: 'clear', child: Text('Remove all effects')),
            ],
          ),
        ]),
        if (effects.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: CutlabSpacing.sm),
            child: Text('No effects. Pick a look above or add effects with +.', style: TextStyle(fontSize: 12, color: CutlabColors.textMuted)),
          ),
        for (var i = 0; i < effects.length; i++)
          _EffectCard(key: ValueKey('fx-${effects[i].id}'), effect: effects[i], index: i, count: effects.length, actions: actions),
      ],
    );
  }

  static String _groupName(EffectGroup g) => switch (g) {
        EffectGroup.light => 'LIGHT',
        EffectGroup.color => 'COLOUR',
        EffectGroup.detail => 'DETAIL',
        EffectGroup.style => 'STYLE',
      };
}

class _EffectCard extends StatefulWidget {
  const _EffectCard({super.key, required this.effect, required this.index, required this.count, required this.actions});
  final Effect effect;
  final int index;
  final int count;
  final TimelineActions actions;

  @override
  State<_EffectCard> createState() => _EffectCardState();
}

class _EffectCardState extends State<_EffectCard> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final e = widget.effect;
    final spec = effectSpec(e.type);
    final a = widget.actions;
    return Container(
      margin: const EdgeInsets.only(bottom: CutlabSpacing.xs),
      decoration: BoxDecoration(
        color: CutlabColors.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: e.enabled ? CutlabColors.outline : CutlabColors.surfaceRaised),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Switch(
              key: Key('fxToggle-${e.id}'),
              value: e.enabled,
              onChanged: spec == null ? null : (v) => a.setEffectEnabled(e.id, v),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            Expanded(
              child: InkWell(
                onTap: () => setState(() => _open = !_open),
                child: Text(spec?.label ?? '${e.type} (not supported by this version)',
                    style: TextStyle(fontSize: 13, color: e.enabled ? CutlabColors.text : CutlabColors.textMuted)),
              ),
            ),
            IconButton(
              key: Key('fxUp-${e.id}'),
              tooltip: 'Earlier',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.arrow_upward, size: 16),
              onPressed: widget.index > 0 ? () => a.moveEffect(e.id, widget.index - 1) : null,
            ),
            IconButton(
              key: Key('fxDown-${e.id}'),
              tooltip: 'Later',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.arrow_downward, size: 16),
              onPressed: widget.index < widget.count - 1 ? () => a.moveEffect(e.id, widget.index + 1) : null,
            ),
            IconButton(
              key: Key('fxRemove-${e.id}'),
              tooltip: 'Remove',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 16),
              onPressed: () => a.removeEffect(e.id),
            ),
          ]),
          if (_open && spec != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(CutlabSpacing.sm, 0, CutlabSpacing.sm, CutlabSpacing.xs),
              child: Column(
                children: [
                  for (final prm in spec.params)
                    if (e.type == 'filter' && prm.name == 'look')
                      _LookPicker(effect: e, actions: a)
                    else
                      _LiveSlider(
                        key: Key('fxParam-${e.id}-${prm.name}'),
                        label: prm.label,
                        value: effectParam(e, prm.name),
                        min: prm.min,
                        max: prm.max,
                        enabled: e.enabled,
                        format: (v) => _paramText(prm, v),
                        onLive: (v) => a.setEffectParams(e.id, {prm.name: v}, commit: false),
                        onEnd: (v) => a.setEffectParams(e.id, {prm.name: v}),
                      ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _paramText(EffectParam p, double v) {
    if (p.unit == '× height') return '${(v * 100).toStringAsFixed(2)}% of height';
    if (p.unit == 'EV') return '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)} EV';
    return v.toStringAsFixed(2);
  }
}

class _LookPicker extends StatelessWidget {
  const _LookPicker({required this.effect, required this.actions});
  final Effect effect;
  final TimelineActions actions;

  @override
  Widget build(BuildContext context) {
    final current = effectParam(effect, 'look').round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: CutlabSpacing.xs),
      child: Wrap(
        spacing: CutlabSpacing.xs,
        runSpacing: CutlabSpacing.xs,
        children: [
          for (var i = 0; i < filterLooks.length; i++)
            ChoiceChip(
              key: Key('fxLook-${effect.id}-${filterLooks[i]}'),
              visualDensity: VisualDensity.compact,
              label: Text(filterLookLabels[filterLooks[i]]!, style: const TextStyle(fontSize: 11)),
              selected: current == i,
              onSelected: effect.enabled ? (_) => actions.setEffectParams(effect.id, {'look': i.toDouble()}) : null,
            ),
        ],
      ),
    );
  }
}

class _Fades extends StatelessWidget {
  const _Fades({required this.project, required this.clip, required this.actions, required this.advanced});
  final Project project;
  final pf.Clip clip;
  final TimelineActions actions;
  final bool advanced;

  @override
  Widget build(BuildContext context) {
    final dur = clip.durationTicks;
    final max = (dur ~/ 2).clamp(0, 10 * ticksPerSecond).toDouble();
    String text(double v) => advanced ? formatTimecode(v.round(), project.fps) : '${(v / ticksPerSecond).toStringAsFixed(1)} s';
    return Column(children: [
      _LiveSlider(
        key: const Key('vfadeIn'),
        label: 'Fade in',
        value: clip.videoFadeInTicks.toDouble().clamp(0.0, max),
        min: 0,
        max: max,
        format: text,
        onLive: (v) => actions.setVideoFades(fadeIn: v.round(), commit: false),
        onEnd: (v) => actions.setVideoFades(fadeIn: v.round()),
      ),
      _LiveSlider(
        key: const Key('vfadeOut'),
        label: 'Fade out',
        value: clip.videoFadeOutTicks.toDouble().clamp(0.0, max),
        min: 0,
        max: max,
        format: text,
        onLive: (v) => actions.setVideoFades(fadeOut: v.round(), commit: false),
        onEnd: (v) => actions.setVideoFades(fadeOut: v.round()),
      ),
    ]);
  }
}

class _TransitionEditor extends StatelessWidget {
  const _TransitionEditor({required this.project, required this.clip, required this.actions, required this.advanced});
  final Project project;
  final pf.Clip clip;
  final TimelineActions actions;
  final bool advanced;

  @override
  Widget build(BuildContext context) {
    final id = clip.id;
    final before = project.clipBefore(id);
    if (before == null) {
      return const Text('Put this clip right after another clip on the same track (no gap) to add a transition between them.',
          key: Key('trNoCut'), style: TextStyle(fontSize: 12, color: CutlabColors.textMuted));
    }
    final tr = clip.transitionIn;
    final current = tr == null ? null : transitionSpec(tr.type);
    final span = project.transitionInto(id);
    final pc = project.find(id)!;
    final index = pc.track.clips.indexWhere((c) => c.id == id);
    final type = current?.type ?? 'dissolve';
    final max = maxTransitionTicks(project, pc.track, index, type);
    final fps = project.fps;
    final minD = 2 * project.frameTicks;
    final maxD = max > minD ? max : minD;
    String text(int t) => advanced ? '${formatTimecode(t, fps)} (${(t / project.frameTicks).round()} frames)' : '${(t / ticksPerSecond).toStringAsFixed(2)} s';
    final duration = tr?.durationTicks ?? ticksPerSecond;
    final t = tr ?? Transition(type: type, durationTicks: duration);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: CutlabSpacing.xs,
          runSpacing: CutlabSpacing.xs,
          children: [
            ChoiceChip(key: const Key('trNone'), label: const Text('None'), selected: current == null, onSelected: (_) => actions.setTransition(null)),
            for (final s in transitionCatalog)
              ChoiceChip(
                key: Key('trType-${s.type}'),
                label: Text(s.label),
                selected: current?.type == s.type,
                onSelected: (_) => actions.setTransition(
                    Transition(type: s.type, durationTicks: tr?.durationTicks ?? ticksPerSecond, direction: tr?.direction ?? 'left')),
              ),
          ],
        ),
        if (current != null) ...[
          const SizedBox(height: CutlabSpacing.sm),
          if (current.directional)
            SegmentedButton<String>(
              key: const Key('trDirection'),
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: 'left', icon: Icon(Icons.arrow_back, size: 16), tooltip: 'Left'),
                ButtonSegment(value: 'right', icon: Icon(Icons.arrow_forward, size: 16), tooltip: 'Right'),
                ButtonSegment(value: 'up', icon: Icon(Icons.arrow_upward, size: 16), tooltip: 'Up'),
                ButtonSegment(value: 'down', icon: Icon(Icons.arrow_downward, size: 16), tooltip: 'Down'),
              ],
              selected: {t.direction},
              onSelectionChanged: (v) => actions.setTransition(t.copyWith(direction: v.first)),
            ),
          const SizedBox(height: CutlabSpacing.xs),
          if (!advanced)
            Wrap(spacing: CutlabSpacing.xs, children: [
              for (final ms in const [250, 500, 1000, 2000])
                ChoiceChip(
                  key: Key('trDur-$ms'),
                  label: Text('${ms / 1000} s'),
                  selected: (duration - ms * ticksPerSecond ~/ 1000).abs() < project.frameTicks,
                  onSelected: max >= ms * ticksPerSecond ~/ 1000 || ms == 250
                      ? (_) => actions.setTransition(t.copyWith(durationTicks: ms * ticksPerSecond ~/ 1000))
                      : null,
                ),
            ])
          else
            _LiveSlider(
              key: const Key('trDuration'),
              label: 'Duration',
              value: duration.toDouble().clamp(minD.toDouble(), maxD.toDouble()),
              min: minD.toDouble(),
              max: maxD.toDouble(),
              format: (v) => text(v.round()),
              onLive: (v) => actions.setTransition(t.copyWith(durationTicks: v.round()), commit: false),
              onEnd: (v) => actions.setTransition(t.copyWith(durationTicks: v.round())),
            ),
          if (span != null && span.active)
            Text(
              'Plays ${text(span.durationTicks)}: ${text(span.left)} before the cut, ${text(span.right)} after'
              '${span.durationTicks < duration ? ' (shortened: not enough media beyond the cut)' : ''}',
              key: const Key('trSpan'),
              style: const TextStyle(fontSize: 11, color: CutlabColors.textMuted),
            )
          else
            const Text('Does not play: no media beyond the cut for this type. Trim the clips or choose a dip.',
                key: Key('trInactive'), style: TextStyle(fontSize: 11, color: CutlabColors.danger)),
          if (advanced) const Text('Tip: drag the ends of the transition on the timeline.', style: TextStyle(fontSize: 11, color: CutlabColors.textMuted)),
        ],
      ],
    );
  }
}
