import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:flutter/material.dart';

import '../editor/editor_controller.dart';
import '../export/titles.dart';
import '../format.dart';
import '../playback/timeline_playback.dart';
import '../theme.dart';
import 'mixer_panel.dart';
import 'timeline_state.dart';

/// The timeline monitor: the edited timeline as it plays (picture of the
/// top-most visible clip, titles, all audio mixed by the native renderer),
/// with the transport controls and a playback quality indicator.
class ProgramMonitor extends StatelessWidget {
  const ProgramMonitor({super.key, required this.controller, required this.state, required this.playback});

  final EditorController controller;
  final TimelineState state;
  final TimelinePlayback playback;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([playback, state, controller]),
      builder: (context, _) {
        final p = state.preview ?? controller.project;
        final t = state.playhead;
        final titles = [
          for (final tr in p.tracks)
            if (tr.kind == TrackKind.text && !tr.hidden)
              for (final c in tr.clips)
                if (c.startTicks <= t && t < c.endTicks) c.data['text'] as String? ?? '',
        ];
        final s = p.settings;
        final image = playback.image;
        return Column(
          children: [
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: s.width / s.height,
                  child: LayoutBuilder(
                    builder: (context, box) => Container(
                      color: Colors.black,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (image != null) RawImage(key: const Key('monitorPicture'), image: image, fit: BoxFit.contain),
                          if (!playback.available && p.durationTicks > 0)
                            _note(playback.unavailable ?? controller.engine.info.reason ?? 'Playback is not available in this build.'),
                          if (p.durationTicks == 0) _note('Add media to the timeline (＋ on a file in Media)'),
                          if (titles.isNotEmpty)
                            // Sized like the exported video's titles (export/titles.dart).
                            Padding(
                              padding: EdgeInsets.all(TitleLook.padding(box.maxHeight)),
                              child: Align(
                                alignment: const Alignment(0, TitleLook.alignY),
                                child: Text(
                                  titles.join('\n'),
                                  key: const Key('monitorTitles'),
                                  textAlign: TextAlign.center,
                                  style: TitleLook.style(box.maxHeight),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _Transport(controller: controller, state: state, playback: playback, project: p),
          ],
        );
      },
    );
  }

  static Widget _note(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(CutlabSpacing.md),
          child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: CutlabColors.textMuted, fontSize: 12)),
        ),
      );
}

class _Transport extends StatelessWidget {
  const _Transport({required this.controller, required this.state, required this.playback, required this.project});

  final EditorController controller;
  final TimelineState state;
  final TimelinePlayback playback;
  final Project project;

  @override
  Widget build(BuildContext context) {
    final can = playback.available && project.durationTicks > 0;
    final advanced = controller.project.editorMode == EditorMode.advanced;
    final st = playback.stats;
    return Padding(
      padding: const EdgeInsets.only(top: CutlabSpacing.xs),
      child: Row(
        children: [
          IconButton(
            key: const Key('tlStop'),
            tooltip: 'Stop (Shift+Space): back to where playback started',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.stop),
            onPressed: can ? playback.stop : null,
          ),
          IconButton.filled(
            key: const Key('tlPlay'),
            tooltip: playback.playing ? 'Pause (Space)' : 'Play (Space)',
            icon: Icon(playback.playing ? Icons.pause : Icons.play_arrow),
            onPressed: can ? playback.toggle : null,
          ),
          const SizedBox(width: CutlabSpacing.sm),
          Flexible(
            flex: 3,
            child: Text(
              '${formatTimecode(state.playhead, project.fps)} / ${formatTimecode(project.durationTicks, project.fps)}',
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
          const Spacer(),
          if (playback.available && st.framesShown > 0)
            Flexible(
              flex: 2,
              child: InkWell(
                key: const Key('syncInfo'),
                onTap: () => showSyncDiagnostics(context, playback),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: CutlabSpacing.xs, vertical: CutlabSpacing.xs),
                  child: Text(
                    [
                      if (st.decoder.isNotEmpty) '${st.hardware ? 'HW' : 'SW'} ${st.decoder}',
                      '${st.framesDropped} dropped',
                      if (advanced) 'A/V ${st.videoLateAvgMs.toStringAsFixed(0)} ms',
                      if (st.audioUnderruns > 0) '${st.audioUnderruns} audio gaps',
                    ].join(' · '),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11, color: st.framesDropped > 0 || st.audioUnderruns > 0 ? CutlabColors.danger : CutlabColors.textMuted),
                  ),
                ),
              ),
            ),
          SizedBox(width: 40, height: 8, child: LevelMeter(level: playback.masterLevel, key: const Key('masterMeter'))),
          const SizedBox(width: CutlabSpacing.sm),
        ],
      ),
    );
  }
}

/// Playback quality and audio/video synchronisation figures.
Future<void> showSyncDiagnostics(BuildContext context, TimelinePlayback playback) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: playback,
      builder: (ctx, _) {
        final s = playback.stats;
        String ms(double v) => '${v.toStringAsFixed(1)} ms';
        final rows = <(String, String)>[
          ('Clock', s.audioDevice ? 'audio device (${s.audioBackend})' : 'system clock (no audio device)'),
          ('Audio output latency', ms(s.audioLatencyMs)),
          ('Audio mixed ahead', ms(s.audioBufferedMs)),
          ('Audio gaps (underruns)', '${s.audioUnderruns}'),
          ('Audio clock vs wall clock', ms(s.audioClockDriftMs)),
          ('Picture late vs sound (avg / max)', '${ms(s.videoLateAvgMs)} / ${ms(s.videoLateMaxMs)}'),
          ('Pictures shown / dropped', '${s.framesShown} / ${s.framesDropped}'),
          ('Clip changes (prepared ahead)', '${s.clipTransitions} (${s.preparedTransitions})'),
          ('Video decoder', s.decoder.isEmpty ? '—' : '${s.decoder} (${s.hardware ? 'hardware' : 'software'})'),
          ('Audio decoders open', '${s.audioDecoders}'),
          ('Mixer load', '${s.mixLoadPercent.toStringAsFixed(2)} % of one CPU'),
          ('Clipped samples', '${s.clippedSamples}'),
          ('Memory', '${s.rssKiB ~/ 1024} MB'),
          if (s.videoError.isNotEmpty) ('Video problem', s.videoError),
          if (s.audioError.isNotEmpty) ('Audio problem', s.audioError),
        ];
        return AlertDialog(
          key: const Key('syncDiagnostics'),
          title: const Text('Playback diagnostics'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (k, v) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: Text(k, style: const TextStyle(fontSize: 12, color: CutlabColors.textMuted))),
                        const SizedBox(width: CutlabSpacing.sm),
                        Expanded(child: Text(v, style: const TextStyle(fontSize: 12))),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close'))],
        );
      },
    ),
  );
}
