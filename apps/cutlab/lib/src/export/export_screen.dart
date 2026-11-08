import 'dart:async';

import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:flutter/material.dart';

import '../engine/media_engine.dart';
import '../theme.dart';
import 'export_controller.dart';
import 'export_settings.dart';

/// Export: choose resolution, frame rate, codec and quality; watch the
/// render; find the finished, checked file.
class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key, required this.controller});

  final ExportController controller;

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  ExportController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    unawaited(c.loadEncoders());
  }

  Future<bool> _confirmLeave() async {
    if (!c.running) return true;
    final stop = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop the export?'),
        content: const Text('The video is not finished. Stopping deletes what has been rendered so far.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Keep exporting')),
          TextButton(key: const Key('exportStopConfirm'), onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Stop export')),
        ],
      ),
    );
    if (stop == true) c.cancel();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => PopScope(
        canPop: !c.running,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_confirmLeave());
        },
        child: Scaffold(
          key: const Key('exportScreen'),
          appBar: AppBar(title: const Text('Export video')),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: switch (c.phase) {
                  ExportPhase.setup => _Setup(c: c),
                  ExportPhase.starting || ExportPhase.rendering || ExportPhase.publishing => _Progress(c: c, onStop: _confirmLeave),
                  ExportPhase.done => _Done(c: c),
                  ExportPhase.failed => _Failed(c: c),
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ settings

class _Setup extends StatelessWidget {
  const _Setup({required this.c});
  final ExportController c;

  @override
  Widget build(BuildContext context) {
    final s = c.settings;
    final advanced = c.project.editorMode == EditorMode.advanced;
    final (w, h) = c.outputSize;
    final enc = c.encoder;
    final empty = c.durationTicks <= 0;
    final seconds = c.durationTicks / ticksPerSecond;
    return ListView(
      padding: const EdgeInsets.all(CutlabSpacing.lg),
      children: [
        _Section(
          title: 'Resolution',
          child: Wrap(spacing: CutlabSpacing.sm, runSpacing: CutlabSpacing.sm, children: [
            for (final r in exportResolutions)
              ChoiceChip(
                key: Key('exportResolution-$r'),
                label: Text(resolutionLabel(r)),
                selected: s.resolution == r,
                onSelected: (_) => c.update(s.copyWith(resolution: r)),
              ),
          ]),
        ),
        _Section(
          title: 'Frame rate',
          child: Wrap(spacing: CutlabSpacing.sm, runSpacing: CutlabSpacing.sm, children: [
            for (final r in exportFrameRates)
              ChoiceChip(
                key: Key('exportFps-${r.num}'),
                label: Text('${r.num} fps'),
                selected: s.frameRate == r,
                onSelected: (_) => c.update(s.copyWith(frameRate: r)),
              ),
          ]),
        ),
        _Section(
          title: 'Quality',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: CutlabSpacing.sm, runSpacing: CutlabSpacing.sm, children: [
              for (final q in ExportQuality.values)
                ChoiceChip(
                  key: Key('exportQuality-${q.name}'),
                  label: Text(q.label),
                  selected: s.bitrateKbps == 0 && s.quality == q,
                  onSelected: (_) => c.update(s.copyWith(quality: q, bitrateKbps: 0)),
                ),
              if (advanced)
                ChoiceChip(
                  key: const Key('exportQuality-bitrate'),
                  label: const Text('Fixed bitrate'),
                  selected: s.bitrateKbps > 0,
                  onSelected: (_) => c.update(s.copyWith(bitrateKbps: s.videoBitrate(w, h) ~/ 1000)),
                ),
            ]),
            if (advanced && s.bitrateKbps > 0) ...[
              const SizedBox(height: CutlabSpacing.sm),
              Text('${(s.bitrateKbps / 1000).toStringAsFixed(1)} Mbit/s', key: const Key('exportBitrateValue')),
              Slider(
                key: const Key('exportBitrate'),
                min: 1,
                max: 150,
                divisions: 149,
                value: (s.bitrateKbps / 1000).clamp(1, 150).toDouble(),
                onChanged: (v) => c.update(s.copyWith(bitrateKbps: (v * 1000).round())),
              ),
            ],
          ]),
        ),
        _Section(
          title: 'Codec',
          child: Column(children: [
            if (c.checkingEncoders)
              const Padding(
                padding: EdgeInsets.all(CutlabSpacing.sm),
                child: Row(children: [
                  SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: CutlabSpacing.sm),
                  Text('Checking which encoders work on this device…'),
                ]),
              ),
            for (final codec in ExportCodec.values) _CodecTile(c: c, codec: codec),
            if (c.encoderProblem != null)
              Text(c.encoderProblem!, key: const Key('exportEncoderProblem'), style: const TextStyle(color: CutlabColors.danger)),
          ]),
        ),
        if (advanced)
          _Section(
            title: 'Advanced',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (s.codec.containers.length > 1)
                _Row('File format', SegmentedButton<ExportContainer>(
                  key: const Key('exportContainer'),
                  segments: [for (final k in s.codec.containers) ButtonSegment(value: k, label: Text(k.label))],
                  selected: {s.container},
                  onSelectionChanged: (v) => c.update(s.copyWith(container: v.first)),
                )),
              _Row('Encoder effort', SegmentedButton<ExportSpeed>(
                key: const Key('exportSpeed'),
                segments: [for (final v in ExportSpeed.values) ButtonSegment(value: v, label: Text(v.label))],
                selected: {s.speed},
                onSelectionChanged: (v) => c.update(s.copyWith(speed: v.first)),
              )),
              SwitchListTile(
                key: const Key('exportHardware'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Hardware encoding'),
                subtitle: const Text('Faster and cooler when the device has a working encoder; software is used otherwise.'),
                value: s.hardware,
                onChanged: (v) => c.update(s.copyWith(hardware: v)),
              ),
              _Row('Audio', DropdownButton<int>(
                key: const Key('exportAudioBitrate'),
                value: s.audioKbps,
                items: [for (final k in const [128, 192, 256, 320]) DropdownMenuItem(value: k, child: Text('$k kbit/s'))],
                onChanged: (v) => c.update(s.copyWith(audioKbps: v)),
              )),
              _Row('Keyframe every', DropdownButton<double>(
                key: const Key('exportKeyframes'),
                value: s.keyframeSeconds,
                items: [for (final k in const [0.5, 1.0, 2.0, 5.0]) DropdownMenuItem(value: k, child: Text('${k == k.roundToDouble() ? k.round() : k} s'))],
                onChanged: (v) => c.update(s.copyWith(keyframeSeconds: v)),
              )),
              _Row('Encoder threads', DropdownButton<int>(
                key: const Key('exportThreads'),
                value: s.threads,
                items: [for (final t in const [0, 2, 4, 8]) DropdownMenuItem(value: t, child: Text(t == 0 ? 'Automatic' : '$t (cooler, slower)'))],
                onChanged: (v) => c.update(s.copyWith(threads: v)),
              )),
            ]),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(CutlabSpacing.lg),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$w × $h · ${s.fpsLabel} fps · ${s.codec.label} · ${s.container.label}',
                  key: const Key('exportSummary'), style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: CutlabSpacing.xs),
              Text(enc == null
                  ? 'No working ${s.codec.label} encoder on this device'
                  : 'Encoder: ${enc.hardware ? 'hardware' : 'software'} (${enc.name})'),
              Text('Length ${formatDuration(Duration(milliseconds: (seconds * 1000).round()))} · '
                  'sound ${s.container.audioCodec.toUpperCase()} ${s.audioKbps} kbit/s'),
              Text('Estimated size ≈ ${formatBytes(c.estimatedBytes)}', key: const Key('exportEstimate')),
              const SizedBox(height: CutlabSpacing.xs),
              const Text(
                'The whole timeline is rendered from the original files: every clip, sound track, volume, fade and title. '
                'Frames are never skipped; the picture is scaled with a sharp filter.',
                style: TextStyle(fontSize: 12, color: CutlabColors.textMuted),
              ),
            ]),
          ),
        ),
        const SizedBox(height: CutlabSpacing.lg),
        FilledButton.icon(
          key: const Key('exportStart'),
          icon: const Icon(Icons.movie_creation_outlined),
          label: const Text('Export'),
          onPressed: empty || enc == null || c.checkingEncoders ? null : () => unawaited(c.start()),
        ),
        if (empty)
          const Padding(
            padding: EdgeInsets.only(top: CutlabSpacing.sm),
            child: Text('The timeline is empty: add media first.', textAlign: TextAlign.center),
          ),
      ],
    );
  }
}

