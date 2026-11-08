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
              onSelectionChanged: (v) => services.updateSettings(services.settings.value.copyWith(defaultMode: v.first)),
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
                    onSelected: (_) => services.updateSettings(services.settings.value.copyWith(autosaveSeconds: secs)),
                  ),
              ],
            ),
            const SizedBox(height: CutlabSpacing.xl),
            const Text('Preview quality', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: CutlabSpacing.xs),
            const Text(
              'Lower is smoother on mid-range phones and long 60/120 fps recordings. Export quality is not affected.',
              style: TextStyle(color: CutlabColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: CutlabSpacing.sm),
            Wrap(
              spacing: CutlabSpacing.sm,
              children: [
                for (final h in AppSettings.previewChoices)
                  ChoiceChip(
                    label: Text('${h}p'),
                    selected: s.previewHeight == h,
                    onSelected: (_) => services.updateSettings(services.settings.value.copyWith(previewHeight: h)),
                  ),
              ],
            ),
            const SizedBox(height: CutlabSpacing.lg),
            SwitchListTile(
              key: const Key('hardwareDecoding'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Hardware video decoding'),
              subtitle: const Text('Uses the phone or PC video decoder when available; falls back to software automatically.',
                  style: TextStyle(fontSize: 12)),
              value: s.hardwareDecoding,
              onChanged: (v) => services.updateSettings(services.settings.value.copyWith(hardwareDecoding: v)),
            ),
            const SizedBox(height: CutlabSpacing.lg),
            const Text('Media engine', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: CutlabSpacing.xs),
            Text(
              services.engine.available
                  ? 'FFmpeg ${services.engine.info.ffmpegVersion ?? '?'} · hardware: '
                      '${services.engine.info.hardwareDecoders.isEmpty ? 'none' : services.engine.info.hardwareDecoders.join(', ')}'
                  : services.engine.info.reason ?? 'Not available',
              style: const TextStyle(color: CutlabColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: CutlabSpacing.xl),
            const Text('Project folder', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: CutlabSpacing.xs),
            SelectableText(services.projects.location, style: const TextStyle(color: CutlabColors.textMuted, fontSize: 12)),
            const SizedBox(height: CutlabSpacing.xl),
            const Text('Version', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: CutlabSpacing.xs),
            const Text('CUTLAB $appVersion · project format v$currentFormatVersion',
                style: TextStyle(color: CutlabColors.textMuted, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
