import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:flutter/material.dart';

import '../editor/editor_controller.dart';
import '../format.dart';
import '../theme.dart';
import 'timeline_actions.dart';
import 'timeline_state.dart';

/// Properties of the selected clip(s): timing, volume, fades, duration of
/// photos/titles, title text, and audio/video sync tools.
class ClipInspector extends StatelessWidget {
  const ClipInspector({super.key, required this.controller, required this.state, required this.actions});

  final EditorController controller;
  final TimelineState state;
  final TimelineActions actions;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, state]),
      builder: (context, _) {
        final p = controller.project;
        final ids = state.selection.where((id) => p.find(id) != null).toList();
        if (ids.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(CutlabSpacing.lg),
              child: Text('Select a clip on the timeline to edit it.',
                  textAlign: TextAlign.center, style: TextStyle(color: CutlabColors.textMuted, fontSize: 12)),
            ),
          );
        }
        if (ids.length > 1) return _multi(p, ids);
        return _single(context, p, p.find(ids.single)!);
      },
    );
  }

  Widget _multi(Project p, List<String> ids) {
    final clips = [for (final id in ids) p.find(id)!.clip];
    final audible = clips.where((c) => c.mediaId != null && (p.mediaById(c.mediaId)?.hasAudio ?? false)).toList();
    return ListView(
      padding: const EdgeInsets.all(CutlabSpacing.md),
      children: [
        Text('${ids.length} clips selected', style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: CutlabSpacing.md),
        if (audible.isNotEmpty)
          _VolumeSlider(
            key: ValueKey('vol-${ids.join()}'),
            value: audible.first.volume,
            onCommit: actions.setVolume,
          ),
        const SizedBox(height: CutlabSpacing.sm),
        Wrap(spacing: CutlabSpacing.sm, children: [
          OutlinedButton(onPressed: () => actions.nudge(-1), child: const Text('−1 frame')),
          OutlinedButton(onPressed: () => actions.nudge(1), child: const Text('+1 frame')),
        ]),
      ],
    );
  }

  Widget _single(BuildContext context, Project p, PlacedClip pc) {
    final c = pc.clip;
    final m = p.mediaById(c.mediaId);
    final kind = pc.track.kind;
    final fps = p.fps;
    final audible = kind == TrackKind.audio || (kind == TrackKind.video && (m?.hasAudio ?? false));
    final still = kind == TrackKind.image || kind == TrackKind.text;
    final maxFade = (c.durationTicks ~/ 2).clamp(0, 10 * ticksPerSecond);
    String tc(int t) => formatTimecode(t, fps);
    return ListView(
      padding: const EdgeInsets.all(CutlabSpacing.md),
      children: [
        Text(m?.displayName ?? (c.data['text'] as String? ?? 'Text'),
            maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
        Text('${pc.track.name}${pc.track.locked ? ' · locked' : ''}${c.linkId != null ? ' · linked' : ''}',
            style: const TextStyle(color: CutlabColors.textMuted, fontSize: 12)),
        const SizedBox(height: CutlabSpacing.sm),
        _row('Start', tc(c.startTicks)),
        _row('End', tc(c.endTicks)),
        _row('Duration', tc(c.durationTicks)),
        if (m != null && kind != TrackKind.image) _row('Source in', tc(c.sourceInTicks)),
        const Divider(height: CutlabSpacing.xl),
        if (kind == TrackKind.text) ...[
          _TextEditor(key: ValueKey('text-${c.id}'), initial: c.data['text'] as String? ?? '', onCommit: actions.setText),
          const SizedBox(height: CutlabSpacing.md),
        ],
        if (still) ...[
          const Text('Duration', style: TextStyle(fontSize: 12, color: CutlabColors.textMuted)),
          Wrap(
            spacing: CutlabSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton.outlined(
                key: const Key('durMinus'),
                icon: const Icon(Icons.remove),
                onPressed: () => actions.setDuration(c.durationTicks - ticksPerSecond),
              ),
              Text('${(c.durationTicks / ticksPerSecond).toStringAsFixed(2)} s'),
              IconButton.outlined(
                key: const Key('durPlus'),
                icon: const Icon(Icons.add),
                onPressed: () => actions.setDuration(c.durationTicks + ticksPerSecond),
              ),
            ],
          ),
          const SizedBox(height: CutlabSpacing.md),
        ],
        if (audible) ...[
          _VolumeSlider(key: ValueKey('vol-${c.id}'), value: c.volume, onCommit: actions.setVolume),
          _FadeSlider(
            key: ValueKey('fi-${c.id}'),
            label: 'Fade in',
            value: c.fadeInTicks.clamp(0, maxFade),
            max: maxFade,
            onCommit: (v) => actions.setFades(fadeIn: v),
          ),
          _FadeSlider(
            key: ValueKey('fo-${c.id}'),
            label: 'Fade out',
            value: c.fadeOutTicks.clamp(0, maxFade),
            max: maxFade,
            onCommit: (v) => actions.setFades(fadeOut: v),
          ),
          const SizedBox(height: CutlabSpacing.sm),
          const Text('Audio/video sync', style: TextStyle(fontSize: 12, color: CutlabColors.textMuted)),
          const SizedBox(height: CutlabSpacing.xs),
          if (c.linkId != null)
            Wrap(spacing: CutlabSpacing.sm, children: [
              const Text('Linked: moves together with its video/audio.', style: TextStyle(fontSize: 12)),
              TextButton(key: const Key('inspUnlink'), onPressed: actions.unlink, child: const Text('Unlink to adjust sync')),
            ])
          else ...[
            if (kind == TrackKind.video && (m?.hasAudio ?? false))
              OutlinedButton.icon(
                key: const Key('inspDetach'),
                onPressed: actions.detachAudio,
                icon: const Icon(Icons.call_split, size: 18),
                label: const Text('Separate audio'),
              ),
            Wrap(spacing: CutlabSpacing.sm, children: [
              OutlinedButton(key: const Key('nudgeBack'), onPressed: () => actions.nudge(-1), child: const Text('−1 frame')),
              OutlinedButton(key: const Key('nudgeFwd'), onPressed: () => actions.nudge(1), child: const Text('+1 frame')),
            ]),
          ],
        ],
      ],
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(label, style: const TextStyle(color: CutlabColors.textMuted, fontSize: 12))),
          Text(value, style: const TextStyle(fontSize: 12)),
        ]),
      );
}