class _CodecTile extends StatelessWidget {
  const _CodecTile({required this.c, required this.codec});
  final ExportController c;
  final ExportCodec codec;

  @override
  Widget build(BuildContext context) {
    final list = c.encodersFor(codec);
    final available = c.codecAvailable(codec);
    final first = list.isEmpty ? null : list.first;
    final how = c.encoders == null
        ? ''
        : !available
            ? 'not available on this device'
            : first == null
                ? 'hardware only (turn hardware encoding on)'
                : first.hardware
                    ? 'hardware'
                    : 'software';
    return RadioListTile<ExportCodec>(
      key: Key('exportCodec-${codec.name}'),
      contentPadding: EdgeInsets.zero,
      value: codec,
      groupValue: c.settings.codec,
      onChanged: available ? (v) => c.update(c.settings.copyWith(codec: v)) : null,
      title: Text(codec.label),
      subtitle: Text([codec.hint, if (how.isNotEmpty) how].join(' · ')),
    );
  }
}

// ------------------------------------------------------------ progress

class _Progress extends StatelessWidget {
  const _Progress({required this.c, required this.onStop});
  final ExportController c;
  final Future<bool> Function() onStop;

  @override
  Widget build(BuildContext context) {
    final st = c.status;
    final pct = (st.progress * 100).clamp(0, 100);
    final phase = switch (c.phase) {
      ExportPhase.starting => 'Preparing…',
      ExportPhase.publishing => 'Saving the video…',
      _ => st.state == ExportState.finishing
          ? 'Finishing the file…'
          : c.pausedForHeat
              ? 'Paused: the device is hot. It continues when it has cooled down.'
              : c.paused
                  ? 'Paused'
                  : 'Rendering',
    };
    final eta = st.etaMs >= 0 ? formatDuration(Duration(milliseconds: st.etaMs)) : '—';
    return ListView(
      padding: const EdgeInsets.all(CutlabSpacing.lg),
      children: [
        Text(phase, key: const Key('exportPhase'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: CutlabSpacing.md),
        LinearProgressIndicator(key: const Key('exportProgress'), value: c.phase == ExportPhase.rendering ? st.progress : null, minHeight: 8),
        const SizedBox(height: CutlabSpacing.sm),
        Text('${pct.toStringAsFixed(1)} %  ·  frame ${st.framesDone} of ${st.framesTotal}', key: const Key('exportPercent')),
        const SizedBox(height: CutlabSpacing.md),
        _Stat('Speed', st.fps > 0 ? '${st.fps.toStringAsFixed(1)} frames/s (${st.speed.toStringAsFixed(2)}× real time)' : '—',
            key: const Key('exportSpeedValue')),
        _Stat('Time left', eta, key: const Key('exportEta')),
        _Stat('Elapsed', formatDuration(Duration(milliseconds: st.elapsedMs))),
        _Stat('File so far', formatBytes(st.bytes)),
        _Stat('Encoder', st.encoder.isEmpty ? '—' : '${st.encoder} (${st.hardware ? 'hardware' : 'software'})'),
        if (c.condition.thermal >= 2 || c.condition.lowBattery || c.condition.powerSave)
          Padding(
            padding: const EdgeInsets.only(top: CutlabSpacing.sm),
            child: Text(
              [
                if (c.condition.thermal >= 2) 'The device is getting warm.',
                if (c.condition.lowBattery) 'Battery is low (${c.condition.battery} %): plug in the charger for long exports.',
                if (c.condition.powerSave) 'Battery saver is on: the export may be slower.',
              ].join(' '),
              key: const Key('exportCondition'),
              style: const TextStyle(color: CutlabColors.imageTrack),
            ),
          ),
        if (c.missingMedia.isNotEmpty)
          _Warning('Missing media (exported as black and silence): ${c.missingMedia.join(', ')}'),
        for (final w in st.warnings) _Warning(w),
        const SizedBox(height: CutlabSpacing.lg),
        const Text('You can switch to other apps: the export keeps going (on Android a notification shows the progress).',
            style: TextStyle(fontSize: 12, color: CutlabColors.textMuted)),
        const SizedBox(height: CutlabSpacing.lg),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              key: const Key('exportPause'),
              icon: Icon(c.paused ? Icons.play_arrow : Icons.pause),
              label: Text(c.paused ? 'Resume' : 'Pause'),
              onPressed: c.phase == ExportPhase.rendering && !c.pausedForHeat ? c.togglePause : null,
            ),
          ),
          const SizedBox(width: CutlabSpacing.md),
          Expanded(
            child: OutlinedButton.icon(
              key: const Key('exportCancel'),
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
              onPressed: c.phase == ExportPhase.rendering ? () => unawaited(onStop()) : null,
            ),
          ),
        ]),
      ],
    );
  }
}

