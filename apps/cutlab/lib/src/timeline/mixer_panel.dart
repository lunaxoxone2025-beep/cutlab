import 'dart:math' as math;

import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:flutter/material.dart';

import '../editor/editor_controller.dart';
import '../playback/timeline_playback.dart';
import '../theme.dart';

/// Track and master volumes, mute and solo, with level meters while the
/// timeline plays. Every control changes the sound the renderer mixes.
class MixerPanel extends StatelessWidget {
  const MixerPanel({super.key, required this.controller, required this.playback});

  final EditorController controller;
  final TimelinePlayback playback;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, playback]),
      builder: (context, _) {
        final p = controller.project;
        final advanced = p.editorMode == EditorMode.advanced;
        final tracks = [
          for (final t in p.tracks)
            if (t.kind == TrackKind.video || t.kind == TrackKind.audio) t,
        ];
        return ListView(
          padding: const EdgeInsets.all(CutlabSpacing.sm),
          children: [
            for (final t in tracks)
              _Strip(
                key: Key('mixer-${t.id}'),
                id: t.id,
                label: t.name.isEmpty ? t.id : t.name,
                icon: t.kind == TrackKind.audio ? Icons.music_note_outlined : Icons.videocam_outlined,
                volume: t.volume,
                muted: t.muted,
                solo: t.solo,
                silencedBySolo: !t.muted && !p.isAudible(t),
                showSolo: advanced,
                showDb: advanced,
                level: playback.levelOf(t.id),
                onVolume: (v) => controller.editLive((q) => q.updateTrack(t.id, volume: v)),
                onVolumeEnd: controller.commitLive,
                onMute: () => controller.edit((q) => q.updateTrack(t.id, muted: !t.muted)),
                onSolo: () => controller.edit((q) => q.updateTrack(t.id, solo: !t.solo)),
              ),
            const Divider(),
            _Strip(
              key: const Key('mixer-master'),
              id: 'master',
              label: 'Master',
              icon: Icons.speaker_outlined,
              volume: p.masterVolume,
              showDb: advanced,
              level: playback.masterLevel,
              onVolume: (v) => controller.editLive((q) => q.setMasterVolume(v)),
              onVolumeEnd: controller.commitLive,
            ),
            if (!playback.available)
              const Padding(
                padding: EdgeInsets.all(CutlabSpacing.sm),
                child: Text('Meters work while the timeline plays (media engine not available).',
                    style: TextStyle(fontSize: 11, color: CutlabColors.textMuted)),
              ),
          ],
        );
      },
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip({
    super.key,
    required this.id,
    required this.label,
    required this.icon,
    required this.volume,
    required this.level,
    required this.onVolume,
    required this.onVolumeEnd,
    this.muted = false,
    this.solo = false,
    this.silencedBySolo = false,
    this.showSolo = false,
    this.showDb = false,
    this.onMute,
    this.onSolo,
  });

  final String id;
  final String label;
  final IconData icon;
  final double volume;
  final double level;
  final bool muted;
  final bool solo;
  final bool silencedBySolo;
  final bool showSolo;
  final bool showDb;
  final ValueChanged<double> onVolume;
  final VoidCallback onVolumeEnd;
  final VoidCallback? onMute;
  final VoidCallback? onSolo;

  @override
  Widget build(BuildContext context) {
    final off = muted || silencedBySolo;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: off ? CutlabColors.textMuted : null),
              const SizedBox(width: CutlabSpacing.xs),
              Expanded(
                child: Text(label,
                    overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: off ? CutlabColors.textMuted : null)),
              ),
              Text(showDb ? gainLabel(volume) : '${(volume * 100).round()}%',
                  key: Key('gain-$id'), style: const TextStyle(fontSize: 11, color: CutlabColors.textMuted)),
              if (onMute != null)
                _Toggle(
                    key: Key('mute-$id'),
                    label: 'M',
                    tooltip: muted ? 'Unmute' : 'Mute',
                    on: muted,
                    color: CutlabColors.danger,
                    onTap: onMute!),
              if (showSolo && onSolo != null)
                _Toggle(
                    key: Key('solo-$id'),
                    label: 'S',
                    tooltip: solo ? 'Unsolo' : 'Solo',
                    on: solo,
                    color: CutlabColors.imageTrack,
                    onTap: onSolo!),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(trackHeight: 3, overlayShape: SliderComponentShape.noOverlay),
                  child: Slider(
                    key: Key('volume-$id'),
                    value: volume.clamp(0.0, 2.0),
                    max: 2.0,
                    divisions: 80,
                    onChanged: onVolume,
                    onChangeEnd: (_) => onVolumeEnd(),
                  ),
                ),
              ),
              const SizedBox(width: CutlabSpacing.xs),
              SizedBox(width: 60, height: 8, child: LevelMeter(level: off ? 0 : level, key: Key('meter-$id'))),
            ],
          ),
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({super.key, required this.label, required this.tooltip, required this.on, required this.color, required this.onTap});
  final String label;
  final String tooltip;
  final bool on;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            width: 28,
            height: 28,
            margin: const EdgeInsets.only(left: 4),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? color : Colors.transparent,
              border: Border.all(color: on ? color : CutlabColors.outline),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: on ? Colors.black : CutlabColors.text)),
          ),
        ),
      );
}

/// "+3.5 dB", "0.0 dB", "−∞ dB" for a gain factor.
String gainLabel(double gain) {
  if (gain <= 0.0001) return '−∞ dB';
  final db = 20 * math.log(gain) / math.ln10;
  final v = db.abs() < 0.05 ? 0.0 : db;
  return '${v > 0 ? '+' : v < 0 ? '−' : ''}${v.abs().toStringAsFixed(1)} dB';
}

/// A horizontal peak meter: green to −6 dBFS, yellow to −1, red above.
class LevelMeter extends StatelessWidget {
  const LevelMeter({super.key, required this.level});

  /// Peak amplitude, 0..1.
  final double level;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _MeterPainter(level), size: Size.infinite);
}

class _MeterPainter extends CustomPainter {
  _MeterPainter(this.level);
  final double level;

  /// Position on the meter: −60 dBFS .. 0 dBFS mapped to 0..1.
  static double scale(double amp) {
    if (amp <= 0.001) return 0;
    final db = 20 * math.log(amp) / math.ln10;
    return ((db + 60) / 60).clamp(0.0, 1.0);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(2));
    canvas.drawRRect(r, Paint()..color = CutlabColors.surfaceRaised);
    final x = scale(level) * size.width;
    if (x <= 0) return;
    final color = level >= 0.89
        ? CutlabColors.danger
        : level >= 0.5
            ? CutlabColors.imageTrack
            : CutlabColors.accent;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, x, size.height), const Radius.circular(2)), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_MeterPainter oldDelegate) => oldDelegate.level != level;
}
