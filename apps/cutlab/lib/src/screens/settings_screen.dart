import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:flutter/material.dart';

import '../services.dart';
import '../storage/app_settings.dart';
import '../theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ValueListenableBuilder<AppSettings>(
        valueListenable: services.settings,
        builder: (context, s, _) => ListView(
          padding: const EdgeInsets.all(CutlabSpacing.xl),
          children: [
            const Text('Editor mode for new projects', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: CutlabSpacing.sm),
            SegmentedButton<EditorMode>(
              key: const Key('defaultMode'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: EditorMode.beginner, label: Text('Beginner')),
                ButtonSegment(value: EditorMode.advanced, label: Text('Advanced')),
              ],
              selected: {s.defaultMode},
              onSelectionChanged: (v) => services.updateSettings(s.copyWith(defaultMode: v.first)),
            ),
            const SizedBox(height: CutlabSpacing.xl),
            const Text('Autosave unsaved changes after', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: CutlabSpacing.xs),
            const Text(
              'Unsaved work is written to a recovery file so it survives crashes. Applies to projects opened afterwards.',
              style: TextStyle(color: CutlabColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: CutlabSpacing.sm),
            Wrap(
              spacing: CutlabSpacing.sm,
              children: [
                for (final secs in AppSettings.autosaveChoices)
                  ChoiceChip(
                    label: Text('$secs s'),
                    selected: s.autosaveSeconds == secs,
                    onSelected: (_) => services.updateSettings(s.copyWith(autosaveSeconds: secs)),
                  ),
              ],
            ),
            const SizedBox(height: CutlabSpacing.xl),
            const Text('Project folder', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: CutlabSpacing.xs),
            SelectableText(services.projects.location, style: const TextStyle(color: CutlabColors.textMuted, fontSize: 12)),
            const SizedBox(height: CutlabSpacing.xl),
            const Text('Version', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: CutlabSpacing.xs),
            Text('CUTLAB $appVersion · project format v$currentFormatVersion',
                style: const TextStyle(color: CutlabColors.textMuted, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
