import 'dart:async';
import 'dart:io';

import 'package:cutlab_project_format/cutlab_project_format.dart';
import 'package:flutter/foundation.dart';

import '../engine/media_engine.dart';
import '../media/media_platform.dart';
import '../playback/timeline_plan.dart';
import 'export_settings.dart';
import 'titles.dart';

enum ExportPhase { setup, starting, rendering, publishing, done, failed }

/// Runs one video export of a project: settings, encoder check, the engine
/// job, progress, pause for heat, publishing and checking the finished file.
class ExportController extends ChangeNotifier {
  ExportController({
    required this.project,
    required this.media,
    required this.engine,
    required this.engineUri,
    required this.isAvailable,
    required this.hardwareDecoding,
    required this.workDir,
    VideoExportSettings? settings,
    this.pollInterval = const Duration(milliseconds: 250),
    this.conditionInterval = const Duration(seconds: 5),
    DateTime Function()? clock,
  })  : _settings = settings ?? lastSettings ?? VideoExportSettings.forProject(project),
        _clock = clock ?? DateTime.now;

  /// The settings of the last export in this run of the app.
  static VideoExportSettings? lastSettings;

  final Project project;
  final MediaPlatform media;
  final MediaEngine engine;
  final Future<String> Function(MediaRef m) engineUri;
  final bool? Function(String mediaId) isAvailable;

  /// Whether hardware decoding may be used for this project's videos.
  final Future<bool> Function() hardwareDecoding;

  /// Folder for the title pictures of this export.
  final Future<Directory> Function() workDir;
  final Duration pollInterval;
  final Duration conditionInterval;
  final DateTime Function() _clock;

  VideoExportSettings _settings;
  ExportPhase _phase = ExportPhase.setup;
  List<EncoderInfo>? _encoders;
  bool _checkingEncoders = false;
  String? _encoderProblem;
  ExportJob? _job;
  ExportStatus _status = const ExportStatus();
  Timer? _poll;
  DateTime _lastNotice = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastCondition = DateTime.fromMillisecondsSinceEpoch(0);
  DeviceCondition _condition = DeviceCondition.unknown;
  bool _pausedForHeat = false;
  bool _userPaused = false;
  String? _error;
  String? _target;
  String? _fileName;
  ExportedFile? _result;
  ProbeInfo? _verified;
  final List<String> _verifyProblems = [];
  final List<String> _missing = [];
  Directory? _titles;
  bool _disposed = false;

  VideoExportSettings get settings => _settings;
  ExportPhase get phase => _phase;
  List<EncoderInfo>? get encoders => _encoders;
  bool get checkingEncoders => _checkingEncoders;
  String? get encoderProblem => _encoderProblem;
  ExportStatus get status => _status;
  DeviceCondition get condition => _condition;
  bool get pausedForHeat => _pausedForHeat;
  bool get paused => _userPaused || _pausedForHeat;
  String? get error => _error;
  ExportedFile? get result => _result;
  ProbeInfo? get verified => _verified;
  List<String> get verifyProblems => List.unmodifiable(_verifyProblems);

  /// Media used in the timeline that cannot be read (exported as black/silence).
  List<String> get missingMedia => List.unmodifiable(_missing);
  bool get running => _phase == ExportPhase.starting || _phase == ExportPhase.rendering || _phase == ExportPhase.publishing;

  int get durationTicks => project.durationTicks;
  (int, int) get outputSize => _settings.sizeFor(project.settings.width, project.settings.height);
  int get estimatedBytes => _settings.estimatedBytes(durationTicks, outputSize.$1, outputSize.$2);

  void update(VideoExportSettings s) {
    if (running) return;
    _settings = s;
    _notify();
  }

  /// Which encoders work here (hardware ones tested once; Android: in a
  /// separate process so a faulty vendor encoder cannot close the app).
  Future<void> loadEncoders({bool force = false}) async {
    _checkingEncoders = true;
    _notify();
    try {
      final tested = await media.testedEncoders(force: force);
      if (tested == null) {
        _encoders = await engine.encoders(probe: true);
      } else if (tested.isEmpty) {
        // The hardware test failed or crashed: software encoders only.
        _encoders = [
          for (final e in await engine.encoders())
            if (!e.hardware) e
        ];
      } else {
        _encoders = tested;
      }
      _encoderProblem = _encoders!.isEmpty ? (engine.info.reason ?? 'This build has no video encoders.') : null;
    } on Object catch (e) {
      _encoders = const [];
      _encoderProblem = 'Could not list the encoders: $e';
    }
    _checkingEncoders = false;
    if (_encoders!.isNotEmpty && !codecAvailable(_settings.codec)) {
      final first = ExportCodec.values.where(codecAvailable).firstOrNull;
      if (first != null) _settings = _settings.copyWith(codec: first);
    }
    _notify();
  }