/// Slider that shows its value while dragging and commits once (one undo step).
class _VolumeSlider extends StatefulWidget {
  const _VolumeSlider({super.key, required this.value, required this.onCommit});
  final double value;
  final ValueChanged<double> onCommit;

  @override
  State<_VolumeSlider> createState() => _VolumeSliderState();
}

class _VolumeSliderState extends State<_VolumeSlider> {
  late double _v = widget.value;

  @override
  void didUpdateWidget(_VolumeSlider old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _v = widget.value;
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Volume ${(_v * 100).round()}%', style: const TextStyle(fontSize: 12, color: CutlabColors.textMuted)),
          Slider(
            key: const Key('volumeSlider'),
            value: _v.clamp(0.0, 2.0),
            max: 2.0,
            divisions: 40,
            onChanged: (v) => setState(() => _v = v),
            onChangeEnd: widget.onCommit,
          ),
        ],
      );
}

class _FadeSlider extends StatefulWidget {
  const _FadeSlider({super.key, required this.label, required this.value, required this.max, required this.onCommit});
  final String label;
  final int value;
  final int max;
  final ValueChanged<int> onCommit;

  @override
  State<_FadeSlider> createState() => _FadeSliderState();
}

class _FadeSliderState extends State<_FadeSlider> {
  late double _v = widget.value.toDouble();

  @override
  void didUpdateWidget(_FadeSlider old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _v = widget.value.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final max = widget.max.toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${widget.label} ${(_v / ticksPerSecond).toStringAsFixed(2)} s',
            style: const TextStyle(fontSize: 12, color: CutlabColors.textMuted)),
        Slider(
          value: _v.clamp(0.0, max <= 0 ? 0.0 : max),
          max: max <= 0 ? 1 : max,
          onChanged: max <= 0 ? null : (v) => setState(() => _v = v),
          onChangeEnd: (v) => widget.onCommit(v.round()),
        ),
      ],
    );
  }
}

class _TextEditor extends StatefulWidget {
  const _TextEditor({super.key, required this.initial, required this.onCommit});
  final String initial;
  final ValueChanged<String> onCommit;

  @override
  State<_TextEditor> createState() => _TextEditorState();
}

class _TextEditorState extends State<_TextEditor> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _commit() {
    if (_c.text != widget.initial) widget.onCommit(_c.text);
  }

  @override
  Widget build(BuildContext context) => TextField(
        key: const Key('clipText'),
        controller: _c,
        decoration: const InputDecoration(labelText: 'Text'),
        maxLines: 3,
        minLines: 1,
        onSubmitted: (_) => _commit(),
        onEditingComplete: _commit,
        onTapOutside: (_) => _commit(),
      );
}
