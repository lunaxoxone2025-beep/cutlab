import 'package:cutlab_project_format/cutlab_project_format.dart';

import '../editor/editor_controller.dart';
import 'timeline_state.dart';

/// Every timeline command, shared by the toolbar, keyboard shortcuts and the
/// clip inspector. Each one is a single undo step; failures are reported
/// through [onMessage] and leave the project unchanged.
class TimelineActions {
  TimelineActions(this.controller, this.state, {required this.onMessage});

  final EditorController controller;
  final TimelineState state;
  final void Function(String message) onMessage;

  Project get project => controller.project;
  Set<String> get selection => state.selection;
  bool get hasSelection => selection.isNotEmpty;

  /// The single selected clip, if exactly one is selected.
  PlacedClip? get single => selection.length == 1 ? project.find(selection.first) : null;

  bool _run(Project Function(Project p) op) {
    try {
      controller.edit(op);
      state.pruneSelection(controller.project);
      return true;
    } on EditException catch (e) {
      onMessage(e.message);
      return false;
    }
  }

  // ------------------------------------------------------------------ add

  void addMedia(String mediaId, {int? at, String? trackId}) {
    String? created;
    final ok = _run((p) {
      final (np, id) = p.addMediaClip(mediaId, at ?? state.playhead, controller.newId, trackId: trackId);
      created = id;
      return np;
    });
    if (ok && created != null) state.select(created!);
  }

  void addText(String text) {
    String? created;
    final ok = _run((p) {
      final (np, id) = p.addTextClip(text, state.playhead, controller.newId);
      created = id;
      return np;
    });
    if (ok && created != null) state.select(created!);
  }

  void addTrack(TrackKind kind) => _run((p) => p.addTrack(kind, controller.newId).$1);

  // ------------------------------------------------------------ edit ops

  /// Splits the selected clips at the playhead, or every clip under it when
  /// nothing is selected.
  void split() {
    _run((p) => p.split(state.playhead, controller.newId, clipIds: hasSelection ? selection : null).$1);
  }

  void delete({bool ripple = false}) {
    if (!hasSelection) return onMessage('Select clips to delete');
    final ids = {...selection};
    if (_run((p) => p.deleteClips(ids, ripple: ripple))) state.clearSelection();
  }

  void duplicate() {
    if (!hasSelection) return onMessage('Select clips to duplicate');
    List<String> created = const [];
    final ok = _run((p) {
      final (np, ids) = p.duplicate(selection, controller.newId);
      created = ids;
      return np;
    });
    if (ok) _selectAll(created);
  }

  void copy() {
    if (!hasSelection) return onMessage('Select clips to copy');
    state.clipboard = project.copy(selection);
    onMessage(state.clipboard!.items.length == 1 ? 'Copied 1 clip' : 'Copied ${state.clipboard!.items.length} clips');
    state.touch();
  }

  void cut() {
    if (!hasSelection) return onMessage('Select clips to cut');
    state.clipboard = project.copy(selection);
    delete();
  }

  void paste() {
    final board = state.clipboard;
    if (board == null || board.isEmpty) return onMessage('Nothing to paste');
    List<String> created = const [];
    final ok = _run((p) {
      final (np, ids) = p.paste(board, state.playhead, controller.newId);
      created = ids;
      return np;
    });
    if (ok) _selectAll(created);
  }

  void detachAudio() {
    final pc = single;
    if (pc == null) return onMessage('Select one video clip');
    _run((p) => p.detachAudio(pc.clip.id, controller.newId).$1);
  }

  void link() => _run((p) => p.link(selection, controller.newId));
  void unlink() => _run((p) => p.unlink(selection));

  /// Shifts the selected (unlinked) clips by whole frames — for lining up
  /// audio with video.
  void nudge(int frames) {
    if (!hasSelection) return onMessage('Select the clips to shift');
    _run((p) => p.nudge(selection, frames));
  }

  void setVolume(double v) {
    if (!hasSelection) return;
    _run((p) => p.setVolume(selection, v));
  }

  void setFades({int? fadeIn, int? fadeOut}) {
    final pc = single;
    if (pc == null) return;
    _run((p) => p.setFades(pc.clip.id, fadeInTicks: fadeIn, fadeOutTicks: fadeOut));
  }

  void setDuration(int ticks) {
    final pc = single;
    if (pc == null) return;
    _run((p) => p.setDuration(pc.clip.id, ticks));
  }

  void setText(String text) {
    final pc = single;
    if (pc == null) return;
    _run((p) => p.setText(pc.clip.id, text));
  }

  // ------------------------------------------------------------ selection

  void selectAll() => _selectAll([
        for (final t in project.tracks)
          if (!t.locked)
            for (final c in t.clips) c.id,
      ]);

  void _selectAll(List<String> ids) {
    state.selection
      ..clear()
      ..addAll(ids);
    state.touch();
  }

  // ------------------------------------------------------------- playhead

  void stepFrames(int n) => state.setPlayhead(state.playhead + n * project.frameTicks, project);
  void stepSeconds(int n) => state.setPlayhead(state.playhead + n * ticksPerSecond, project);
  void toStart() => state.setPlayhead(0, project);
  void toEnd() => state.setPlayhead(project.durationTicks, project);

  /// Jumps to the previous/next clip edge (any track).
  void toEdge(int direction) {
    final points = project.snapPoints();
    final t = state.playhead;
    final target = direction > 0 ? points.where((p) => p > t).firstOrNull : points.where((p) => p < t).lastOrNull;
    if (target != null) state.setPlayhead(target, project);
  }
}
