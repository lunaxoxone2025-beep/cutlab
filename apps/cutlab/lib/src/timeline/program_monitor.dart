import 'dart:async';
import 'dart:ui' as ui;

import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:flutter/material.dart';

import '../editor/editor_controller.dart';
import '../format.dart';
import '../storage/app_settings.dart';
import '../theme.dart';
import 'timeline_assets.dart';
import 'timeline_state.dart';

/// Shows the timeline frame under the playhead: the picture on the top-most
/// visible video/image track (decoded frame-accurately by the engine; fast
/// keyframe seeks while scrubbing) and any titles at that time.
///
/// Phase 4 scope: still frames at the playhead. Continuous playback of the
/// edited timeline with mixed audio needs the native timeline renderer
/// (Phase 5); playing a single file works in the Source view.
class ProgramMonitor extends StatefulWidget {
  const ProgramMonitor({super.key, required this.controller, required this.state, required this.assets, required this.settings});

  final EditorController controller;
  final TimelineState state;
  final TimelineAssets assets;
  final AppSettings settings;

  @override
  State<ProgramMonitor> createState() => _ProgramMonitorState();
}

class _ProgramMonitorState extends State<ProgramMonitor> {
  ui.Image? _image;
  String _shownKey = '';
  bool _busy = false;
  bool _again = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_changed);
    widget.controller.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(ProgramMonitor old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) {
      old.state.removeListener(_changed);
      widget.state.addListener(_changed);
    }
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_changed);
    widget.controller.removeListener(_changed);
    _image?.dispose();
    super.dispose();
  }

  Project get _p => widget.state.preview ?? widget.controller.project;

  bool get _fast => widget.state.scrubbing || widget.state.preview != null;

  /// What should be on screen: "<media>|<source time>|<a|f>" (accurate or
  /// fast frame) or "" for black.
  String _wantedKey() {
    final pc = _p.topVisualAt(widget.state.playhead);
    if (pc == null || pc.clip.mediaId == null) return '';
    final m = _p.mediaById(pc.clip.mediaId);
    if (m == null) return '';
    final src = m.kind == MediaKind.image ? 0 : _p.sourceTimeAt(pc.clip, widget.state.playhead);
    return '${m.id}|$src|${_fast && m.kind != MediaKind.image ? 'f' : 'a'}';
  }

  void _changed() {
    if (!mounted) return;
    setState(() {}); // titles / timecode
    final key = _wantedKey();
    if (key == _shownKey) return;
    if (_busy) {
      _again = true;
      return;
    }
    unawaited(_load(key));
  }

  Future<void> _load(String key) async {
    _busy = true;
    _again = false;
    try {
      if (key.isEmpty) {
        _setImage(null, key);
        return;
      }
      final engine = widget.controller.engine;
      if (!engine.available) {
        setState(() => _error = engine.info.reason);
        _shownKey = key;
        return;
      }
      final parts = key.split('|');
      final m = _p.mediaById(parts[0]);
      if (m == null) {
        _shownKey = key;
        return;
      }
      final src = int.parse(parts[1]);
      final accurate = parts[2] == 'a';
      final uri = await widget.assets.engineUri(m);
      final s = widget.settings;
      final frame = await engine.frameAt(uri, src, accurate: accurate, maxWidth: s.previewMaxWidth, maxHeight: s.previewMaxHeight);
      final c = Completer<ui.Image>();
      ui.decodeImageFromPixels(frame.pixels, frame.width, frame.height, ui.PixelFormat.rgba8888, c.complete);
      final img = await c.future;
      if (!mounted) {
        img.dispose();
        return;
      }
      _error = null;
      _setImage(img, key);
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'Cannot show this frame: $e');
      _shownKey = key;
    } finally {
      _busy = false;
      // A newer position (or the accurate frame after scrubbing) is pending.
      if (mounted && (_again || _wantedKey() != _shownKey)) unawaited(_load(_wantedKey()));
    }
  }

  void _setImage(ui.Image? img, String key) {
    setState(() {
      _image?.dispose();
      _image = img;
      _shownKey = key;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final t = widget.state.playhead;
    final titles = [
      for (final tr in p.tracks)
        if (tr.kind == TrackKind.text && !tr.hidden)
          for (final c in tr.clips)
            if (c.startTicks <= t && t < c.endTicks) c.data['text'] as String? ?? '',
    ];
    final s = p.settings;
    return Column(
      children: [
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: s.width / s.height,
              child: Container(
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_image != null) RawImage(image: _image, fit: BoxFit.contain),
                    if (_error != null && _image == null)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(CutlabSpacing.md),
                          child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: CutlabColors.textMuted, fontSize: 12)),
                        ),
                      ),
                    if (p.durationTicks == 0)
                      const Center(
                        child: Text('Add media to the timeline (＋ on a file in Media)',
                            textAlign: TextAlign.center, style: TextStyle(color: CutlabColors.textMuted, fontSize: 12)),
                      ),
                    if (titles.isNotEmpty)
                      Align(
                        alignment: const Alignment(0, 0.8),
                        child: Padding(
                          padding: const EdgeInsets.all(CutlabSpacing.sm),
                          child: Text(
                            titles.join('\n'),
                            key: const Key('monitorTitles'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800, shadows: [Shadow(blurRadius: 6)]),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: CutlabSpacing.xs),
          child: Text(
            '${formatTimecode(t, p.fps)} / ${formatTimecode(p.durationTicks, p.fps)}',
            style: const TextStyle(fontSize: 12, color: CutlabColors.textMuted),
          ),
        ),
      ],
    );
  }
}
