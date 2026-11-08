import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:flutter/material.dart';

import '../editor/editor_controller.dart';
import '../format.dart';
import '../theme.dart';
import 'timeline_actions.dart';
import 'timeline_state.dart';

/// Timeline commands. Buttons are disabled when they cannot apply; advanced
/// mode shows the extra tools (ripple delete, link, track management, sync).
class TimelineToolbar extends StatelessWidget {
  const TimelineToolbar({
    super.key,
    required this.controller,
    required this.state,
    required this.actions,
    required this.onAddText,
    required this.onClipSettings,
    required this.viewportWidth,
  });

  final EditorController controller;
  final TimelineState state;
  final TimelineActions actions;
  final VoidCallback onAddText;
  final VoidCallback onClipSettings;
  final double viewportWidth;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, state]),
      builder: (context, _) {
        final p = controller.project;
        final sel = state.selection.isNotEmpty;
        final single = actions.single;
        final advanced = p.editorMode == EditorMode.advanced;
        final canDetach = single != null &&
            single.track.kind == TrackKind.video &&
            (p.mediaById(single.clip.mediaId)?.hasAudio ?? false) &&
            single.clip.linkId == null;
        final linked = state.selection.any((id) => p.find(id)?.clip.linkId != null);
        Widget b(String key, IconData icon, String tip, VoidCallback? onTap, {bool on = false}) => IconButton(
              key: Key(key),
              tooltip: tip,
              visualDensity: VisualDensity.compact,
              isSelected: on,
              icon: Icon(icon, size: 20, color: on ? CutlabColors.accent : null),
              onPressed: onTap,
            );
        return SizedBox(
          height: 42,
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: CutlabSpacing.sm),
                child: Text(
                  formatTimecode(state.playhead, p.fps),
                  key: const Key('playheadTimecode'),
                  style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      b('tlSplit', Icons.content_cut, 'Split at playhead (S)', p.durationTicks > 0 ? actions.split : null),
                      b('tlDelete', Icons.delete_outline, 'Delete (Del)', sel ? () => actions.delete() : null),
                      if (advanced) b('tlRipple', Icons.format_indent_decrease, 'Ripple delete (Shift+Del)', sel ? () => actions.delete(ripple: true) : null),
                      b('tlDuplicate', Icons.copy_all_outlined, 'Duplicate (Ctrl+D)', sel ? actions.duplicate : null),
                      b('tlCopy', Icons.content_copy, 'Copy (Ctrl+C)', sel ? actions.copy : null),
                      b('tlPaste', Icons.content_paste, 'Paste at playhead (Ctrl+V)', (state.clipboard?.isEmpty ?? true) ? null : actions.paste),
                      b('tlClip', Icons.tune, 'Clip settings: volume, fades, duration, text', sel ? onClipSettings : null),
                      b('tlDetach', Icons.call_split, 'Separate audio from video', canDetach ? actions.detachAudio : null),
                      if (advanced) b('tlUnlink', Icons.link_off, 'Unlink', linked ? actions.unlink : null),
                      if (advanced) b('tlLink', Icons.link, 'Link selected clips', state.selection.length > 1 ? actions.link : null),
                      b('tlText', Icons.title, 'Add text at playhead', onAddText),
                      if (advanced)
                        PopupMenuButton<TrackKind>(
                          key: const Key('tlAddTrack'),
                          tooltip: 'Add track',
                          icon: const Icon(Icons.playlist_add, size: 20),
                          onSelected: actions.addTrack,
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: TrackKind.video, child: Text('Video track')),
                            PopupMenuItem(value: TrackKind.image, child: Text('Image track')),
                            PopupMenuItem(value: TrackKind.audio, child: Text('Audio track')),
                            PopupMenuItem(value: TrackKind.text, child: Text('Text track')),
                          ],
                        ),
                      const SizedBox(width: CutlabSpacing.sm),
                      b('tlSnap', Icons.straighten, state.snapping ? 'Snapping on (N)' : 'Snapping off (N)', () {
                        state.snapping = !state.snapping;
                        state.touch();
                      }, on: state.snapping),
                      b('tlMulti', Icons.library_add_check_outlined, 'Multi-select (tap several clips)', () {
                        state.multiSelect = !state.multiSelect;
                        state.touch();
                      }, on: state.multiSelect),
                      b('tlZoomOut', Icons.zoom_out, 'Zoom out (-)', () => state.zoomAround(1 / 1.5, viewportWidth / 2)),
                      b('tlZoomIn', Icons.zoom_in, 'Zoom in (+)', () => state.zoomAround(1.5, viewportWidth / 2)),
                      b('tlFit', Icons.fit_screen_outlined, 'Fit project', () => state.zoomToFit(p.durationTicks, viewportWidth)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
