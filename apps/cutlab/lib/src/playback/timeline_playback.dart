import 'dart:async';
import 'dart:ui' as ui;

import 'package:cutlab_project_format/cutlab_project_format.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import '../editor/editor_controller.dart';
import '../engine/media_engine.dart';
import '../storage/app_settings.dart';
import '../timeline/timeline_assets.dart';
import '../timeline/timeline_state.dart';
import 'timeline_plan.dart';

/// Plays the edited timeline: keeps the native renderer's plan in step with
/// the project, moves the timeline cursor with the audio clock while
/// playing, follows the cursor when the user moves it, and exposes the
/// picture, the level meters and the playback statistics.
class TimelinePlayback extends ChangeNotifier {
  TimelinePlayback({required this.controller, required this.state, required this.assets, required this.settings}) {
    final s = settings.value;
    try {
      _r = controller.engine.openTimeline(maxWidth: s.previewMaxWidth, maxHeight: s.previewMaxHeight);
    } on Object catch (e) {
      unavailable = '$e';
    }
    _ticker = Ticker(_onTick, debugLabel: 'timeline playback');
    // In the background (Android may take the window, audio route or
    // memory): stop playing; the position is kept.
    _lifecycle = AppLifecycleListener(onHide: pause);
    controller.addListener(_projectChanged);
    state.addListener(_stateChanged);
    _lastPreview = state.preview;
    _scheduleSync();
  }

  final EditorController controller;
  final TimelineState state;
  final TimelineAssets assets;
  final ValueListenable<AppSettings> settings;

  TimelineRenderer? _r;
  late final Ticker _ticker;
  late final AppLifecycleListener _lifecycle;

  /// Why playback is not available (no media engine), or null.
  String? unavailable;

  /// Timeline width in pixels, to keep the cursor in view while playing.
  double viewportWidth = 0;

  ui.Image? _image;
  bool _black = true;
  bool _decoding = false;
  RgbaImage? _pending;

  bool _playing = false;
  int _playStart = 0;
  int _lastPushed = -1;
  bool _wasScrubbing = false;
  Project? _lastPreview;
  Duration _awakeUntil = Duration.zero;
  Duration _lastTick = Duration.zero;
  Duration _lastStats = Duration.zero;
  bool _disposed = false;

  String _planText = '';
  String _pictureKey = '';
  List<String> _trackIds = const [];
  int _syncGeneration = 0;
  Timer? _syncTimer;
  final Map<String, bool> _hardwareOk = {};

  final Map<String, double> _levels = {};
  double _master = 0;
  TimelineStats stats = const TimelineStats();

  bool get available => _r != null;
  bool get playing => _playing;

  /// The picture at the cursor; null with [isBlack] = nothing to show.
  ui.Image? get image => _black ? null : _image;
  bool get isBlack => _black;

  /// Meter level (0..1, peak, smoothed) of a track and of the master.
  double levelOf(String trackId) => _levels[trackId] ?? 0;
  double get masterLevel => _master;

  // ------------------------------------------------------------- transport

  void play() {
    final r = _r;
    final p = controller.project;
    if (r == null || p.durationTicks <= 0 || _playing) return;
    if (state.playhead >= p.durationTicks) {
      _push(0);
      r.seek(0);
    }
    _playStart = state.playhead;
    r.play();
    _playing = true;
    controller.engine.note('timeline play from ${state.playhead}');
    _wake(const Duration(days: 1));
    notifyListeners();
  }

  void pause() {
    final r = _r;
    if (r == null || !_playing) return;
    r.pause();
    _playing = false;
    _push(r.positionTicks);
    r.seek(state.playhead); // exactly the frame under the cursor
    _wake();
    _resetLevels();
    notifyListeners();
  }

  /// Stops and returns the cursor to where playback started.
  void stop() {
    if (_playing) pause();
    _r?.seek(_playStart);
    _push(_playStart);
    _wake();
    notifyListeners();
  }

  void toggle() => _playing ? pause() : play();

  // ------------------------------------------------------------ plan sync

  void _projectChanged() => _scheduleSync();

  void _stateChanged() {
    if (!identical(state.preview, _lastPreview)) {
      _lastPreview = state.preview;
      _scheduleSync();
    }
    final r = _r;
    if (r == null) return;
    final t = state.playhead;
    final scrubEnded = _wasScrubbing && !state.scrubbing;
    _wasScrubbing = state.scrubbing;
    if (t == _lastPushed && !scrubEnded) return; // our own cursor update
    _lastPushed = t;
    // The user moved the cursor: play on from there (or show that frame).
    r.seek(t, accurate: !state.scrubbing);
    if (!_playing) _wake();
  }

  void _scheduleSync() {
    if (_disposed) return;
    _syncTimer?.cancel();
    // Coalesce bursts (slider drags, typing) into one plan update.
    _syncTimer = Timer(const Duration(milliseconds: 30), () => unawaited(_sync()));
  }

