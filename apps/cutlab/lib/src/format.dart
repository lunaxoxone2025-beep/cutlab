import 'package:cutlab_project_format/cutlab_project_format.dart';

/// Formats ticks as HH:MM:SS:FF using exact integer frame math.
String formatTimecode(int ticks, Rational fps) {
  final frames = ticksToFrames(ticks, fps);
  final nominal = (fps.num / fps.den).round();
  final ff = frames % nominal;
  final total = frames ~/ nominal;
  return '${_two(total ~/ 3600)}:${_two(total ~/ 60 % 60)}:${_two(total % 60)}:${_two(ff)}';
}

/// "1:23:45" or "3:07" for media durations.
String formatDuration(int ticks) {
  final s = ticks ~/ ticksPerSecond;
  final h = s ~/ 3600;
  final m = s ~/ 60 % 60;
  return h > 0 ? '$h:${_two(m)}:${_two(s % 60)}' : '$m:${_two(s % 60)}';
}

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return i == 0 ? '$bytes B' : '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

String formatFps(Rational r) => r.den == 1 ? '${r.num}' : r.toDouble().toStringAsFixed(2);

/// Local date and time, "2026-11-08 14:05".
String formatDateTime(DateTime t) {
  final l = t.toLocal();
  return '${l.year}-${_two(l.month)}-${_two(l.day)} ${_two(l.hour)}:${_two(l.minute)}';
}

String _two(int v) => v.toString().padLeft(2, '0');
