import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../editor/editor_controller.dart';
import '../engine/bmp.dart';
import '../engine/media_engine.dart';
import '../format.dart';
import '../storage/app_settings.dart';
import '../theme.dart';

/// Plays one media file from the project with the native engine: video with
/// audio-driven sync, scrubbing (fast while dragging, frame-accurate on
/// release), frame stepping, a thumbnail strip, and a waveform for audio.
class SourceViewer extends StatefulWidget {
  const SourceViewer({super.key, required this.controller, required this.media, required this.settings});

  final EditorController controller;
  final MediaRef media;
  final AppSettings settings;

  @override
  State<SourceViewer> createState() => _SourceViewerState();
}

class _SourceViewerState extends State<SourceViewer> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  PreviewPlayer? _player;
  String? _engineUri;
  String? _error;
  String? _hwNote;
  bool _opening = true;

  ui.Image? _image;
  RgbaImage? _pending;
  bool _decoding = false;
  int _shownPts = 0;
  int _position = 0;
  int _duration = 0;
  bool _playing = false;
  bool _dragging = false;
  double _dragValue = 0;
  Duration _awakeUntil = Duration.zero;
  Duration _lastTick = Duration.zero;
  Duration _lastStats = Duration.zero;
  PlayerStats _stats = const PlayerStats();

  List<(int, Uint8List)>? _strip;
  Peaks? _peaks;
  int _openGeneration = 0;

  MediaEngine get _engine => widget.controller.engine;

  Rational get _fps => widget.controller.probeInfo(widget.media.id)?.frameRate ?? widget.media.frameRate ?? Rational.fps30;

  int get _frameTicks => framesToTicks(1, _fps);

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void didUpdateWidget(SourceViewer old) {
    super.didUpdateWidget(old);
    if (old.media.id != widget.media.id ||
        old.media.uri != widget.media.uri ||
        old.settings.previewHeight != widget.settings.previewHeight ||
        old.settings.hardwareDecoding != widget.settings.hardwareDecoding) {
      _close();
      unawaited(_open());
    }
  }

  @override
  void dispose() {
    _close();
    _ticker.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final gen = ++_openGeneration;
    setState(() {
      _opening = true;
      _error = null;
      _hwNote = null;
      _strip = null;
      _peaks = null;
    });
    final c = widget.controller;
    final m = widget.media;
    String? uri;
    try {
      uri = await c.media.openForEngine(m.uri);
      if (!mounted || gen != _openGeneration) {
        unawaited(c.releaseEngineUri(uri));
        return;
      }
      final s = widget.settings;
      var hardware = s.hardwareDecoding && m.kind == MediaKind.video;
      if (hardware) {
        // On Android the hardware decoder is first tried in a separate
        // process, so a faulty phone decoder cannot close CUTLAB.
        try {
          final check = await c.media.checkHardwareDecoding(m.uri, hardwareCheckKey(c.probeInfo(m.id), m));
          if (!check.ok) {
            hardware = false;
            _hwNote = check.detail;
          }
        } on Object catch (e) {
          hardware = false;
          _hwNote = 'hardware check failed: $e';
        }
        if (!mounted || gen != _openGeneration) {
          unawaited(c.releaseEngineUri(uri));
          return;
        }
      }
      c.engine.note('preview open ${m.displayName} hardware=$hardware ${_hwNote ?? ''}');
      final player = await _engine.openPlayer(uri, maxWidth: s.previewMaxWidth, maxHeight: s.previewMaxHeight, hardware: hardware);
      if (!mounted || gen != _openGeneration) {
        player.dispose();
        unawaited(c.releaseEngineUri(uri));
        return;
      }
      _player = player;
      _engineUri = uri;
      setState(() {
        _opening = false;
        _duration = player.durationTicks;
      });
      _wake(const Duration(seconds: 2));
      unawaited(_loadExtras(uri, gen));
    } on Object catch (e) {
      if (uri != null) unawaited(c.releaseEngineUri(uri));
      if (!mounted || gen != _openGeneration) return;
      c.engine.note('preview failed ${m.displayName}: $e');
      setState(() {
        _opening = false;
        _error = 'Cannot play this file: $e';
      });
    }
  }

  Future<void> _loadExtras(String uri, int gen) async {
    try {
      if (widget.media.kind == MediaKind.video) {
        final strip = await _engine.thumbnails(uri, 10, maxWidth: 160, maxHeight: 90);
        if (!mounted || gen != _openGeneration) return;
        setState(() => _strip = [for (final f in strip.frames) (f.ptsTicks, encodeBmp(f))]);
      } else if (widget.media.kind == MediaKind.audio) {
        final secs = (_duration ~/ ticksPerSecond).clamp(1, 1 << 30);
        final bps = (4000 ~/ secs).clamp(1, 100);
        final peaks = await _engine.peaks(uri, bucketsPerSecond: bps);
        if (!mounted || gen != _openGeneration) return;
        setState(() => _peaks = peaks);
      }
    } on Object {
      // Optional extras: the player still works without them.
    }
  }

  void _close() {
    _ticker.stop();
    _player?.dispose();
    _player = null;
    final uri = _engineUri;
    _engineUri = null;
    // Thumbnails may still be reading the file: close it once they finish.
    if (uri != null) unawaited(widget.controller.releaseEngineUri(uri));
    _image?.dispose();
    _image = null;
    _pending = null;
    _playing = false;
    _stats = const PlayerStats();
  }

  /// Keeps polling frames for a while (frames arrive asynchronously after a
  /// seek). While playing, the ticker always runs.
  void _wake([Duration d = const Duration(milliseconds: 800)]) {
    final until = _lastTick + d;
    if (until > _awakeUntil) _awakeUntil = until;
    if (!_ticker.isActive) {
      _awakeUntil = d; // ticker elapsed restarts at zero
      _lastTick = Duration.zero;
      _lastStats = Duration.zero;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    _lastTick = elapsed;
    final p = _player;
    if (p == null) return;
    // While a picture is being uploaded, leave newer ones in the engine
    // (copying every frame would only make garbage on slow phones).
    if (!_decoding) {
      final frame = p.pollFrame();
      if (frame != null) {
        _pending = frame;
        _decodePending();
      }
    }
    final playing = p.playing;
    final pos = p.positionTicks;
    if (elapsed - _lastStats > const Duration(seconds: 1)) {
      _lastStats = elapsed;
      final before = _stats.error;
      _stats = p.stats();
      if (_stats.error.isNotEmpty && _stats.error != before) {
        widget.controller.engine.note('preview decoding error ${widget.media.displayName}: ${_stats.error}');
        setState(() {});
      }
    }
    if (pos != _position || playing != _playing) {
      setState(() {
        _position = pos;
        _playing = playing;
      });
    }
    if (!playing && elapsed > _awakeUntil && !_decoding && _pending == null) _ticker.stop();
  }

  void _decodePending() {
    if (_decoding) return;
    final f = _pending;
    if (f == null) return;
    _pending = null;
    _decoding = true;
    ui.decodeImageFromPixels(f.pixels, f.width, f.height, ui.PixelFormat.rgba8888, (img) {
      _decoding = false;
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = img;
        _shownPts = f.ptsTicks;
      });
      if (_pending != null) _decodePending();
    });
  }

  void _togglePlay() {
    final p = _player;
    if (p == null) return;
    if (p.playing) {
      p.pause();
      _wake();
    } else {
      p.play();
      _wake(const Duration(days: 1));
    }
    setState(() => _playing = p.playing);
  }

  void _seek(int ticks, {required bool accurate}) {
    final p = _player;
    if (p == null) return;
    final t = ticks.clamp(0, _duration > 0 ? _duration : ticks);
    p.seek(t, accurate: accurate);
    setState(() => _position = t);
    _wake();
  }

  void _step(int frames) {
    _player?.pause();
    _seek(_shownPts + frames * _frameTicks, accurate: true);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.media;
    if (_error != null) return _message(Icons.error_outline, _error!);
    if (_opening && _player == null) return const Center(child: CircularProgressIndicator());
    final info = widget.controller.probeInfo(m.id);
    final shownTime = _dragging ? (_dragValue * _duration).round() : _position;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Container(
            color: Colors.black,
            alignment: Alignment.center,
            child: m.kind == MediaKind.audio
                ? _Waveform(peaks: _peaks, position: _duration > 0 ? shownTime / _duration : 0)
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_image != null) RawImage(image: _image, fit: BoxFit.contain, filterQuality: FilterQuality.medium),
                      if (_stats.error.isNotEmpty)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            key: const Key('decodeError'),
                            color: Colors.black87,
                            padding: const EdgeInsets.all(CutlabSpacing.sm),
                            child: Text(
                              'This video could not be decoded further: ${_stats.error}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        if (_strip != null && _strip!.isNotEmpty)
          SizedBox(
            height: 40,
            child: Row(
              children: [
                for (final (pts, bmp) in _strip!)
                  Expanded(
                    child: GestureDetector(
                      onTap: () => _seek(pts, accurate: true),
                      child: Image.memory(bmp, fit: BoxFit.cover, gaplessPlayback: true, height: 40),
                    ),
                  ),
              ],
            ),
          ),
        if (m.kind != MediaKind.image)
          SliderTheme(
            data: SliderTheme.of(context).copyWith(trackHeight: 3, overlayShape: SliderComponentShape.noOverlay),
            child: Slider(
              key: const Key('scrubber'),
              value: _duration > 0 ? (shownTime / _duration).clamp(0.0, 1.0) : 0,
              onChangeStart: (v) => setState(() {
                _dragging = true;
                _dragValue = v;
              }),
              onChanged: (v) {
                setState(() => _dragValue = v);
                _seek((v * _duration).round(), accurate: false);
              },
              onChangeEnd: (v) {
                setState(() => _dragging = false);
                _seek((v * _duration).round(), accurate: true);
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: CutlabSpacing.xs),
          child: Row(
            children: [
              if (m.kind != MediaKind.image) ...[
                IconButton(
                  key: const Key('stepBack'),
                  tooltip: 'Previous frame',
                  icon: const Icon(Icons.skip_previous),
                  onPressed: m.kind == MediaKind.video ? () => _step(-1) : null,
                ),
                IconButton.filled(
                  key: const Key('playPause'),
                  tooltip: _playing ? 'Pause' : 'Play',
                  icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                  onPressed: _togglePlay,
                ),
                IconButton(
                  key: const Key('stepForward'),
                  tooltip: 'Next frame',
                  icon: const Icon(Icons.skip_next),
                  onPressed: m.kind == MediaKind.video ? () => _step(1) : null,
                ),
                const SizedBox(width: CutlabSpacing.sm),
                Text(
                  '${formatTimecode(shownTime, _fps)} / ${formatTimecode(_duration, _fps)}',
                  style: const TextStyle(fontSize: 12, fontFeatures: [ui.FontFeature.tabularFigures()]),
                ),
              ],
              const Spacer(),
              Flexible(
                child: Text(
                  [
                    if (info != null) info.summary,
                    if (_stats.decoder.isNotEmpty) '${_stats.hardware ? 'HW' : 'SW'} ${_stats.decoder}',
                    if (!_stats.hardware && (_hwNote != null || _stats.hardwareFallback.isNotEmpty)) 'hardware off',
                    if (_stats.framesDropped > 0) '${_stats.framesDropped} dropped',
                  ].join(' · '),
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 11, color: CutlabColors.textMuted),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _message(IconData icon, String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(CutlabSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: CutlabColors.textMuted),
              const SizedBox(height: CutlabSpacing.sm),
              Text(text, textAlign: TextAlign.center, style: const TextStyle(color: CutlabColors.textMuted, fontSize: 12)),
            ],
          ),
        ),
      );
}

class _Waveform extends StatelessWidget {
  const _Waveform({required this.peaks, required this.position});
  final Peaks? peaks;
  final double position;

  @override
  Widget build(BuildContext context) {
    final p = peaks;
    if (p == null) return const Icon(Icons.graphic_eq, size: 48, color: CutlabColors.textMuted);
    return CustomPaint(painter: _WaveformPainter(p, position), size: Size.infinite);
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter(this.peaks, this.position);
  final Peaks peaks;
  final double position;

  @override
  void paint(Canvas canvas, Size size) {
    final n = peaks.length;
    if (n == 0) return;
    final mid = size.height / 2;
    final paint = Paint()
      ..color = CutlabColors.audioTrack
      ..strokeWidth = 1;
    final columns = size.width.floor();
    for (var x = 0; x < columns; x++) {
      final from = x * n ~/ columns;
      final to = ((x + 1) * n ~/ columns).clamp(from + 1, n);
      var lo = 0.0, hi = 0.0;
      for (var i = from; i < to; i++) {
        lo = lo < peaks.pairs[2 * i] ? lo : peaks.pairs[2 * i];
        hi = hi > peaks.pairs[2 * i + 1] ? hi : peaks.pairs[2 * i + 1];
      }
      canvas.drawLine(Offset(x + 0.5, mid - hi * mid * 0.9), Offset(x + 0.5, mid - lo * mid * 0.9), paint);
    }
    final px = position * size.width;
    canvas.drawLine(
        Offset(px, 0),
        Offset(px, size.height),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_WaveformPainter old) => old.peaks != peaks || old.position != position;
}
