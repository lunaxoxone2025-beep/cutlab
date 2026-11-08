import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:flutter/material.dart';

import 'theme.dart';

/// Width at which the desktop workspace (side panels) replaces the
/// touch-first mobile layout.
const double kDesktopBreakpoint = 1000;

/// The editing workspace for one project.
///
/// Phase 1 scope: real project state, the editor-mode switch and the
/// responsive panel layout. Panels whose engine is not built yet say which
/// roadmap phase delivers them instead of showing inert controls.
class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key, required this.project});

  final Project project;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  late Project _project = widget.project;

  void _setMode(EditorMode mode) {
    // Changing mode only changes how the project is presented; tracks,
    // clips and settings are untouched.
    setState(() => _project = _project.copyWith(editorMode: mode, modifiedAt: DateTime.now().toUtc()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_project.name, overflow: TextOverflow.ellipsis),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: CutlabSpacing.md),
            child: SegmentedButton<EditorMode>(
              key: const Key('modeSwitch'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: EditorMode.beginner, label: Text('Beginner')),
                ButtonSegment(value: EditorMode.advanced, label: Text('Advanced')),
              ],
              selected: {_project.editorMode},
              onSelectionChanged: (s) => _setMode(s.first),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) => c.maxWidth >= kDesktopBreakpoint ? _desktop() : _mobile(),
        ),
      ),
    );
  }

  Widget _desktop() {
    return Padding(
      padding: const EdgeInsets.all(CutlabSpacing.sm),
      child: Column(
        children: [
          Expanded(
            flex: 3,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(width: 260, child: _MediaPanel()),
                const SizedBox(width: CutlabSpacing.sm),
                Expanded(child: _PreviewPanel(settings: _project.settings)),
                const SizedBox(width: CutlabSpacing.sm),
                SizedBox(width: 300, child: _InspectorPanel(project: _project)),
              ],
            ),
          ),
          const SizedBox(height: CutlabSpacing.sm),
          Expanded(flex: 2, child: _TimelinePanel(project: _project)),
        ],
      ),
    );
  }

  Widget _mobile() {
    return Padding(
      padding: const EdgeInsets.all(CutlabSpacing.sm),
      child: Column(
        children: [
          Expanded(flex: 5, child: _PreviewPanel(settings: _project.settings)),
          const SizedBox(height: CutlabSpacing.sm),
          Expanded(flex: 4, child: _TimelinePanel(project: _project)),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(CutlabSpacing.md, CutlabSpacing.sm, CutlabSpacing.md, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(title.toUpperCase(),
                      style: const TextStyle(fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w700, color: CutlabColors.textMuted)),
                ),
                if (trailing != null) trailing!,
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _PlannedNote extends StatelessWidget {
  const _PlannedNote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(CutlabSpacing.md),
          child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: CutlabColors.textMuted, fontSize: 12)),
        ),
      );
}

class _MediaPanel extends StatelessWidget {
  const _MediaPanel();

  @override
  Widget build(BuildContext context) =>
      const _Panel(title: 'Media', child: _PlannedNote('Media browser and import — Phase 2.'));
}

class _PreviewPanel extends StatelessWidget {
  const _PreviewPanel({required this.settings});
  final ProjectSettings settings;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Preview',
      trailing: Text('${settings.width} × ${settings.height}',
          style: const TextStyle(fontSize: 11, color: CutlabColors.textMuted)),
      child: Padding(
        padding: const EdgeInsets.all(CutlabSpacing.md),
        child: Center(
          child: AspectRatio(
            aspectRatio: settings.width / settings.height,
            child: const DecoratedBox(
              decoration: BoxDecoration(color: Colors.black),
              child: _PlannedNote('Playback engine — Phase 3.'),
            ),
          ),
        ),
      ),
    );
  }
}

class _InspectorPanel extends StatelessWidget {
  const _InspectorPanel({required this.project});
  final Project project;