  /// Encoders the export will try for [codec], in order.
  List<EncoderInfo> encodersFor(ExportCodec codec, {bool? hardware}) {
    final hw = hardware ?? _settings.hardware;
    return [
      for (final e in _encoders ?? const <EncoderInfo>[])
        if (e.codec == codec.name && e.usable && (hw || !e.hardware)) e,
    ];
  }

  bool codecAvailable(ExportCodec codec) => encodersFor(codec, hardware: true).isNotEmpty;

  /// The encoder that will be used first (null: none).
  EncoderInfo? get encoder => encodersFor(_settings.codec).firstOrNull;

  /// Starts the export. Returns false when the user cancelled choosing
  /// where to save, or it could not start (see [error]).
  Future<bool> start() async {
    if (running) return false;
    ExportController.lastSettings = _settings;
    final s = _settings;
    final order = encodersFor(s.codec);
    if (order.isEmpty) {
      _fail('No ${s.codec.label} encoder works on this device.');
      return false;
    }
    _fileName = s.fileName(safeFileName(project.name), _clock());
    final target = await media.exportTarget(_fileName!);
    if (target == null || _disposed) return false;
    _target = target;
    _phase = ExportPhase.starting;
    _error = null;
    _result = null;
    _verified = null;
    _verifyProblems.clear();
    _status = const ExportStatus();
    _notify();
    try {
      final (w, h) = outputSize;
      final plan = await _plan(w, h);
      final text =
          '${s.engineText(path: target, width: w, height: h)}encoder ${order.map((e) => '${e.name}/${e.hardware ? 'hw' : 'sw'}').join(',')}\n';
      _job = engine.startExport(plan, text);
    } on Object catch (e) {
      _fail('The export could not start: $e');
      return false;
    }
    _phase = ExportPhase.rendering;
    _userPaused = false;
    _pausedForHeat = false;
    unawaited(media.startBackgroundWork('Exporting "${project.name}"').catchError((Object _) {}));
    _poll = Timer.periodic(pollInterval, (_) => _tick());
    _notify();
    return true;
  }

  Future<String> _plan(int width, int height) async {
    final uris = <String, String>{};
    _missing.clear();
    for (final m in project.media) {
      if (project.clipsUsingMedia(m.id) == 0) continue;
      if (isAvailable(m.id) == false) {
        _missing.add(m.displayName);
        continue;
      }
      try {
        uris[m.id] = await engineUri(m);
      } on Object {
        _missing.add(m.displayName);
      }
    }
    final hw = await hardwareDecoding();
    final b = StringBuffer(buildTimelinePlan(project, uris, hardware: hw).text)..writeln('duration ${project.durationTicks}');
    final spans = titleSpans(project);
    if (spans.isNotEmpty) {
      final dir = await workDir();
      _titles = await dir.createTemp('titles');
      for (final line in await renderTitleOverlays(spans, width, height, _titles!)) {
        b.writeln(line);
      }
    }
    return b.toString();
  }

  void _tick() {
    final job = _job;
    if (job == null || _disposed) return;
    _status = job.status();
    final now = _clock();
    if (now.difference(_lastNotice) >= const Duration(seconds: 1)) {
      _lastNotice = now;
      final left = _status.etaMs >= 0 ? ' · ${formatDuration(Duration(milliseconds: _status.etaMs))} left' : '';
      unawaited(
          media.updateBackgroundWork('${(_status.progress * 100).toStringAsFixed(0)}%$left', _status.progress).catchError((Object _) {}));
    }
    if (now.difference(_lastCondition) >= conditionInterval) {
      _lastCondition = now;
      unawaited(_checkCondition());
    }
    if (_status.finished) {
      unawaited(_finish());
    } else {
      _notify();
    }
  }

