import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:flutter/material.dart';

import 'theme.dart';
import 'workspace_screen.dart';

/// Canvas presets offered when creating a project.
enum CanvasPreset {
  landscape('16:9', 'YouTube', ProjectSettings.landscape1080p),
  vertical('9:16', 'Shorts / Reels', ProjectSettings.vertical1080p),
  square('1:1', 'Square', ProjectSettings.square1080),
  portrait('4:5', 'Feed', ProjectSettings.portrait4x5);

  const CanvasPreset(this.ratio, this.label, this.settings);
  final String ratio;
  final String label;
  final ProjectSettings settings;
}

const frameRateChoices = <String, Rational>{
  '24': Rational.fps24,
  '25': Rational.fps25,
  '29.97': Rational.fps29_97,
  '30': Rational.fps30,
  '50': Rational.fps50,
  '60': Rational.fps60,
};

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _name = TextEditingController(text: 'My project');
  CanvasPreset _preset = CanvasPreset.landscape;
  String _fps = '30';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _create() {
    final name = _name.text.trim().isEmpty ? 'Untitled' : _name.text.trim();
    final project = Project.create(
      id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      name: name,
      settings: _preset.settings.copyWith(frameRate: frameRateChoices[_fps]),
    );
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => WorkspaceScreen(project: project)));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('CUTLAB', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.2))),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(CutlabSpacing.xl),
              children: [
                Text('New project', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: CutlabSpacing.lg),
                TextField(
                  key: const Key('projectName'),
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Name'),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _create(),
                ),
                const SizedBox(height: CutlabSpacing.xl),
                Text('Canvas', style: text.titleSmall),
                const SizedBox(height: CutlabSpacing.sm),
                Wrap(
                  spacing: CutlabSpacing.sm,
                  runSpacing: CutlabSpacing.sm,
                  children: [
                    for (final p in CanvasPreset.values)
                      ChoiceChip(
                        label: Text('${p.ratio} · ${p.label}'),
                        selected: _preset == p,
                        onSelected: (_) => setState(() => _preset = p),
                      ),
                  ],
                ),
                const SizedBox(height: CutlabSpacing.xl),
                Text('Frame rate (fps)', style: text.titleSmall),
                const SizedBox(height: CutlabSpacing.sm),
                Wrap(
                  spacing: CutlabSpacing.sm,
                  runSpacing: CutlabSpacing.sm,
                  children: [
                    for (final fps in frameRateChoices.keys)
                      ChoiceChip(label: Text(fps), selected: _fps == fps, onSelected: (_) => setState(() => _fps = fps)),
                  ],
                ),
                const SizedBox(height: CutlabSpacing.xl),
                FilledButton(
                  key: const Key('createProject'),
                  onPressed: _create,
                  child: const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Text('Create project')),
                ),
                const SizedBox(height: CutlabSpacing.xl),
                Text(
                  'Development build — project format v$currentFormatVersion. '
                  'Opening and saving .cutlab files arrives in Phase 2; '
                  'media import and playback in Phases 2–3 (see docs/ROADMAP.md).',
                  style: text.bodySmall?.copyWith(color: CutlabColors.textMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
