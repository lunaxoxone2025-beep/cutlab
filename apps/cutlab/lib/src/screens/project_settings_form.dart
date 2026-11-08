import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:flutter/material.dart';

import '../theme.dart';

/// Canvas presets offered for projects.
enum CanvasPreset {
  landscape('16:9', 'YouTube', 1920, 1080),
  vertical('9:16', 'Shorts / Reels', 1080, 1920),
  square('1:1', 'Square', 1080, 1080),
  portrait('4:5', 'Feed', 1080, 1350);

  const CanvasPreset(this.ratio, this.label, this.width, this.height);
  final String ratio;
  final String label;
  final int width;
  final int height;

  static CanvasPreset? of(ProjectSettings s) {
    for (final p in values) {
      if (p.width == s.width && p.height == s.height) return p;
    }
    return null;
  }
}

const frameRateChoices = <String, Rational>{
  '24': Rational.fps24,
  '25': Rational.fps25,
  '29.97': Rational.fps29_97,
  '30': Rational.fps30,
  '50': Rational.fps50,
  '60': Rational.fps60,
};

/// Canvas and frame-rate chips. Used when creating a project and in the
/// project inspector.
class CanvasAndRatePicker extends StatelessWidget {
  const CanvasAndRatePicker({super.key, required this.settings, required this.onChanged});

  final ProjectSettings settings;
  final ValueChanged<ProjectSettings> onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final preset = CanvasPreset.of(settings);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Canvas', style: text.titleSmall),
        const SizedBox(height: CutlabSpacing.sm),
        Wrap(
          spacing: CutlabSpacing.sm,
          runSpacing: CutlabSpacing.sm,
          children: [
            for (final p in CanvasPreset.values)
              ChoiceChip(
                label: Text('${p.ratio} · ${p.label}'),
                selected: preset == p,
                onSelected: (_) => onChanged(settings.copyWith(width: p.width, height: p.height)),
              ),
          ],
        ),
        const SizedBox(height: CutlabSpacing.lg),
        Text('Frame rate (fps)', style: text.titleSmall),
        const SizedBox(height: CutlabSpacing.sm),
        Wrap(
          spacing: CutlabSpacing.sm,
          runSpacing: CutlabSpacing.sm,
          children: [
            for (final e in frameRateChoices.entries)
              ChoiceChip(
                label: Text(e.key),
                selected: settings.frameRate == e.value,
                onSelected: (_) => onChanged(settings.copyWith(frameRate: e.value)),
              ),
          ],
        ),
      ],
    );
  }
}

class NewProjectRequest {
  const NewProjectRequest(this.name, this.settings);
  final String name;
  final ProjectSettings settings;
}

/// Bottom sheet that asks for name, canvas and frame rate.
class NewProjectSheet extends StatefulWidget {
  const NewProjectSheet({super.key});

  static Future<NewProjectRequest?> show(BuildContext context) => showModalBottomSheet<NewProjectRequest>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => const NewProjectSheet(),
      );

  @override
  State<NewProjectSheet> createState() => _NewProjectSheetState();
}

class _NewProjectSheetState extends State<NewProjectSheet> {
  final _name = TextEditingController(text: 'My project');
  ProjectSettings _settings = ProjectSettings.landscape1080p;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim().isEmpty ? 'Untitled' : _name.text.trim();
    Navigator.of(context).pop(NewProjectRequest(name, _settings));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(CutlabSpacing.xl, 0, CutlabSpacing.xl, CutlabSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('New project', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: CutlabSpacing.lg),
            TextField(
              key: const Key('projectName'),
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: CutlabSpacing.lg),
            CanvasAndRatePicker(settings: _settings, onChanged: (s) => setState(() => _settings = s)),
            const SizedBox(height: CutlabSpacing.xl),
            FilledButton(
              key: const Key('createProject'),
              onPressed: _submit,
              child: const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Text('Create project')),
            ),
          ],
        ),
      ),
    );
  }
}
