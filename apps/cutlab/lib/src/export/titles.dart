import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cutlab_project_format/cutlab_project_format.dart';
import 'package:flutter/material.dart';

/// How titles look, relative to the height of the picture, so the monitor
/// and the exported video show them the same at any size.
class TitleLook {
  static double fontSize(double frameHeight) => frameHeight * 0.05;
  static double padding(double frameHeight) => frameHeight * 0.022;
  static double shadowBlur(double frameHeight) => frameHeight * 0.0167;

  /// Vertical place of the title box (as Alignment.y).
  static const alignY = 0.8;

  static TextStyle style(double frameHeight) => TextStyle(
        color: Colors.white,
        fontSize: fontSize(frameHeight),
        fontWeight: FontWeight.w800,
        shadows: [Shadow(blurRadius: shadowBlur(frameHeight))],
      );
}

/// A stretch of the timeline with the same titles on screen.
class TitleSpan {
  const TitleSpan(this.start, this.end, this.text);
  final int start;
  final int end;
  final String text;
}

/// The titles of [p] over time: every visible text clip, several at once
/// joined by line breaks (as the monitor shows them).
List<TitleSpan> titleSpans(Project p) {
  final clips = [
    for (final t in p.tracks)
      if (t.kind == TrackKind.text && !t.hidden)
        for (final c in t.clips)
          if ((c.data['text'] as String? ?? '').trim().isNotEmpty && c.durationTicks > 0) c,
  ];
  final edges = <int>{for (final c in clips) ...[c.startTicks, c.endTicks]}.toList()..sort();
  final spans = <TitleSpan>[];
  for (var i = 0; i + 1 < edges.length; i++) {
    final a = edges[i], b = edges[i + 1];
    final text = [
      for (final c in clips)
        if (c.startTicks <= a && a < c.endTicks) c.data['text'] as String,
    ].join('\n');
    if (text.isEmpty) continue;
    if (spans.isNotEmpty && spans.last.end == a && spans.last.text == text) {
      spans[spans.length - 1] = TitleSpan(spans.last.start, b, text);
    } else {
      spans.add(TitleSpan(a, b, text));
    }
  }
  return spans;
}

/// Draws each title for a [width] × [height] video into a raw RGBA file in
/// [dir] and returns the plan lines that place them ("overlay …").
Future<List<String>> renderTitleOverlays(List<TitleSpan> spans, int width, int height, Directory dir) async {
  final lines = <String>[];
  final h = height.toDouble();
  final pad = TitleLook.padding(h);
  final margin = (TitleLook.shadowBlur(h) * 2).ceil();
  final rendered = <String, (String, int, int, int, int)>{};
  for (final s in spans) {
    var r = rendered[s.text];
    if (r == null) {
      final painter = TextPainter(
        text: TextSpan(text: s.text, style: TitleLook.style(h)),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: math.max(1.0, width - 2 * pad));
      final w = painter.width.ceil() + 2 * margin;
      final ht = painter.height.ceil() + 2 * margin;
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), Offset(margin.toDouble(), margin.toDouble()));
      final image = await recorder.endRecording().toImage(w, ht);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      image.dispose();
      if (data == null) {
        painter.dispose();
        continue;
      }
      final file = File('${dir.path}/title_${rendered.length}.rgba');
      await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      // Same place as in the monitor: Align(0, 0.8) inside the padding.
      final availW = width - 2 * pad, availH = h - 2 * pad;
      final left = pad + (availW - painter.width) / 2 - margin;
      final top = pad + (availH - painter.height) * (1 + TitleLook.alignY) / 2 - margin;
      painter.dispose();
      r = (file.path, left.round(), top.round(), w, ht);
      rendered[s.text] = r;
    }
    lines.add('overlay ${s.start} ${s.end - s.start} ${r.$2} ${r.$3} ${r.$4} ${r.$5} ${r.$1}');
  }
  return lines;
}
