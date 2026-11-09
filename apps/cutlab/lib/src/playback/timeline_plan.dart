import 'package:cutlab_project_format/cutlab_project_format.dart';

/// What the native timeline renderer plays, as the text it reads
/// (format: docs/PLAYBACK.md).
class TimelinePlan {
  const TimelinePlan(this.text, this.trackIds, this.clipCount);

  final String text;

  /// Track ids in plan order (the order of the renderer's level meters).
  final List<String> trackIds;
  final int clipCount;
}

/// Builds the plan for [p]. [engineUris] maps media ids to what the engine
/// opens (a path, or "fd:N" on Android); clips whose media has no entry
/// (missing or not yet opened) are left out, so they play as black/silence.
///
/// Text tracks are not part of the plan: titles are drawn by the monitor.
/// Clip speed and reverse are not supported yet: such clips play at normal
/// speed (the editor has no control for them yet).
///
/// Effects (enabled ones of known types, in stack order), video fades and
/// transitions go into the plan exactly as the export renders them; the
/// engine composes the same picture for the preview and the file.
/// [previewHeight] (preview quality) limits the preview picture only; 0 =
/// the player's own size. The export passes 0.
TimelinePlan buildTimelinePlan(Project p, Map<String, String> engineUris, {required bool hardware, int previewHeight = 0}) {
  final fps = p.settings.frameRate;
  final b = StringBuffer('cutlab-timeline 1\n')
    ..writeln('master ${_num(p.masterVolume)}')
    ..writeln('hardware ${hardware ? 1 : 0}')
    ..writeln('canvas ${p.settings.width} ${p.settings.height}')
    ..writeln('fps ${fps.num} ${fps.den}');
  if (previewHeight > 0) b.writeln('preview $previewHeight');
  final ids = <String>[];
  final styling = StringBuffer();
  var clips = 0;
  for (final t in p.tracks) {
    if (t.kind == TrackKind.text) continue;
    ids.add(t.id);
    b.writeln('track ${_token(t.id)} ${t.kind.name} ${_bit(t.muted)} ${_bit(t.solo)} ${_bit(t.hidden)} ${_num(t.volume)}');
    final visual = t.kind == TrackKind.video || t.kind == TrackKind.image;
    final written = <String>{};
    for (var i = 0; i < t.clips.length; i++) {
      final c = t.clips[i];
      final m = c.mediaId == null ? null : p.mediaById(c.mediaId);
      final uri = m == null ? null : engineUris[m.id];
      if (m == null || uri == null || c.durationTicks <= 0) continue;
      final still = m.kind == MediaKind.image;
      final audio = switch (t.kind) {
        TrackKind.audio => m.kind != MediaKind.image,
        TrackKind.video => m.kind == MediaKind.video && m.hasAudio,
        _ => false,
      };
      b.writeln('clip ${_token(c.id)} ${c.startTicks} ${c.durationTicks} ${still ? 0 : c.sourceInTicks} ${_num(c.volume)} '
          '${c.fadeInTicks} ${c.fadeOutTicks} ${_bit(audio)} ${_bit(still)} 1 ${_line(uri)}');
      written.add(c.id);
      clips++;
      if (!visual) continue;
      for (final e in c.effects) {
        if (!effectRenders(e)) continue;
        final spec = effectSpec(e.type)!;
        styling.writeln('effect ${_token(c.id)} ${e.type} ${[
          for (final prm in spec.params) '${prm.name}=${effectParam(e, prm.name).toStringAsFixed(6)}'
        ].join(',')}');
      }
      if (c.videoFadeInTicks > 0 || c.videoFadeOutTicks > 0) {
        styling.writeln('vfade ${_token(c.id)} ${c.videoFadeInTicks} ${c.videoFadeOutTicks}');
      }
      // Both clips of a transition must be in the plan.
      final span = transitionSpan(p, t, i);
      if (span != null && span.active && written.contains(t.clips[i - 1].id)) {
        styling.writeln('transition ${_token(c.id)} ${span.spec.type} ${span.left} ${span.right} ${span.direction}');
      }
    }
  }
  b.write(styling);
  return TimelinePlan(b.toString(), ids, clips);
}

String _bit(bool v) => v ? '1' : '0';
String _num(double v) => v.toStringAsFixed(4);

/// Ids are written as single words.
String _token(String id) => id.replaceAll(RegExp(r'\s'), '_');

/// The uri is the rest of its line: it may contain spaces, not line breaks.
String _line(String uri) => uri.replaceAll(RegExp(r'[\r\n]'), ' ');
