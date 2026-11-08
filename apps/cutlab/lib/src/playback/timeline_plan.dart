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
TimelinePlan buildTimelinePlan(Project p, Map<String, String> engineUris, {required bool hardware}) {
  final b = StringBuffer('cutlab-timeline 1\n')
    ..writeln('master ${_num(p.masterVolume)}')
    ..writeln('hardware ${hardware ? 1 : 0}');
  final ids = <String>[];
  var clips = 0;
  for (final t in p.tracks) {
    if (t.kind == TrackKind.text) continue;
    ids.add(t.id);
    b.writeln('track ${_token(t.id)} ${t.kind.name} ${_bit(t.muted)} ${_bit(t.solo)} ${_bit(t.hidden)} ${_num(t.volume)}');
    for (final c in t.clips) {
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
      clips++;
    }
  }
  return TimelinePlan(b.toString(), ids, clips);
}

String _bit(bool v) => v ? '1' : '0';
String _num(double v) => v.toStringAsFixed(4);

/// Ids are written as single words.
String _token(String id) => id.replaceAll(RegExp(r'\s'), '_');

/// The uri is the rest of its line: it may contain spaces, not line breaks.
String _line(String uri) => uri.replaceAll(RegExp(r'[\r\n]'), ' ');