  @override
  Widget build(BuildContext context) {
    final s = project.settings;
    final rows = <(String, String)>[
      ('Resolution', '${s.width} × ${s.height}'),
      ('Frame rate', '${_fps(s.frameRate)} fps'),
      ('Audio', '${s.sampleRate ~/ 1000} kHz · ${s.audioChannels == 2 ? 'stereo' : '${s.audioChannels} ch'}'),
      ('Tracks', '${project.tracks.length}'),
      ('Mode', project.editorMode == EditorMode.beginner ? 'Beginner' : 'Advanced'),
      ('Format', 'v$currentFormatVersion'),
    ];
    return _Panel(
      title: 'Project',
      child: ListView(
        padding: const EdgeInsets.all(CutlabSpacing.md),
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: CutlabSpacing.xs),
              child: Row(
                children: [
                  Expanded(child: Text(label, style: const TextStyle(color: CutlabColors.textMuted))),
                  Text(value),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

String _fps(Rational r) {
  if (r.den == 1) return '${r.num}';
  return r.toDouble().toStringAsFixed(2);
}

/// Formats ticks as HH:MM:SS:FF using exact integer frame math.
String formatTimecode(int ticks, Rational fps) {
  final frames = ticksToFrames(ticks, fps);
  final nominal = (fps.num / fps.den).round();
  final ff = frames % nominal;
  final total = frames ~/ nominal;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(total ~/ 3600)}:${two(total ~/ 60 % 60)}:${two(total % 60)}:${two(ff)}';
}

class _TimelinePanel extends StatelessWidget {
  const _TimelinePanel({required this.project});
  final Project project;

  Color _color(TrackKind k) => switch (k) {
        TrackKind.video => CutlabColors.videoTrack,
        TrackKind.audio => CutlabColors.audioTrack,
        TrackKind.text => CutlabColors.textTrack,
      };

  IconData _icon(TrackKind k) => switch (k) {
        TrackKind.video => Icons.movie_outlined,
        TrackKind.audio => Icons.music_note_outlined,
        TrackKind.text => Icons.title,
      };

  @override
  Widget build(BuildContext context) {
    final advanced = project.editorMode == EditorMode.advanced;
    return _Panel(
      title: 'Timeline',
      trailing: Text(
        formatTimecode(project.durationTicks, project.settings.frameRate),
        key: const Key('timelineDuration'),
        style: const TextStyle(fontSize: 11, color: CutlabColors.textMuted),
      ),
      child: ListView(
        padding: const EdgeInsets.all(CutlabSpacing.sm),
        children: [
          for (final t in project.tracks)
            Container(
              margin: const EdgeInsets.only(bottom: CutlabSpacing.xs),
              height: 36,
              decoration: BoxDecoration(
                color: CutlabColors.surfaceRaised,
                borderRadius: BorderRadius.circular(8),
                border: Border(left: BorderSide(color: _color(t.kind), width: 4)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: CutlabSpacing.sm),
              child: Row(
                children: [
                  Icon(_icon(t.kind), size: 16, color: CutlabColors.textMuted),
                  const SizedBox(width: CutlabSpacing.sm),
                  Expanded(child: Text(t.name, overflow: TextOverflow.ellipsis)),
                  Text('${t.clips.length} clips', style: const TextStyle(fontSize: 11, color: CutlabColors.textMuted)),
                  // Advanced mode surfaces per-track state (read-only until Phase 4).
                  if (advanced) ...[
                    const SizedBox(width: CutlabSpacing.sm),
                    Icon(t.locked ? Icons.lock : Icons.lock_open, size: 14, color: CutlabColors.textMuted, semanticLabel: t.locked ? 'locked' : 'unlocked'),
                    const SizedBox(width: CutlabSpacing.xs),
                    Icon(t.hidden ? Icons.visibility_off : Icons.visibility, size: 14, color: CutlabColors.textMuted),
                    const SizedBox(width: CutlabSpacing.xs),
                    Icon(t.muted ? Icons.volume_off : Icons.volume_up, size: 14, color: CutlabColors.textMuted),
                  ],
                ],
              ),
            ),
          const Padding(
            padding: EdgeInsets.only(top: CutlabSpacing.sm),
            child: Text('Clip editing (move, trim, split, undo) — Phase 4.',
                textAlign: TextAlign.center, style: TextStyle(color: CutlabColors.textMuted, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
