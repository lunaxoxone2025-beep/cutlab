import 'dart:math' as math;

import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:cutlab_project_format/cutlab_project_format.dart' as pf show Clip;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../editor/editor_controller.dart';
import '../theme.dart';
import 'timeline_assets.dart';
import 'timeline_painter.dart';
import 'timeline_state.dart';

enum _Mode { none, pan, zoom, scrub, move, trimStart, trimEnd, transition }

/// The multi-track timeline: ruler, track headers and clip lanes.
///
/// Touch: tap a clip to select it, then drag it to move or drag its white
/// edges to trim; drag empty space to scroll; pinch to zoom; drag the ruler
/// to scrub. Long-press a clip to select and move it in one gesture.
/// Mouse: click/drag clips directly, Ctrl/Shift-click for multi-select,
/// wheel to scroll, Ctrl+wheel to zoom.
/// Transitions show as bars across cuts: tap one to edit it, drag its ends
/// to make it longer or shorter.
class TimelineView extends StatefulWidget {
  const TimelineView({super.key, required this.controller, required this.state, required this.assets, this.onTransitionTap});

  final EditorController controller;
  final TimelineState state;
  final TimelineAssets assets;

  /// A transition bar was tapped (the clip after the cut is selected).
  final ValueChanged<String>? onTransitionTap;

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends State<TimelineView> {
  _Mode _mode = _Mode.none;
  PointerDeviceKind _device = PointerDeviceKind.touch;
  Offset _start = Offset.zero;
  Offset _last = Offset.zero;
  double _lastScale = 1;
  String? _dragClip;
  String? _dragTrack;
  Size _size = Size.zero;

  EditorController get c => widget.controller;
  TimelineState get s => widget.state;

  bool get _modifier {
    final keys = HardwareKeyboard.instance;
    return keys.isControlPressed || keys.isShiftPressed || keys.isMetaPressed;
  }

  List<TrackRow> get _rows => layoutTracks(c.project);

  // ------------------------------------------------------------ hit testing

  ({TrackRow? row, pf.Clip? clip, _Mode edge, bool ruler}) _hit(Offset p) {
    if (p.dy < rulerHeight) return (row: null, clip: null, edge: _Mode.none, ruler: true);
    final y = p.dy - rulerHeight + s.scrollY;
    TrackRow? row;
    for (final r in _rows) {
      if (y >= r.top && y < r.bottom) row = r;
    }
    if (row == null) return (row: null, clip: null, edge: _Mode.none, ruler: false);
    final t = s.ticksAtX(p.dx);
    final slop = _device == PointerDeviceKind.mouse ? 6.0 : 14.0;
    pf.Clip? hit;
    var edge = _Mode.none;
    for (final cl in row.track.clips) {
      final x0 = s.xOf(cl.startTicks), x1 = s.xOf(cl.endTicks);
      if (p.dx < x0 - slop || p.dx > x1 + slop) continue;
      final selected = s.selection.contains(cl.id);
      final canTrim = (selected || _device == PointerDeviceKind.mouse) && !row.track.locked && x1 - x0 > 24;
      if (canTrim && (p.dx - x0).abs() <= slop) {
        hit = cl;
        edge = _Mode.trimStart;
        break;
      }
      if (canTrim && (p.dx - x1).abs() <= slop) {
        hit = cl;
        edge = _Mode.trimEnd;
        break;
      }
      if (t >= cl.startTicks && t < cl.endTicks) hit = cl;
    }
    return (row: row, clip: hit, edge: edge, ruler: false);
  }

  /// The transition bar under [p]: the clip after the cut, and whether an
  /// end (grip) was hit.
  ({String clipId, int cut, bool grip, bool locked})? _hitTransition(Offset p) {
    if (p.dy < rulerHeight) return null;
    final y = p.dy - rulerHeight + s.scrollY;
    final project = s.preview ?? c.project;
    final slop = _device == PointerDeviceKind.mouse ? 5.0 : 12.0;
    for (final r in layoutTracks(project)) {
      if (y < r.top || y >= r.bottom) continue;
      for (var i = 1; i < r.track.clips.length; i++) {
        final span = transitionSpan(project, r.track, i);
        if (span == null) continue;
        final cut = r.track.clips[i].startTicks;
        final bar = transitionBar(s, r, rulerHeight + r.top - s.scrollY, span, cut);
        if (!bar.inflate(slop / 2).contains(p)) continue;
        final grip = (p.dx - bar.left).abs() <= slop || (p.dx - bar.right).abs() <= slop;
        return (clipId: r.track.clips[i].id, cut: cut, grip: grip, locked: r.track.locked);
      }
    }
    return null;
  }

  int _transitionCut = 0;

  // --------------------------------------------------------------- gestures

  void _onTapUp(TapUpDetails d) {
    final tr = _hitTransition(d.localPosition);
    if (tr != null) {
      s.select(tr.clipId);
      widget.onTransitionTap?.call(tr.clipId);
      return;
    }
    final h = _hit(d.localPosition);
    if (h.ruler) {
      s.setPlayhead(s.ticksAtX(d.localPosition.dx), c.project);
      return;
    }
    if (h.clip != null) {
      s.select(h.clip!.id, toggle: _modifier);
    } else {
      s.clearSelection();
      s.setPlayhead(s.ticksAtX(d.localPosition.dx), c.project);
    }
  }

  void _onLongPressStart(LongPressStartDetails d) {
    final h = _hit(d.localPosition);
    if (h.clip == null || h.row == null || h.row!.track.locked) return;
    HapticFeedback.selectionClick();
    if (!s.selection.contains(h.clip!.id)) s.select(h.clip!.id);
    _beginClipDrag(_Mode.move, h.clip!, h.row!, d.localPosition);
  }

  void _onLongPressMove(LongPressMoveUpdateDetails d) => _updateDrag(d.localPosition);

  void _onLongPressEnd(LongPressEndDetails d) => _endDrag();

  void _onScaleStart(ScaleStartDetails d) {
    _start = d.localFocalPoint;
    _last = d.localFocalPoint;
    _lastScale = 1;
    if (d.pointerCount > 1) {
      _mode = _Mode.zoom;
      return;
    }
    final tr = _hitTransition(d.localFocalPoint);
    if (tr != null && tr.grip && !tr.locked) {
      s.select(tr.clipId);
      _mode = _Mode.transition;
      _dragClip = tr.clipId;
      _transitionCut = tr.cut;
      s.setPreview(c.project);
      return;
    }
    final h = _hit(d.localFocalPoint);
    if (h.ruler) {
      _mode = _Mode.scrub;
      s.scrubbing = true;
      s.setPlayhead(s.ticksAtX(d.localFocalPoint.dx), c.project);
      return;
    }
    final clip = h.clip;
    if (clip != null && h.row != null && !h.row!.track.locked) {
      final mouse = _device == PointerDeviceKind.mouse;
      if (h.edge != _Mode.none) {
        if (!s.selection.contains(clip.id)) s.select(clip.id);
        _beginClipDrag(h.edge, clip, h.row!, d.localFocalPoint);
        return;
      }
      if (mouse || s.selection.contains(clip.id)) {
        if (!s.selection.contains(clip.id)) s.select(clip.id, toggle: _modifier);
        _beginClipDrag(_Mode.move, clip, h.row!, d.localFocalPoint);
        return;
      }
    }
    _mode = _Mode.pan;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final delta = d.localFocalPoint - _last;
    _last = d.localFocalPoint;
    switch (_mode) {
      case _Mode.zoom:
        if (d.scale > 0) {
          s.zoomAround(d.scale / _lastScale, d.localFocalPoint.dx);
          _lastScale = d.scale;
        }
        _scroll(-delta.dx, -delta.dy);
      case _Mode.pan:
        if (d.pointerCount > 1) {
          _mode = _Mode.zoom;
          _lastScale = d.scale;
          return;
        }
        _scroll(-delta.dx, -delta.dy);
      case _Mode.scrub:
        s.setPlayhead(s.ticksAtX(d.localFocalPoint.dx), c.project);
      case _Mode.move:
      case _Mode.trimStart:
      case _Mode.trimEnd:
        _updateDrag(d.localFocalPoint);
      case _Mode.transition:
        _updateTransition(d.localFocalPoint);
      case _Mode.none:
        break;
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_mode == _Mode.scrub) {
      s.scrubbing = false;
      s.touch();
    }
    if (_mode == _Mode.move || _mode == _Mode.trimStart || _mode == _Mode.trimEnd || _mode == _Mode.transition) _endDrag();
    _mode = _Mode.none;
  }

  void _scroll(double dx, double dy) =>
      s.scrollBy(dx, dy, contentHeight: contentHeight(_rows), viewportHeight: math.max(0, _size.height - rulerHeight));

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed) {
      s.zoomAround(e.scrollDelta.dy < 0 ? 1.15 : 1 / 1.15, e.localPosition.dx);
    } else if (keys.isShiftPressed) {
      _scroll(0, e.scrollDelta.dy);
    } else {
      // Plain wheel scrolls time (the usual NLE convention).
      _scroll(e.scrollDelta.dy + e.scrollDelta.dx, 0);
    }
  }

  // ------------------------------------------------------- clip drag/trim

  void _beginClipDrag(_Mode mode, pf.Clip clip, TrackRow row, Offset at) {
    _mode = mode;
    _dragClip = clip.id;
    _dragTrack = row.track.id;
    _start = at;
    s.setPreview(c.project);
  }

  void _updateDrag(Offset at) {
    final id = _dragClip;
    if (id == null) return;
    final base = c.project;
    final orig = base.find(id);
    if (orig == null) return;
    final dt = s.ticksForPixels(at.dx - _start.dx);
    final threshold = s.ticksForPixels(10);
    final group = s.selection.contains(id) && s.selection.length > 1 ? base.withLinked(s.selection) : base.withLinked([id]);
    final points = s.snapping ? base.snapPoints(playhead: s.playhead, exclude: group) : const <int>[];
    int? guide;
    Project? next;
    try {
      switch (_mode) {
        case _Mode.move:
          var start = orig.clip.startTicks + dt;
          if (s.snapping) {
            final snapped = snapRange(start, orig.clip.durationTicks, points, threshold);
            if (snapped != start) {
              guide = snapped == snapTo(snapped, points, 0) ? snapped : snapped + orig.clip.durationTicks;
              start = snapped;
            }
          }
          if (s.selection.length > 1 && s.selection.contains(id)) {
            next = base.moveClipsBy(s.selection, start - orig.clip.startTicks);
          } else {
            // Vertical: the row under the pointer, if it has the same kind.
            final y = at.dy - rulerHeight + s.scrollY;
            final row = _rows.where((r) => y >= r.top && y < r.bottom).firstOrNull;
            final target = row != null && row.track.kind == orig.track.kind ? row.track.id : _dragTrack;
            next = base.moveClip(id, start, c.newId, targetTrackId: target);
          }
        case _Mode.trimStart:
          var t = orig.clip.startTicks + dt;
          if (s.snapping) {
            final sn = snapTo(t, points, threshold);
            if (sn != t) guide = t = sn;
          }
          next = base.trimStart(id, t);
        case _Mode.trimEnd:
          var t = orig.clip.endTicks + dt;
          if (s.snapping) {
            final sn = snapTo(t, points, threshold);
            if (sn != t) guide = t = sn;
          }
          next = base.trimEnd(id, t);
        default:
          return;
      }
    } on EditException {
      next = s.preview; // keep the last valid position
    }
    s.setPreview(next, guide: guide);
  }

  /// Dragging a grip: the transition stays centred on the cut, so its
  /// length is twice the distance from the cut (limited by setTransition).
  void _updateTransition(Offset at) {
    final id = _dragClip;
    if (id == null) return;
    final base = c.project;
    final tr = base.find(id)?.clip.transitionIn;
    if (tr == null) return;
    final d = 2 * (s.ticksAtX(at.dx) - _transitionCut).abs();
    try {
      s.setPreview(base.setTransition(id, tr.copyWith(durationTicks: d < 1 ? 1 : d)));
    } on EditException {
      // keep the last valid length
    }
  }

  void _endDrag() {
    final p = s.preview;
    s.setPreview(null);
    _dragClip = null;
    _mode = _Mode.none;
    if (p != null && !identical(p, c.project)) c.edit((_) => p);
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, s]),
      builder: (context, _) {
        final rows = layoutTracks(s.preview ?? c.project);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: headerWidth, child: _TrackHeaders(controller: c, state: s, rows: rows)),
            Expanded(
              child: LayoutBuilder(builder: (context, box) {
                _size = Size(box.maxWidth, box.maxHeight);
                return Listener(
                  onPointerDown: (e) => _device = e.kind,
                  onPointerSignal: _onPointerSignal,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: _onTapUp,
                    onLongPressStart: _onLongPressStart,
                    onLongPressMoveUpdate: _onLongPressMove,
                    onLongPressEnd: _onLongPressEnd,
                    onScaleStart: _onScaleStart,
                    onScaleUpdate: _onScaleUpdate,
                    onScaleEnd: _onScaleEnd,
                    child: ClipRect(
                      child: CustomPaint(
                        key: const Key('timelineCanvas'),
                        size: Size.infinite,
                        painter: TimelinePainter(
                          project: c.project,
                          state: s,
                          assets: widget.assets,
                          rows: rows,
                          repaint: Listenable.merge([s, widget.assets]),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],
        );
      },
    );
  }
}

/// Track names with lock / show / mute toggles, scrolled with the lanes.
class _TrackHeaders extends StatelessWidget {
  const _TrackHeaders({required this.controller, required this.state, required this.rows});

  final EditorController controller;
  final TimelineState state;
  final List<TrackRow> rows;

  IconData _icon(TrackKind k) => switch (k) {
        TrackKind.video => Icons.movie_outlined,
        TrackKind.audio => Icons.music_note_outlined,
        TrackKind.text => Icons.title,
        TrackKind.image => Icons.image_outlined,
      };

  void _toggle(String id, {bool? locked, bool? hidden, bool? muted}) =>
      controller.edit((p) => p.updateTrack(id, locked: locked, hidden: hidden, muted: muted));

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Stack(
        children: [
          const Positioned(left: 0, right: 0, top: 0, height: rulerHeight, child: ColoredBox(color: CutlabColors.surface)),
          for (final r in rows)
            Positioned(
              left: 0,
              right: 0,
              top: rulerHeight + r.top - state.scrollY,
              height: r.height,
              child: Container(
                key: Key('trackHeader-${r.track.id}'),
                margin: const EdgeInsets.only(right: 2),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: CutlabColors.surface,
                  border: Border(left: BorderSide(color: TimelinePainter.colorFor(r.track.kind), width: 3)),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(_icon(r.track.kind), size: 12, color: CutlabColors.textMuted),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(r.track.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10)),
                        ),
                      ],
                    ),
                    if (r.height >= 40)
                      Row(
                        children: [
                          _HeaderButton(
                            icon: r.track.locked ? Icons.lock : Icons.lock_open,
                            active: r.track.locked,
                            tooltip: r.track.locked ? 'Unlock track' : 'Lock track',
                            onTap: () => _toggle(r.track.id, locked: !r.track.locked),
                          ),
                          if (r.track.kind != TrackKind.audio)
                            _HeaderButton(
                              icon: r.track.hidden ? Icons.visibility_off : Icons.visibility,
                              active: r.track.hidden,
                              tooltip: r.track.hidden ? 'Show track' : 'Hide track',
                              onTap: () => _toggle(r.track.id, hidden: !r.track.hidden),
                            ),
                          if (r.track.kind == TrackKind.audio || r.track.kind == TrackKind.video)
                            _HeaderButton(
                              icon: r.track.muted ? Icons.volume_off : Icons.volume_up,
                              active: r.track.muted,
                              tooltip: r.track.muted ? 'Unmute track' : 'Mute track',
                              onTap: () => _toggle(r.track.id, muted: !r.track.muted),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.icon, required this.active, required this.tooltip, required this.onTap});
  final IconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkResponse(
          onTap: onTap,
          radius: 16,
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Icon(icon, size: 15, color: active ? CutlabColors.accent : CutlabColors.textMuted),
          ),
        ),
      );
}
