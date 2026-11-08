import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../engine/media_engine.dart';
import '../media/media_platform.dart';
import '../storage/app_settings.dart';

/// One abnormal end of CUTLAB, found when the app starts again.
class CrashReport {
  const CrashReport({required this.kind, required this.title, required this.text, required this.time});

  /// "native" (engine crash handler), "java" (Android Java/Kotlin crash) or
  /// "system" (Android's own record: crashes, out-of-memory kills, ANRs).
  final String kind;
  final String title;
  final String text;
  final DateTime time;

  /// The crash happened while a hardware video decoder was open.
  bool get duringHardwareDecoding => RegExp(r'hardware decoders open: [1-9]').hasMatch(text);

  /// Android ended CUTLAB because the phone ran out of memory.
  bool get lowMemory => title.contains('low memory');
}

/// Crash reports, device information and an error log, kept in the app's
/// diagnostics folder so a crash on the phone can be investigated later.
///
/// - Native crashes (engine/FFmpeg/MediaCodec): written by the engine's
///   signal handler with a backtrace, memory figures and the last engine
///   activity (codec, resolution, hardware or software decoding).
/// - Java/Kotlin crashes: written by MainActivity's handler.
/// - Android 11+: the system's own record of crashes and low-memory kills,
///   including crashes from older CUTLAB versions.
/// - Dart/Flutter errors: appended to errors.log.
class Diagnostics {
  Diagnostics(this.directory, {required this.device, required this.engine, required this.media, required this.version});

  final Directory directory;
  final Map<String, Object?> device;
  final MediaEngine engine;
  final MediaPlatform media;
  final String version;

  /// Problems found at this start (shown once to the user).
  final List<CrashReport> newCrashes = [];

  /// Something CUTLAB changed because of a crash (shown with the crashes).
  String? notice;

  static const _maxLogBytes = 256 * 1024;
  static const _maxHistory = 20;

  Directory get _history => Directory('${directory.path}${Platform.pathSeparator}history');
  File get _errorLog => File('${directory.path}${Platform.pathSeparator}errors.log');

  static Future<Diagnostics> start({required MediaEngine engine, required MediaPlatform media, required String appVersion}) async {
    var device = <String, Object?>{};
    try {
      device = Map<String, Object?>.of(await media.deviceInfo());
    } on Object catch (e) {
      device = {'error': 'device information unavailable: $e'};
    }
    var path = device['diagnosticsDir'] as String?;
    if (path == null) {
      final support = await getApplicationSupportDirectory();
      path = '${support.path}${Platform.pathSeparator}diagnostics';
    }
    final dir = Directory(path);
    await dir.create(recursive: true);
    final d = Diagnostics(dir, device: device, engine: engine, media: media, version: appVersion);
    await d.collect();
    if (engine.available) {
      try {
        engine.initDiagnostics(dir.path, d.deviceSummary);
      } on Object catch (e) {
        d.log('diagnostics', 'engine crash handler not installed: $e');
      }
    }
    d._hookErrors();
    return d;
  }

  String get deviceSummary {
    final summary = device['summary'] as String?;
    final base = summary ??
        [
          device['platform'],
          device['osVersion'],
          if (device['cpus'] != null) '${device['cpus']} CPUs',
        ].whereType<Object>().join(', ');
    return '$base · CUTLAB $version';
  }

  /// Moves crash reports left by the last run into the history and adds
  /// them (and Android's records) to [newCrashes].
  Future<void> collect() async {
    await _history.create(recursive: true);
    for (final (file, kind, title) in [
      ('native-crash.txt', 'native', 'CUTLAB closed because of an error in the video engine'),
      ('java-crash.txt', 'java', 'CUTLAB closed because of an error in the Android app'),
    ]) {
      final f = File('${directory.path}${Platform.pathSeparator}$file');
      if (!await f.exists()) continue;
      try {
        final text = await f.readAsString();
        final time = await f.lastModified();
        await _keep(kind, time, text);
        await f.delete();
        newCrashes.add(CrashReport(kind: kind, title: title, text: text, time: time));
      } on Object catch (e) {
        log('diagnostics', 'cannot read $file: $e');
      }
    }
    final exits = device['exits'];
    if (exits is List<Object?>) {
      for (final e in exits) {
        if (e is! Map<Object?, Object?>) continue;
        final time = DateTime.fromMillisecondsSinceEpoch((e['timeMs'] as num?)?.toInt() ?? 0);
        final process = '${e['process'] ?? ''}';
        final reason = '${e['reason'] ?? 'unknown'}';
        final text = StringBuffer()
          ..writeln('Android record of an abnormal end')
          ..writeln('time: ${time.toIso8601String()}')
          ..writeln('process: $process')
          ..writeln('reason: $reason')
          ..writeln('description: ${e['description'] ?? ''}')
          ..writeln('importance: ${e['importance']} · memory at the end: pss ${e['pssKB']} KB, rss ${e['rssKB']} KB')
          ..writeln('status: ${e['status']}');
        final trace = e['trace'];
        if (trace is String && trace.isNotEmpty) {
          text
            ..writeln()
            ..writeln('system crash record (readable parts):')
            ..writeln(trace);
        }
        await _keep('system', time, text.toString());
        if (process.endsWith(':hwprobe')) {
          // The hardware decoder test process: its crash is the protection
          // working (that kind of video is decoded in software from now on).
          continue;
        }
        newCrashes.add(CrashReport(kind: 'system', title: 'Android: $reason', text: text.toString(), time: time));
      }
    }
    await _trimHistory();
  }