// ------------------------------------------------------------ result

class _Done extends StatelessWidget {
  const _Done({required this.c});
  final ExportController c;

  @override
  Widget build(BuildContext context) {
    final r = c.result!;
    final v = c.verified;
    final st = c.status;
    final ok = c.verifyProblems.isEmpty && v != null;
    return ListView(
      key: const Key('exportDone'),
      padding: const EdgeInsets.all(CutlabSpacing.lg),
      children: [
        Row(children: [
          Icon(ok ? Icons.check_circle : Icons.warning_amber, color: ok ? CutlabColors.accent : CutlabColors.imageTrack, size: 32),
          const SizedBox(width: CutlabSpacing.md),
          Expanded(
            child: Text(ok ? 'Video exported and checked' : 'Video exported, but the check found problems',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: CutlabSpacing.md),
        _Stat('Saved to', r.location, key: const Key('exportLocation')),
        if (v != null) ...[
          _Stat('Picture', '${v.videoCodec?.toUpperCase()} ${v.width} × ${v.height} · '
              '${v.frameRate == null ? '?' : (v.frameRate!.num / v.frameRate!.den).toStringAsFixed(v.frameRate!.den == 1 ? 0 : 2)} fps',
              key: const Key('exportVerified')),
          _Stat('Sound', v.audioCodec == null ? 'none' : '${v.audioCodec!.toUpperCase()} ${(v.sampleRate ?? 0) ~/ 1000} kHz, ${v.channels} ch'),
          _Stat('Length', formatDuration(ticksToDuration(v.durationTicks))),
          if (v.sizeBytes != null) _Stat('Size', formatBytes(v.sizeBytes!)),
        ],
        _Stat('Took', '${formatDuration(Duration(milliseconds: st.elapsedMs))} with ${st.encoder} (${st.hardware ? 'hardware' : 'software'})'),
        for (final p in c.verifyProblems) _Warning(p),
        for (final w in st.warnings) _Warning(w),
        const SizedBox(height: CutlabSpacing.lg),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              key: const Key('exportOpen'),
              icon: const Icon(Icons.play_circle_outline),
              label: Text(r.gallery ? 'Play' : 'Show file'),
              onPressed: () => unawaited(c.media.openExported(r)),
            ),
          ),
          const SizedBox(width: CutlabSpacing.md),
          Expanded(
            child: OutlinedButton(key: const Key('exportAgain'), onPressed: c.reset, child: const Text('Export again')),
          ),
        ]),
      ],
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.c});
  final ExportController c;

  @override
  Widget build(BuildContext context) {
    final usedHardware = c.status.hardware || (c.settings.hardware && (c.encoder?.hardware ?? false));
    return ListView(
      padding: const EdgeInsets.all(CutlabSpacing.lg),
      children: [
        const Row(children: [
          Icon(Icons.error_outline, color: CutlabColors.danger, size: 32),
          SizedBox(width: CutlabSpacing.md),
          Text('The export did not finish', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: CutlabSpacing.md),
        SelectableText(c.error ?? 'Unknown error', key: const Key('exportError')),
        for (final w in c.status.warnings) _Warning(w),
        const SizedBox(height: CutlabSpacing.sm),
        const Text('Nothing was left behind: the unfinished file was deleted.', style: TextStyle(fontSize: 12, color: CutlabColors.textMuted)),
        const SizedBox(height: CutlabSpacing.lg),
        if (usedHardware)
          FilledButton(
            key: const Key('exportRetrySoftware'),
            onPressed: () => unawaited(c.retryInSoftware()),
            child: const Text('Try again with software encoding'),
          ),
        const SizedBox(height: CutlabSpacing.sm),
        OutlinedButton(key: const Key('exportBack'), onPressed: c.reset, child: const Text('Back to the settings')),
      ],
    );
  }
}

// ------------------------------------------------------------ pieces

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: CutlabSpacing.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700, color: CutlabColors.textMuted)),
          const SizedBox(height: CutlabSpacing.sm),
          child,
        ]),
      );
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.child);
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: CutlabSpacing.xs),
        child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: CutlabSpacing.md, children: [Text(label), child]),
      );
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {super.key});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 110, child: Text(label, style: const TextStyle(color: CutlabColors.textMuted))),
          Expanded(child: Text(value)),
        ]),
      );
}

class _Warning extends StatelessWidget {
  const _Warning(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: CutlabSpacing.sm),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.info_outline, size: 16, color: CutlabColors.imageTrack),
          const SizedBox(width: CutlabSpacing.xs),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
        ]),
      );
}
