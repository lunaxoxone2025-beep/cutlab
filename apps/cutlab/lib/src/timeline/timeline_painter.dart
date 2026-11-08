import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:cutlab_project_format/cutlab_project_format.dart' as pf show Clip;
import 'package:flutter/material.dart';

import '../format.dart';
import '../theme.dart';
import 'timeline_assets.dart';
import 'timeline_state.dart';

const double handleWidth = 12;

/// Draws the ruler, all track lanes, the visible clips (with thumbnails or
/// waveforms), selection, trim handles, snap guide and playhead in one pass.
/// Only clips intersecting the visible time range are drawn, so long
/// projects with many clips stay smooth.
class TimelinePainter extends CustomPainter {
  TimelinePainter({required this.project, required this.state, required this.assets, required this.rows, required Listenable repaint})
      : super(repaint: repaint);

  final Project project;
  final TimelineState state;
  final TimelineAssets assets;
  final List<TrackRow> rows;

  static Color colorFor(TrackKind k) => switch (k) {
        TrackKind.video => CutlabColors.videoTrack,
        TrackKind.audio => CutlabColors.audioTrack,
        TrackKind.text => CutlabColors.textTrack,
        TrackKind.image => CutlabColors.imageTrack,
      };

  @override
  void paint(Canvas canvas, Size size) {
    final p = state.preview ?? project;
    final rowsNow = state.preview == null ? rows : layoutTracks(p);
    final t0 = state.ticksAtX(0);
    final t1 = state.ticksAtX(size.width);

    // Lanes.
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, rulerHeight, size.width, size.height - rulerHeight));
    for (final r in rowsNow) {
      final top = rulerHeight + r.top - state.scrollY;
      if (top > size.height || top + r.height < rulerHeight) continue;
      final lane = Rect.fromLTWH(0, top, size.width, r.height);
      canvas.drawRect(lane, Paint()..color = CutlabColors.surfaceRaised.withAlpha(r.track.locked ? 90 : 140));
      for (final c in r.track.clips) {
        if (c.endTicks < t0 || c.startTicks > t1) continue;
        _paintClip(canvas, size, p, r, top, c);
      }
    }
    canvas.restore();

    _paintRuler(canvas, size, t0, t1);

    // Snap guide and playhead.
    final guide = state.snapGuide;
    if (guide != null) {
      final x = state.xOf(guide);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), Paint()
        ..color = const Color(0xFFFFD54F)
        ..strokeWidth = 1);
    }
    final px = state.xOf(state.playhead);
    if (px >= -2 && px <= size.width + 2) {
      canvas.drawLine(Offset(px, 0), Offset(px, size.height), Paint()
        ..color = Colors.white
        ..strokeWidth = 2);
      final head = Path()
        ..moveTo(px - 7, 0)
        ..lineTo(px + 7, 0)
        ..lineTo(px + 7, 10)
        ..lineTo(px, 17)
        ..lineTo(px - 7, 10)
        ..close();
      canvas.drawPath(head, Paint()..color = Colors.white);
    }
  }

  void _paintClip(Canvas canvas, Size size, Project p, TrackRow r, double top, pf.Clip c) {
    final x0 = state.xOf(c.startTicks);
    final x1 = state.xOf(c.endTicks);
    final rect = Rect.fromLTRB(x0 + 0.5, top + 2, math.max(x0 + 2, x1 - 0.5), top + r.height - 2);
    final visible = Rect.fromLTRB(math.max(rect.left, -4), rect.top, math.min(rect.right, size.width + 4), rect.bottom);
    if (visible.width <= 0) return;
    final rr = RRect.fromRectAndRadius(rect, const Radius.circular(6));
    final dim = r.track.hidden || (r.track.muted && r.track.kind == TrackKind.audio);
    final base = colorFor(r.track.kind);
    canvas.save();
    canvas.clipRRect(rr);
    canvas.drawRect(visible, Paint()..color = dim ? base.withAlpha(90) : base);

    final m = p.mediaById(c.mediaId);
    if (m != null && (r.track.kind == TrackKind.video || r.track.kind == TrackKind.image)) {
      _paintThumbnails(canvas, visible, rect, c, m);
    }
    if (m != null && r.track.kind == TrackKind.audio) {
      _paintWaveform(canvas, visible, rect, c, m);
    }
    if (dim) canvas.drawRect(visible, Paint()..color = Colors.black.withAlpha(120));
    if (r.track.locked) {
      final stripe = Paint()
        ..color = Colors.white.withAlpha(25)
        ..strokeWidth = 6;
      for (var x = visible.left - rect.height; x < visible.right; x += 16) {
        canvas.drawLine(Offset(x, rect.bottom), Offset(x + rect.height, rect.top), stripe);
      }
    }
    _paintFades(canvas, rect, c);

    // Label.
    final label = m?.displayName ?? (c.data['text'] as String? ?? 'Text');
    final link = c.linkId != null ? '\u{1F517} ' : '';
    final vol = (r.track.kind == TrackKind.audio || r.track.kind == TrackKind.video) && c.volume != 1.0
        ? '  ${(c.volume * 100).round()}%'
        : '';
    final tp = TextPainter(
      text: TextSpan(
        text: '$link$label$vol',
        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600, shadows: [Shadow(blurRadius: 3)]),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(0, visible.width - 10));
    tp.paint(canvas, Offset(math.max(rect.left, 0) + 6, rect.top + 3));
    canvas.restore();

    final selected = state.selection.contains(c.id);
    if (selected) {
      canvas.drawRRect(
          rr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = CutlabColors.accent);
      if (!r.track.locked) {
        final hp = Paint()..color = Colors.white;
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(rect.left, rect.top, 6, rect.height), const Radius.circular(3)), hp);
        canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromLTWH(rect.right - 6, rect.top, 6, rect.height), const Radius.circular(3)), hp);
      }
    }
  }

  void _paintThumbnails(Canvas canvas, Rect visible, Rect rect, pf.Clip c, MediaRef m) {
    final thumbs = assets.thumbnails(m);
    if (thumbs == null || thumbs.isEmpty) return;
    final tileW = rect.height * 16 / 9;
    final paint = Paint()..filterQuality = FilterQuality.low;
    // Tiles aligned to the clip start so they do not swim while scrolling.
    final firstTile = ((visible.left - rect.left) / tileW).floor();
    for (var i = math.max(0, firstTile); rect.left + i * tileW < visible.right; i++) {
      final x = rect.left + i * tileW;
      final tAtTile = state.ticksAtX(x + tileW / 2).clamp(c.startTicks, c.endTicks);
      final src = project.sourceTimeAt(c, tAtTile);
      final img = _nearest(thumbs, src);
      final dst = Rect.fromLTWH(x, rect.top, tileW, rect.height);
      final s = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
      canvas.drawImageRect(img, _cover(s, dst), dst, paint);
    }
  }

  static Rect _cover(Rect src, Rect dst) {
    final scale = math.max(dst.width / src.width, dst.height / src.height);
    final w = dst.width / scale, h = dst.height / scale;
    return Rect.fromLTWH((src.width - w) / 2, (src.height - h) / 2, w, h);
  }

  static ui.Image _nearest(List<(int, ui.Image)> thumbs, int t) {
    var lo = 0, hi = thumbs.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (thumbs[mid].$1 <= t) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return thumbs[lo].$2;
  }

  void _paintWaveform(Canvas canvas, Rect visible, Rect rect, pf.Clip c, MediaRef m) {
    final peaks = assets.peaks(m);
    if (peaks == null || peaks.length == 0) return;
    final mid = rect.center.dy;
    final amp = rect.height / 2 - 3;
    final gain = c.volume.clamp(0.0, 2.0);
    final paint = Paint()
      ..color = Colors.white.withAlpha(150)
      ..strokeWidth = 1;
    for (var x = visible.left.floorToDouble(); x < visible.right; x += 2) {
      final ta = project.sourceTimeAt(c, state.ticksAtX(x).clamp(c.startTicks, c.endTicks));
      final tb = project.sourceTimeAt(c, state.ticksAtX(x + 2).clamp(c.startTicks, c.endTicks));
      final a = (ta * peaks.bucketsPerSecond) ~/ ticksPerSecond;
      var b = (tb * peaks.bucketsPerSecond) ~/ ticksPerSecond;
      if (a >= peaks.length) break;
      b = b.clamp(a + 1, peaks.length);
      var lo = 0.0, hi = 0.0;
      for (var i = a; i < b; i++) {
        lo = math.min(lo, peaks.pairs[2 * i]);
        hi = math.max(hi, peaks.pairs[2 * i + 1]);
      }
      canvas.drawLine(Offset(x, mid - (hi * gain).clamp(-1.0, 1.0) * amp), Offset(x, mid - (lo * gain).clamp(-1.0, 1.0) * amp), paint);
    }
  }

  void _paintFades(Canvas canvas, Rect rect, pf.Clip c) {
    final paint = Paint()..color = Colors.black.withAlpha(110);
    if (c.fadeInTicks > 0) {
      final w = c.fadeInTicks / ticksPerSecond * state.pxPerSec;
      canvas.drawPath(
          Path()
            ..moveTo(rect.left, rect.top)
            ..lineTo(rect.left + w, rect.top)
            ..lineTo(rect.left, rect.bottom)
            ..close(),
          paint);
    }
    if (c.fadeOutTicks > 0) {
      final w = c.fadeOutTicks / ticksPerSecond * state.pxPerSec;
      canvas.drawPath(
          Path()
            ..moveTo(rect.right, rect.top)
            ..lineTo(rect.right - w, rect.top)
            ..lineTo(rect.right, rect.bottom)
            ..close(),
          paint);
    }
  }

  void _paintRuler(Canvas canvas, Size size, int t0, int t1) {
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, rulerHeight), Paint()..color = CutlabColors.surface);
    final step = rulerStepSeconds(state.pxPerSec, project.fps);
    final stepTicks = (step * ticksPerSecond).round();
    if (stepTicks <= 0) return;
    final first = (math.max(0, t0) ~/ stepTicks) * stepTicks;
    final tick = Paint()
      ..color = CutlabColors.textMuted
      ..strokeWidth = 1;
    final showFrames = step < 1;
    for (var t = first; t <= t1; t += stepTicks) {
      final x = state.xOf(t);
      canvas.drawLine(Offset(x, rulerHeight - 8), Offset(x, rulerHeight), tick);
      final label = showFrames ? formatTimecode(t, project.fps).substring(3) : formatDuration(t);
      final tp = TextPainter(
        text: TextSpan(text: label, style: const TextStyle(color: CutlabColors.textMuted, fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x + 3, 3));
      // Minor ticks.
      for (var k = 1; k < 4; k++) {
        final mx = x + k * step * state.pxPerSec / 4;
        canvas.drawLine(Offset(mx, rulerHeight - 4), Offset(mx, rulerHeight), tick);
      }
    }
    canvas.drawLine(const Offset(0, rulerHeight - 0.5), Offset(size.width, rulerHeight - 0.5), Paint()..color = CutlabColors.outline);
  }

  @override
  bool shouldRepaint(TimelinePainter old) =>
      old.project != project || old.state != state || old.assets != assets || old.rows != rows;
}