  /// Settings to use after the crashes found at start-up: hardware decoding
  /// is switched off when CUTLAB closed while a hardware decoder was open.
  AppSettings settingsAfterCrashes(AppSettings s) {
    if (!s.hardwareDecoding || !newCrashes.any((c) => c.duringHardwareDecoding)) return s;
    notice = 'Hardware video decoding was turned off because CUTLAB closed while using it. '
        'Videos are decoded in software. You can turn it on again in Settings.';
    return s.copyWith(hardwareDecoding: false);
  }

  Future<void> _keep(String kind, DateTime time, String text) async {
    final stamp = time.toUtc().toIso8601String().replaceAll(':', '-').split('.').first;
    await File('${_history.path}${Platform.pathSeparator}$stamp-$kind.txt').writeAsString(text);
  }

  Future<void> _trimHistory() async {
    final files = await history();
    for (final f in files.skip(_maxHistory)) {
      try {
        await f.delete();
      } on Object {
        // Ignore: best effort.
      }
    }
  }

  /// Saved crash reports, newest first.
  Future<List<File>> history() async {
    if (!await _history.exists()) return [];
    final files = await _history.list().where((e) => e is File).cast<File>().toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  void _hookErrors() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      log('flutter', details.exceptionAsString(), details.stack);
      previous?.call(details);
    };
    final platformPrevious = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      log('dart', '$error', stack);
      return platformPrevious?.call(error, stack) ?? true;
    };
  }

  /// Appends an error to errors.log (kept under 256 KB) and the engine log.
  void log(String kind, String message, [StackTrace? stack]) {
    try {
      final rss = ProcessInfo.currentRss ~/ (1024 * 1024);
      final entry = StringBuffer('${DateTime.now().toIso8601String()} [$kind] rss=${rss}MB $message\n');
      if (stack != null) entry.writeln(stack.toString().split('\n').take(25).join('\n'));
      final f = _errorLog;
      if (f.existsSync() && f.lengthSync() > _maxLogBytes) {
        final text = f.readAsStringSync();
        f.writeAsStringSync(text.substring(text.length ~/ 2));
      }
      f.writeAsStringSync(entry.toString(), mode: FileMode.append, flush: true);
      engine.note('$kind error: ${message.split('\n').first}');
    } on Object {
      // Logging must never cause another error.
    }
  }

  Future<void> clearHistory() async {
    for (final f in await history()) {
      await f.delete();
    }
    if (await _errorLog.exists()) await _errorLog.delete();
  }

  /// Everything in one text, for copying or saving.
  Future<String> report() async {
    final b = StringBuffer()
      ..writeln('CUTLAB diagnostics report')
      ..writeln('version: $version')
      ..writeln('created: ${DateTime.now().toIso8601String()}')
      ..writeln()
      ..writeln('== Device');
    for (final e in device.entries) {
      if (e.value is List<Object?> || e.key == 'diagnosticsDir') continue;
      b.writeln('${e.key}: ${e.value}');
    }
    b
      ..writeln()
      ..writeln('== Media engine')
      ..writeln(engine.available
          ? 'FFmpeg ${engine.info.ffmpegVersion} · ${engine.info.cpus} CPUs · hardware decoders: ${engine.info.hardwareDecoders.join(', ')}'
          : 'not available: ${engine.info.reason}');
    void list(String title, Object? items) {
      if (items is! List<Object?> || items.isEmpty) return;
      b
        ..writeln()
        ..writeln('== $title');
      for (final i in items) {
        b.writeln('$i');
      }
    }

    list('Video decoders on this device', device['decoders']);
    list('Hardware decoding checks (per kind of video)', device['hardwareChecks']);
    b
      ..writeln()
      ..writeln('== Recent engine activity')
      ..writeln(engine.recentActivity());
    final files = await history();
    b
      ..writeln()
      ..writeln('== Crash history (${files.length})');
    var budget = 60000;
    for (final f in files) {
      final text = await f.readAsString();
      b
        ..writeln('--- ${f.uri.pathSegments.last}')
        ..writeln(text.length > budget ? text.substring(0, budget) : text);
      budget -= text.length;
      if (budget <= 0) break;
    }
    if (await _errorLog.exists()) {
      final text = await _errorLog.readAsString();
      b
        ..writeln()
        ..writeln('== Dart/Flutter errors (latest)')
        ..writeln(text.length > 20000 ? text.substring(text.length - 20000) : text);
    }
    return b.toString();
  }
}