  Future<void> _sync() async {
    final r = _r;
    if (r == null || _disposed) return;
    final gen = ++_syncGeneration;
    final p = state.preview ?? controller.project;
    final uris = <String, String>{};
    for (final m in p.media) {
      if (p.clipsUsingMedia(m.id) == 0 || controller.isAvailable(m.id) == false) continue;
      try {
        uris[m.id] = await assets.engineUri(m);
      } on Object {
        // Cannot be opened right now: plays as black/silence.
      }
    }
    final hardware = settings.value.hardwareDecoding && await _hardwareAllowed(p);
    if (gen != _syncGeneration || _disposed) return;
    final plan = buildTimelinePlan(p, uris, hardware: hardware);
    if (plan.text == _planText) return;
    try {
      r.setPlan(plan.text);
    } on Object catch (e) {
      controller.engine.note('timeline plan rejected: $e');
      return;
    }
    _planText = plan.text;
    _trackIds = plan.trackIds;
    final key = _pictureKeyOf(plan.text);
    if (key != _pictureKey) {
      _pictureKey = key;
      if (!_playing) {
        r.seek(state.playhead, accurate: !state.scrubbing && state.preview == null);
        _wake();
      }
    }
    notifyListeners();
  }

  /// Hardware decoding is used only when every kind of video in the
  /// timeline passed its check (on Android, in a separate process).
  Future<bool> _hardwareAllowed(Project p) async {
    for (final m in p.media) {
      if (m.kind != MediaKind.video || p.clipsUsingMedia(m.id) == 0) continue;
      final key = hardwareCheckKey(controller.probeInfo(m.id), m);
      var ok = _hardwareOk[key];
      if (ok == null) {
        try {
          ok = (await controller.media.checkHardwareDecoding(m.uri, key)).ok;
        } on Object {
          ok = false;
        }
        _hardwareOk[key] = ok;
      }
      if (!ok) return false;
    }
    return true;
  }

  /// The picture-related part of a plan (mix-only changes do not need a
  /// new frame while paused).
  static String _pictureKeyOf(String plan) => [
        for (final line in plan.split('\n'))
          if (line.startsWith('track ') && !line.contains(' audio '))
            line.split(' ').take(6).join(' ')
          else if (line.startsWith('clip '))
            () {
              final f = line.split(' ');
              return [f[1], f[2], f[3], f[4], f[9], ...f.skip(11)].join(' ');
            }()
          else if (line.startsWith('hardware'))
            line,
      ].join('\n');

  // ---------------------------------------------------------------- ticks

  void _push(int t) {
    state.setPlayhead(t, controller.project);
    _lastPushed = state.playhead;
  }

  void _wake([Duration d = const Duration(milliseconds: 1500)]) {
    if (_disposed) return;
    if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _lastStats = Duration.zero;
      _awakeUntil = d;
      _ticker.start();
    } else {
      final until = _lastTick + d;
      if (until > _awakeUntil) _awakeUntil = until;
    }
  }

  void _onTick(Duration elapsed) {
    _lastTick = elapsed;
    final r = _r;
    if (r == null) return;
    if (!_decoding) {
      final pic = r.pollFrame();
      if (pic != null) {
        if (pic.image == null) {
          _black = true;
          notifyListeners();
        } else {
          _pending = pic.image;
          _decode();
        }
      }
    }
    if (_playing) {
      final pos = r.positionTicks;
      if (!r.playing) {
        // Reached the end.
        _playing = false;
        _push(pos);
        _resetLevels();
        _wake();
        notifyListeners();
      } else {
        _push(pos);
        if (viewportWidth > 0) state.revealPlayhead(viewportWidth);
        _updateLevels(r.levels());
      }
      if (elapsed - _lastStats > const Duration(seconds: 1)) {
        _lastStats = elapsed;
        stats = r.stats();
        notifyListeners();
      }
    } else if (elapsed > _awakeUntil && !_decoding && _pending == null) {
      _ticker.stop();
      stats = r.stats();
    }
  }

  void _updateLevels(List<double> raw) {
    // Fast attack, ~300 ms release, like a peak meter.
    for (var i = 0; i < _trackIds.length && i < raw.length; i++) {
      final id = _trackIds[i];
      final old = _levels[id] ?? 0;
      _levels[id] = raw[i] > old ? raw[i] : old * 0.86;
    }
    if (raw.length > _trackIds.length) {
      final m = raw[_trackIds.length];
      _master = m > _master ? m : _master * 0.86;
    }
    notifyListeners();
  }

  void _resetLevels() {
    _levels.clear();
    _master = 0;
  }

  void _decode() {
    if (_decoding) return;
    final f = _pending;
    if (f == null) return;
    _pending = null;
    _decoding = true;
    ui.decodeImageFromPixels(f.pixels, f.width, f.height, ui.PixelFormat.rgba8888, (img) {
      _decoding = false;
      if (_disposed) {
        img.dispose();
        return;
      }
      _image?.dispose();
      _image = img;
      _black = false;
      notifyListeners();
      if (_pending != null) _decode();
    });
  }

  /// Plays the timeline's mix offline (tests, export preview).
  Float32List? renderAudio(int startTicks, int frames) => _r?.renderAudio(startTicks, frames);

  @override
  void dispose() {
    _disposed = true;
    _syncTimer?.cancel();
    _lifecycle.dispose();
    controller.removeListener(_projectChanged);
    state.removeListener(_stateChanged);
    _ticker.dispose();
    _r?.dispose();
    _r = null;
    _image?.dispose();
    _image = null;
    super.dispose();
  }
}
