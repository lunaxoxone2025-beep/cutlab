import 'dart:math' as math;

import 'package:cutlab_project_format/cutlab_project_format.dart';
import 'package:flutter/foundation.dart';

/// UI state of the timeline: zoom, scroll, playhead, selection, clipboard
/// and the in-progress drag. Project data itself lives in EditorController.
class TimelineState extends ChangeNotifier {
  /// Zoom: horizontal pixels per second of timeline.
  double pxPerSec = 40;
  double scrollX = 0;
  double scrollY = 0;
  int playhead = 0;
  final Set<String> selection = {};
  bool snapping = true;
  bool multiSelect = false;
  ClipboardContent? clipboard;

  /// While a clip is dragged or trimmed: the project as it would be if the
  /// gesture ended now (painted instead of the real one; committed on release).
  Project? preview;

  /// Time at which the current drag snapped (drawn as a guide line).
  int? snapGuide;

  /// True while the playhead is being dragged (preview uses fast seeks).
  bool scrubbing = false;

  static const minPxPerSec = 0.05; // ~2 h fits in 360 px
  static const maxPxPerSec = 2400; // ~10 px per frame at 240 fps

  double xOf(int ticks) => ticks / ticksPerSecond * pxPerSec - scrollX;

  int ticksAtX(double x) => ((x + scrollX) / pxPerSec * ticksPerSecond).round();

  int ticksForPixels(double px) => (px / pxPerSec * ticksPerSecond).round();

  void touch() => notifyListeners();

  void setPlayhead(int t, Project p) {
    final end = math.max(p.durationTicks, 0);
    final v = p.quantize(t.clamp(0, end > 0 ? end : 0));
    if (v == playhead) return;
    playhead = v;
    notifyListeners();
  }

  /// Keeps the playhead visible after keyboard moves.
  void revealPlayhead(double viewportWidth) {
    final x = xOf(playhead);
    if (x < 40) {
      scrollX = math.max(0, scrollX + x - 40);
    } else if (x > viewportWidth - 40) {
      scrollX += x - (viewportWidth - 40);
    }
  }

  void select(String id, {bool toggle = false}) {
    if (toggle || multiSelect) {
      if (!selection.remove(id)) selection.add(id);
    } else {
      selection
        ..clear()
        ..add(id);
    }
    notifyListeners();
  }

  void clearSelection() {
    if (selection.isEmpty) return;
    selection.clear();
    notifyListeners();
  }

  /// Drops ids that no longer exist (after undo, delete…).
  void pruneSelection(Project p) {
    final before = selection.length;
    selection.removeWhere((id) => p.find(id) == null);
    if (selection.length != before) notifyListeners();
  }

  void scrollBy(double dx, double dy, {required double contentHeight, required double viewportHeight}) {
    scrollX = math.max(0, scrollX + dx);
    scrollY = (scrollY + dy).clamp(0, math.max(0, contentHeight - viewportHeight)).toDouble();
    notifyListeners();
  }

  /// Zooms by [factor] keeping the time under [focalX] still.
  void zoomAround(double factor, double focalX) {
    final t = (focalX + scrollX) / pxPerSec;
    pxPerSec = (pxPerSec * factor).clamp(minPxPerSec, maxPxPerSec).toDouble();
    scrollX = math.max(0, t * pxPerSec - focalX);
    notifyListeners();
  }

  /// Fits [durationTicks] into [width] pixels.
  void zoomToFit(int durationTicks, double width) {
    final secs = math.max(durationTicks / ticksPerSecond, 5.0);
    pxPerSec = ((width - 40) / secs).clamp(minPxPerSec, maxPxPerSec).toDouble();
    scrollX = 0;
    notifyListeners();
  }

  void setPreview(Project? p, {int? guide}) {
    preview = p;
    snapGuide = guide;
    notifyListeners();
  }
}

/// Vertical layout: which track is drawn where.
class TrackRow {
  const TrackRow(this.track, this.top, this.height);
  final Track track;
  final double top;
  final double height;
  double get bottom => top + height;
}

const double rulerHeight = 26;
const double headerWidth = 112;

double trackHeight(TrackKind k) => switch (k) {
      TrackKind.video => 58,
      TrackKind.image => 44,
      TrackKind.audio => 48,
      TrackKind.text => 34,
    };

/// Pictures on top (highest layer first), then audio in project order.
List<TrackRow> layoutTracks(Project p) {
  final visual = p.tracks.where((t) => t.kind != TrackKind.audio).toList().reversed;
  final audio = p.tracks.where((t) => t.kind == TrackKind.audio);
  final rows = <TrackRow>[];
  var y = 0.0;
  for (final t in [...visual, ...audio]) {
    final h = trackHeight(t.kind);
    rows.add(TrackRow(t, y, h));
    y += h + 2;
  }
  return rows;
}

double contentHeight(List<TrackRow> rows) => rows.isEmpty ? 0 : rows.last.bottom + 8;

/// A good ruler step (in seconds) for the zoom level: labels >= ~80 px apart.
double rulerStepSeconds(double pxPerSec, Rational fps) {
  final frame = fps.den / fps.num;
  final candidates = <double>[
    frame,
    frame * 2,
    frame * 5,
    frame * 10,
    0.5,
    1,
    2,
    5,
    10,
    15,
    30,
    60,
    120,
    300,
    600,
    900,
    1800,
    3600,
  ];
  for (final c in candidates) {
    if (c * pxPerSec >= 80) return c;
  }
  return 7200;
}