  /// Too hot: pause until the phone has cooled down (Android thermal status).
  Future<void> _checkCondition() async {
    try {
      _condition = await media.deviceCondition();
    } on Object {
      return;
    }
    final job = _job;
    if (job == null || _disposed) return;
    if (_condition.hot && !_pausedForHeat) {
      _pausedForHeat = true;
      job.pause(true);
    } else if (_pausedForHeat && _condition.cooledDown) {
      _pausedForHeat = false;
      if (!_userPaused) job.pause(false);
    }
    _notify();
  }

  void togglePause() {
    final job = _job;
    if (job == null || _phase != ExportPhase.rendering) return;
    _userPaused = !_userPaused;
    job.pause(_userPaused || _pausedForHeat);
    _status = job.status();
    _notify();
  }

  /// Stops the export; nothing is left behind.
  void cancel() {
    _job?.cancel();
  }

  /// After a failure with a hardware encoder: the same export in software.
  Future<bool> retryInSoftware() async {
    _settings = _settings.copyWith(hardware: false);
    _phase = ExportPhase.setup;
    return start();
  }

  /// Back to the settings after a finished, failed or cancelled export.
  void reset() {
    if (running) return;
    _phase = ExportPhase.setup;
    _notify();
  }

  Future<void> _finish() async {
    _poll?.cancel();
    _poll = null;
    final job = _job;
    _job = null;
    if (job == null) return;
    final st = job.status();
    _status = st;
    job.dispose();
    unawaited(media.stopBackgroundWork().catchError((Object _) {}));
    await _cleanTitles();
    if (st.state == ExportState.cancelled) {
      _phase = ExportPhase.setup;
      _notify();
      return;
    }
    if (st.state != ExportState.done) {
      _fail(st.error.isEmpty ? 'The export failed.' : st.error);
      return;
    }
    _phase = ExportPhase.publishing;
    _notify();
    try {
      _result = await media.publishExport(_target!, _fileName!, _settings.container.mime);
    } on Object catch (e) {
      _fail('The video was rendered but could not be saved: $e');
      return;
    }
    await _verify();
    _phase = ExportPhase.done;
    _notify();
  }

  /// Reads the finished file back and compares it with what was asked.
  Future<void> _verify() async {
    final r = _result;
    if (r == null) return;
    String? euri;
    try {
      euri = await media.openForEngine(r.uri);
      final info = await engine.probe(euri);
      _verified = info;
      final (w, h) = outputSize;
      if (info.width != w || info.height != h) _verifyProblems.add('size is ${info.width}×${info.height}, expected $w×$h');
      final rate = info.frameRate;
      if (rate == null || (rate.num / rate.den - _settings.fps).abs() > 0.01) {
        _verifyProblems
            .add('frame rate is ${rate == null ? 'unknown' : (rate.num / rate.den).toStringAsFixed(2)}, expected ${_settings.fpsLabel}');
      }
      final frameTicks = ticksPerSecond * _settings.frameRate.den ~/ _settings.frameRate.num;
      if ((info.durationTicks - durationTicks).abs() > frameTicks * 2) {
        _verifyProblems.add(
            'length is ${formatDuration(ticksToDuration(info.durationTicks))}, expected ${formatDuration(ticksToDuration(durationTicks))}');
      }
      if (info.videoCodec != _settings.codec.name) {
        _verifyProblems.add('video codec is ${info.videoCodec}, expected ${_settings.codec.name}');
      }
      if (info.audioCodec == null) _verifyProblems.add('no sound track');
    } on Object catch (e) {
      _verifyProblems.add('the file could not be read back: $e');
    } finally {
      if (euri != null) await media.closeForEngine(euri).catchError((Object _) {});
    }
  }

  void _fail(String message) {
    _error = message;
    _phase = ExportPhase.failed;
    _notify();
  }

  Future<void> _cleanTitles() async {
    final d = _titles;
    _titles = null;
    if (d != null) {
      try {
        await d.delete(recursive: true);
      } on Object {
        // Temporary files only.
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    final job = _job;
    _job = null;
    if (job != null) {
      job.cancel();
      job.dispose();
      unawaited(media.stopBackgroundWork().catchError((Object _) {}));
    }
    unawaited(_cleanTitles());
    super.dispose();
  }
}
