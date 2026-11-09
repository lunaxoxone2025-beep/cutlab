import 'dart:async';
import 'dart:io';

import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../editor/editor_controller.dart';
import '../engine/media_engine.dart';
import '../export/export_controller.dart';
import '../export/export_screen.dart';
import '../format.dart';
import '../media/desktop_media_platform.dart';
import '../media/media_platform.dart';
import '../storage/app_settings.dart';
import '../theme.dart';
import '../timeline/clip_inspector.dart';
import '../timeline/effects_panel.dart';
import '../playback/timeline_playback.dart';
import '../timeline/mixer_panel.dart';
import '../timeline/program_monitor.dart';
import '../timeline/timeline_actions.dart';
import '../timeline/timeline_assets.dart';
import '../timeline/timeline_state.dart';
import '../timeline/timeline_toolbar.dart';
import '../timeline/timeline_view.dart';
import 'dialogs.dart';
import 'project_settings_form.dart';
import 'source_viewer.dart';

/// Width at which the desktop workspace (side panels) replaces the
/// touch-first mobile layout.
const double kDesktopBreakpoint = 1000;

enum _Monitor { program, source }

enum _Side { inspector, effects, mixer }

/// The editing workspace for one project.
class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key, required this.controller, required this.settings});

  final EditorController controller;
  final ValueListenable<AppSettings> settings;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  late final AppLifecycleListener _lifecycle;
  late final TimelineState _tl = TimelineState();
  late final TimelineAssets _assets = TimelineAssets(c);
  late final TimelineActions _actions = TimelineActions(c, _tl, onMessage: _snack);
  late final TimelinePlayback _playback = TimelinePlayback(controller: c, state: _tl, assets: _assets, settings: widget.settings);
  _Side _side = _Side.inspector;
  final FocusNode _focus = FocusNode(debugLabel: 'workspace');
  String? _selectedMediaId;
  _Monitor _monitor = _Monitor.program;
  double _timelineWidth = 800;
  bool _dropping = false;

  EditorController get c => widget.controller;

  MediaRef? get _selected => c.project.media.where((m) => m.id == _selectedMediaId).firstOrNull;

  void _select(MediaRef m) {
    _playback.pause(); // one thing plays at a time
    setState(() {
      _selectedMediaId = m.id;
      _monitor = _Monitor.source;
    });
  }

  /// Space: play/pause the timeline (showing the timeline monitor).
  void _togglePlayback() {
    if (_monitor != _Monitor.program) setState(() => _monitor = _Monitor.program);
    _playback.toggle();
  }

  @override
  void initState() {
    super.initState();
    // Going to the background may be the last chance before the OS kills
    // the app: write unsaved work to the recovery file.
    _lifecycle = AppLifecycleListener(onHide: () => unawaited(c.autosaveNow()));
    c.addListener(_projectChanged);
    unawaited(c.checkMedia());
  }

  void _projectChanged() => _tl.pruneSelection(c.project);

  @override
  void dispose() {
    _lifecycle.dispose();
    c.removeListener(_projectChanged);
    _focus.dispose();
    _playback.dispose(); // before the files it reads are released
    _assets.dispose();
    _tl.dispose();
    unawaited(c.close());
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }

  /// Opens the export screen for the project as it is now.
  Future<void> _export() async {
    _playback.pause();
    final ec = ExportController(
      project: c.project,
      media: c.media,
      engine: c.engine,
      engineUri: _assets.engineUri,
      isAvailable: c.isAvailable,
      hardwareDecoding: () async => widget.settings.value.hardwareDecoding && await _playback.hardwareDecodingAllowed(c.project),
      workDir: getTemporaryDirectory,
    );
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ExportScreen(controller: ec)));
    ec.dispose();
  }

  Future<void> _rename() async {
    final name = await promptText(context, title: 'Rename project', initial: c.project.name);
    if (name != null) c.rename(name);
  }

  Future<void> _save() async {
    final ok = await c.save();
    if (!mounted) return;
    _snack(ok ? 'Saved' : (c.lastError ?? 'Save failed'));
  }

  Future<void> _import() async {
    try {
      final n = await c.importMedia();
      if (!mounted) return;
      if (n > 0) _snack(n == 1 ? 'Imported 1 file' : 'Imported $n files');
    } on Object catch (e) {
      if (mounted) _snack('Import failed: $e');
    }
  }

  Future<void> _relink(MediaRef m) async {
    try {
      final error = await c.relinkMedia(m.id);
      if (mounted && error != null) _snack(error);
    } on Object catch (e) {
      if (mounted) _snack('Relink failed: $e');
    }
  }

  void _remove(MediaRef m) {
    if (!c.removeMedia(m.id)) _snack('"${m.displayName}" is used by ${c.project.clipsUsingMedia(m.id)} clip(s) and cannot be removed.');
  }

  void _addToTimeline(MediaRef m) {
    _actions.addMedia(m.id);
    setState(() => _monitor = _Monitor.program);
  }

  Future<void> _addText() async {
    final text = await promptText(context, title: 'Add text', initial: 'Title');
    if (text != null && text.trim().isNotEmpty) _actions.addText(text.trim());
  }

  /// Effects, looks and transitions of the selected clip: the side panel on
  /// desktop, a sheet on phones.
  void _effects() {
    if (MediaQuery.sizeOf(context).width >= kDesktopBreakpoint) {
      setState(() => _side = _Side.effects);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: EffectsPanel(controller: c, state: _tl, actions: _actions),
      ),
    );
  }

  void _clipSettings() {
    if (MediaQuery.sizeOf(context).width >= kDesktopBreakpoint) return; // always visible on desktop
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: ClipInspector(controller: c, state: _tl, actions: _actions),
      ),
    );
  }

  /// Files dropped from Explorer: imported (no copies), analysed, then placed
  /// one after another at the playhead.
  Future<void> _onDrop(List<String> paths) async {
    final picked = <PickedMedia>[];
    for (final path in paths) {
      final m = await DesktopMediaPlatform.describeFile(File(path));
      if (m != null) picked.add(m);
    }
    if (picked.isEmpty) {
      _snack('Those files are not supported media');
      return;
    }
    final before = {for (final m in c.project.media) m.uri};
    c.addMedia(picked);
    final added = [
      for (final m in c.project.media)
        if (!before.contains(m.uri)) m.id,
    ];
    await c.probeMedia(added);
    if (!mounted) return;
    for (final id in added) {
      final m = c.project.mediaById(id);
      if (m == null) continue;
      _actions.addMedia(id);
      final placed = _tl.selection.isEmpty ? null : c.project.find(_tl.selection.first);
      if (placed != null) _tl.setPlayhead(placed.clip.endTicks, c.project);
    }
    setState(() => _monitor = _Monitor.program);
  }

  bool get _typing {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null && (ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  Map<ShortcutActivator, VoidCallback> get _shortcuts {
    VoidCallback g(VoidCallback f) => () {
          if (!_typing) f();
        };
    void reveal() => _tl.revealPlayhead(_timelineWidth);
    return {
      const SingleActivator(LogicalKeyboardKey.keyS): g(_actions.split),
      const SingleActivator(LogicalKeyboardKey.keyB, control: true): g(_actions.split),
      const SingleActivator(LogicalKeyboardKey.delete): g(() => _actions.delete()),
      const SingleActivator(LogicalKeyboardKey.backspace): g(() => _actions.delete()),
      const SingleActivator(LogicalKeyboardKey.delete, shift: true): g(() => _actions.delete(ripple: true)),
      const SingleActivator(LogicalKeyboardKey.keyC, control: true): g(_actions.copy),
      const SingleActivator(LogicalKeyboardKey.keyX, control: true): g(_actions.cut),
      const SingleActivator(LogicalKeyboardKey.keyV, control: true): g(_actions.paste),
      const SingleActivator(LogicalKeyboardKey.keyD, control: true): g(_actions.duplicate),
      const SingleActivator(LogicalKeyboardKey.keyA, control: true): g(_actions.selectAll),
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true): g(c.undo),
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): g(c.redo),
      const SingleActivator(LogicalKeyboardKey.keyY, control: true): g(c.redo),
      const SingleActivator(LogicalKeyboardKey.keyS, control: true): g(() => unawaited(_save())),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): g(() {
        _actions.stepFrames(-1);
        reveal();
      }),
      const SingleActivator(LogicalKeyboardKey.arrowRight): g(() {
        _actions.stepFrames(1);
        reveal();
      }),
      const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): g(() {
        _actions.stepSeconds(-1);
        reveal();
      }),
      const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): g(() {
        _actions.stepSeconds(1);
        reveal();
      }),
      const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): g(() => _actions.nudge(-1)),
      const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): g(() => _actions.nudge(1)),
      const SingleActivator(LogicalKeyboardKey.arrowUp): g(() {
        _actions.toEdge(-1);
        reveal();
      }),
      const SingleActivator(LogicalKeyboardKey.arrowDown): g(() {
        _actions.toEdge(1);
        reveal();
      }),
      const SingleActivator(LogicalKeyboardKey.home): g(() {
        _actions.toStart();
        reveal();
      }),
      const SingleActivator(LogicalKeyboardKey.end): g(() {
        _actions.toEnd();
        reveal();
      }),
      const SingleActivator(LogicalKeyboardKey.equal): g(() => _tl.zoomAround(1.5, _timelineWidth / 2)),
      const SingleActivator(LogicalKeyboardKey.add): g(() => _tl.zoomAround(1.5, _timelineWidth / 2)),
      const SingleActivator(LogicalKeyboardKey.minus): g(() => _tl.zoomAround(1 / 1.5, _timelineWidth / 2)),
      const SingleActivator(LogicalKeyboardKey.keyN): g(() {
        _tl.snapping = !_tl.snapping;
        _tl.touch();
      }),
      const SingleActivator(LogicalKeyboardKey.escape): g(_tl.clearSelection),
      const SingleActivator(LogicalKeyboardKey.space): g(_togglePlayback),
      const SingleActivator(LogicalKeyboardKey.space, shift: true): g(_playback.stop),
      const SingleActivator(LogicalKeyboardKey.keyK): g(_playback.pause),
      const SingleActivator(LogicalKeyboardKey.keyL): g(() {
        if (!_playback.playing) _togglePlayback();
      }),
    };
  }

  /// Desktop: files dropped from Explorer are imported and placed.
  Widget _withDrop(Widget body) {
    if (kIsWeb || !(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return body;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dropping = true),
      onDragExited: (_) => setState(() => _dropping = false),
      onDragDone: (d) {
        setState(() => _dropping = false);
        unawaited(_onDrop([for (final f in d.files) f.path]));
      },
      child: Stack(children: [
        Positioned.fill(child: body),
        if (_dropping)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                color: CutlabColors.accent.withAlpha(40),
                alignment: Alignment.center,
                child: const Text('Drop to import and add to the timeline', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: _shortcuts,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            final wide = MediaQuery.sizeOf(context).width >= kDesktopBreakpoint;
            return Scaffold(
              appBar: AppBar(
                titleSpacing: 0,
                title: InkWell(
                  onTap: _rename,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: CutlabSpacing.sm),
                    child: Text(c.project.name, overflow: TextOverflow.ellipsis),
                  ),
                ),
                actions: [
                  IconButton(
                      key: const Key('undo'), tooltip: 'Undo (Ctrl+Z)', icon: const Icon(Icons.undo), onPressed: c.canUndo ? c.undo : null),
                  IconButton(
                      key: const Key('redo'), tooltip: 'Redo (Ctrl+Y)', icon: const Icon(Icons.redo), onPressed: c.canRedo ? c.redo : null),
                  _SaveButton(state: c.saveState, onSave: _save),
                  IconButton(
                    key: const Key('exportButton'),
                    tooltip: 'Export video',
                    icon: const Icon(Icons.ios_share),
                    onPressed: c.project.durationTicks > 0 ? () => unawaited(_export()) : null,
                  ),
                  if (wide)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: CutlabSpacing.sm),
                      child: _ModeSwitch(mode: c.project.editorMode, onChanged: c.setMode),
                    ),
                ],
              ),
              body: _withDrop(SafeArea(child: wide ? _desktop() : _mobile())),
            );
          },
        ),
      ),
    );
  }

  Widget _mediaPanel() => _MediaPanel(
        controller: c,
        selectedId: _selectedMediaId,
        onSelect: _select,
        onAdd: _addToTimeline,
        onImport: _import,
        onRelink: _relink,
        onRemove: _remove,
      );

  Widget _preview() => ValueListenableBuilder<AppSettings>(
        valueListenable: widget.settings,
        builder: (context, settings, _) => Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(CutlabSpacing.xs),
                child: SegmentedButton<_Monitor>(
                  key: const Key('monitorSwitch'),
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(value: _Monitor.program, label: Text('Timeline')),
                    ButtonSegment(value: _Monitor.source, label: Text('Source')),
                  ],
                  selected: {_monitor},
                  onSelectionChanged: (v) {
                    if (v.first == _Monitor.source) _playback.pause();
                    setState(() => _monitor = v.first);
                  },
                ),
              ),
              Expanded(
                child: _monitor == _Monitor.program
                    ? ProgramMonitor(controller: c, state: _tl, playback: _playback)
                    : _PreviewPanel(
                        controller: c,
                        media: _selected,
                        available: _selected == null ? null : c.isAvailable(_selected!.id),
                        settings: settings,
                      ),
              ),
            ],
          ),
        ),
      );

  Widget _timeline() => LayoutBuilder(builder: (context, box) {
        _timelineWidth = box.maxWidth - headerWidth;
        _playback.viewportWidth = _timelineWidth;
        return Column(
          children: [
            TimelineToolbar(
              controller: c,
              state: _tl,
              actions: _actions,
              onAddText: _addText,
              onClipSettings: _clipSettings,
              onEffects: _effects,
              viewportWidth: _timelineWidth,
            ),
            Expanded(
              child: DragTarget<String>(
                onAcceptWithDetails: (d) {
                  final box2 = context.findRenderObject() as RenderBox?;
                  if (box2 == null) return;
                  final local = box2.globalToLocal(d.offset);
                  final at = _tl.ticksAtX(local.dx - headerWidth);
                  _actions.addMedia(d.data, at: at < 0 ? 0 : at);
                  setState(() => _monitor = _Monitor.program);
                },
                builder: (context, candidate, _) => DecoratedBox(
                  decoration: BoxDecoration(border: candidate.isEmpty ? null : Border.all(color: CutlabColors.accent, width: 2)),
                  child: TimelineView(controller: c, state: _tl, assets: _assets, onTransitionTap: (_) => _effects()),
                ),
              ),
            ),
          ],
        );
      });

  Widget _desktop() {
    return Padding(
      padding: const EdgeInsets.all(CutlabSpacing.sm),
      child: Column(
        children: [
          Expanded(
            flex: 5,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 300, child: _Panel(title: 'Media (${c.project.media.length})', child: _mediaPanel())),
                const SizedBox(width: CutlabSpacing.sm),
                Expanded(child: _preview()),
                const SizedBox(width: CutlabSpacing.sm),
                SizedBox(
                  width: 320,
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(CutlabSpacing.xs),
                          child: SegmentedButton<_Side>(
                            key: const Key('sideSwitch'),
                            showSelectedIcon: false,
                            style: const ButtonStyle(visualDensity: VisualDensity.compact),
                            segments: const [
                              ButtonSegment(value: _Side.inspector, label: Text('Inspector')),
                              ButtonSegment(value: _Side.effects, label: Text('Effects')),
                              ButtonSegment(value: _Side.mixer, label: Text('Mixer')),
                            ],
                            selected: {_side},
                            onSelectionChanged: (v) => setState(() => _side = v.first),
                          ),
                        ),
                        Expanded(
                          child: _side == _Side.mixer
                              ? MixerPanel(controller: c, playback: _playback)
                              : _side == _Side.effects
                                  ? _Panel(title: 'Effects', child: EffectsPanel(controller: c, state: _tl, actions: _actions))
                                  : ListenableBuilder(
                                  listenable: _tl,
                                  builder: (context, _) => _tl.selection.isEmpty
                                      ? _Panel(title: 'Project', child: _ProjectPanel(controller: c, showMode: false))
                                      : _Panel(title: 'Clip', child: ClipInspector(controller: c, state: _tl, actions: _actions)),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: CutlabSpacing.sm),
          Expanded(flex: 4, child: Card(clipBehavior: Clip.antiAlias, child: _timeline())),
        ],
      ),
    );
  }

  Widget _mobile() {
    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          Expanded(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(CutlabSpacing.sm, CutlabSpacing.sm, CutlabSpacing.sm, 0),
              child: _preview(),
            ),
          ),
          TabBar(
            tabs: [
              const Tab(text: 'Timeline'),
              Tab(text: 'Media (${c.project.media.length})'),
              const Tab(text: 'Mixer'),
              const Tab(text: 'Project'),
            ],
          ),
          Expanded(
            flex: 5,
            child: TabBarView(
              physics: const NeverScrollableScrollPhysics(), // horizontal drags belong to the timeline
              children: [
                _timeline(),
                _mediaPanel(),
                MixerPanel(controller: c, playback: _playback),
                _ProjectPanel(controller: c, showMode: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.state, required this.onSave});
  final SaveState state;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      SaveState.saving => const Padding(
          padding: EdgeInsets.all(14),
          child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      SaveState.saved => IconButton(
          key: const Key('save'),
          tooltip: 'All changes saved',
          icon: const Icon(Icons.cloud_done_outlined, color: CutlabColors.textMuted),
          onPressed: onSave,
        ),
      SaveState.unsaved => IconButton(
          key: const Key('save'),
          tooltip: 'Save',
          icon: const Icon(Icons.save_outlined, color: CutlabColors.accent),
          onPressed: onSave,
        ),
      SaveState.error => IconButton(
          key: const Key('save'),
          tooltip: 'Save failed — tap to retry',
          icon: const Icon(Icons.error_outline, color: CutlabColors.danger),
          onPressed: onSave,
        ),
    };
  }
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.onChanged});
  final EditorMode mode;
  final ValueChanged<EditorMode> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<EditorMode>(
        key: const Key('modeSwitch'),
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: EditorMode.beginner, label: Text('Beginner')),
          ButtonSegment(value: EditorMode.advanced, label: Text('Advanced')),
        ],
        selected: {mode},
        onSelectionChanged: (s) => onChanged(s.first),
      );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(CutlabSpacing.md, CutlabSpacing.sm, CutlabSpacing.md, 0),
            child: Text(title.toUpperCase(),
                style: const TextStyle(fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w700, color: CutlabColors.textMuted)),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _PreviewPanel extends StatelessWidget {
  const _PreviewPanel({required this.controller, required this.media, required this.available, required this.settings});
  final EditorController controller;
  final MediaRef? media;
  final bool? available;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final m = media;
    final engine = controller.engine;
    Widget body;
    if (m == null) {
      final s = controller.project.settings;
      body = _note('${s.width} × ${s.height} · ${formatFps(s.frameRate)} fps\n'
          '${engine.available ? 'Tap a file in Media to preview it.' : engine.info.reason ?? 'Media engine unavailable.'}');
    } else if (available == false) {
      body = _note('"${m.displayName}" is missing. Relink it to preview.');
    } else if (!engine.available) {
      body = _note(engine.info.reason ?? 'Media engine unavailable.');
    } else {
      body = SourceViewer(key: ValueKey(m.id), controller: controller, media: m, settings: settings);
    }
    return Card(clipBehavior: Clip.antiAlias, child: body);
  }

  Widget _note(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(CutlabSpacing.md),
          child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: CutlabColors.textMuted, fontSize: 12)),
        ),
      );
}

// ------------------------------------------------------------------ media

class _MediaPanel extends StatelessWidget {
  const _MediaPanel({
    required this.controller,
    required this.selectedId,
    required this.onSelect,
    required this.onAdd,
    required this.onImport,
    required this.onRelink,
    required this.onRemove,
  });

  final EditorController controller;
  final String? selectedId;
  final ValueChanged<MediaRef> onSelect;
  final ValueChanged<MediaRef> onAdd;
  final VoidCallback onImport;
  final ValueChanged<MediaRef> onRelink;
  final ValueChanged<MediaRef> onRemove;

  @override
  Widget build(BuildContext context) {
    final media = controller.project.media;
    final missing = controller.missingCount;
    return ListView(
      padding: const EdgeInsets.all(CutlabSpacing.sm),
      children: [
        FilledButton.tonalIcon(
          key: const Key('importMedia'),
          onPressed: onImport,
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: const Text('Import media'),
        ),
        if (missing > 0)
          Container(
            key: const Key('missingBanner'),
            margin: const EdgeInsets.only(top: CutlabSpacing.sm),
            padding: const EdgeInsets.all(CutlabSpacing.sm),
            decoration: BoxDecoration(
              color: CutlabColors.danger.withAlpha(40),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              missing == 1
                  ? '1 file is missing. Use "Relink" to point it to its new location.'
                  : '$missing files are missing. Use "Relink" on each one.',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        if (media.isEmpty)
          const Padding(
            padding: EdgeInsets.all(CutlabSpacing.lg),
            child: Text(
              'Videos, music and photos you import appear here. Files stay where they are — nothing is copied.',
              textAlign: TextAlign.center,
              style: TextStyle(color: CutlabColors.textMuted, fontSize: 12),
            ),
          ),
        for (final m in media)
          _MediaTile(
            key: Key('media-${m.id}'),
            media: m,
            thumbnail: controller.thumbnailFor(m),
            available: controller.isAvailable(m.id),
            info: controller.probeInfo(m.id),
            probing: controller.isProbing(m.id),
            probeError: controller.probeError(m.id),
            selected: m.id == selectedId,
            onSelect: () => onSelect(m),
            onAdd: () => onAdd(m),
            draggable: MediaQuery.sizeOf(context).width >= kDesktopBreakpoint,
            onRelink: () => onRelink(m),
            onRemove: () => onRemove(m),
          ),
      ],
    );
  }
}

class _MediaTile extends StatelessWidget {
  const _MediaTile({
    super.key,
    required this.media,
    required this.thumbnail,
    required this.available,
    required this.info,
    required this.probing,
    required this.probeError,
    required this.selected,
    required this.onSelect,
    required this.onAdd,
    required this.draggable,
    required this.onRelink,
    required this.onRemove,
  });

  final MediaRef media;
  final Uint8List? thumbnail;
  final bool? available;
  final ProbeInfo? info;
  final bool probing;
  final String? probeError;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onAdd;
  final bool draggable;
  final VoidCallback onRelink;
  final VoidCallback onRemove;

  IconData get _icon => switch (media.kind) {
        MediaKind.video => Icons.movie_outlined,
        MediaKind.audio => Icons.music_note_outlined,
        MediaKind.image => Icons.image_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final missing = available == false;
    final parts = <String>[
      if (media.kind != MediaKind.image && !media.needsProbe) formatDuration(media.durationTicks),
      if (media.width != null && media.height != null) '${media.width}×${media.height}',
      if (media.sizeBytes != null) formatBytes(media.sizeBytes!),
    ];
    final details = missing
        ? 'Missing'
        : [
            parts.isEmpty ? media.kind.name : parts.join(' · '),
            if (info != null && info!.summary.isNotEmpty) info!.summary,
            if (probing) 'reading…',
            if (probeError != null && info == null) 'unreadable',
          ].join(' · ');
    final tile = Padding(
      padding: const EdgeInsets.only(top: CutlabSpacing.sm),
      child: Material(
        color: selected ? CutlabColors.accent.withAlpha(30) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onSelect,
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  width: 64,
                  height: 40,
                  color: CutlabColors.surfaceRaised,
                  child: thumbnail != null && !missing
                      ? Image.memory(thumbnail!,
                          fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, __, ___) => Icon(_icon, size: 20))
                      : Icon(_icon, size: 20, color: CutlabColors.textMuted),
                ),
              ),
              const SizedBox(width: CutlabSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(media.displayName, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                    Text(
                      details,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: missing ? CutlabColors.danger : CutlabColors.textMuted),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: Key('addToTimeline-${media.id}'),
                tooltip: 'Add to timeline at the playhead',
                icon: const Icon(Icons.add_box_outlined),
                onPressed: missing ? null : onAdd,
              ),
              PopupMenuButton<String>(
                tooltip: 'Media actions',
                onSelected: (v) => v == 'relink' ? onRelink() : onRemove(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'relink', child: Text('Relink…')),
                  PopupMenuItem(value: 'remove', child: Text('Remove from project')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (!draggable || missing) return tile;
    // Desktop: drag a file onto the timeline to place it where it is dropped.
    return Draggable<String>(
      data: media.id,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: CutlabColors.accent, borderRadius: BorderRadius.circular(6)),
          child: Text(media.displayName, style: const TextStyle(color: CutlabColors.onAccent, fontWeight: FontWeight.w700)),
        ),
      ),
      child: tile,
    );
  }
}

// --------------------------------------------------------------- project

class _ProjectPanel extends StatelessWidget {
  const _ProjectPanel({required this.controller, required this.showMode});

  final EditorController controller;
  final bool showMode;

  @override
  Widget build(BuildContext context) {
    final p = controller.project;
    final s = p.settings;
    final rows = <(String, String)>[
      ('Resolution', '${s.width} × ${s.height}'),
      ('Frame rate', '${formatFps(s.frameRate)} fps'),
      ('Audio', '${s.sampleRate ~/ 1000} kHz · ${s.audioChannels == 2 ? 'stereo' : '${s.audioChannels} ch'}'),
      ('Media', '${p.media.length}'),
      ('Tracks', '${p.tracks.length}'),
      ('Created', formatDateTime(p.createdAt)),
      ('Edited', formatDateTime(p.modifiedAt)),
    ];
    return ListView(
      padding: const EdgeInsets.all(CutlabSpacing.md),
      children: [
        if (showMode) ...[
          const Text('Editor mode', style: TextStyle(color: CutlabColors.textMuted, fontSize: 12)),
          const SizedBox(height: CutlabSpacing.xs),
          _ModeSwitch(mode: p.editorMode, onChanged: controller.setMode),
          const SizedBox(height: CutlabSpacing.lg),
        ],
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Expanded(child: Text(label, style: const TextStyle(color: CutlabColors.textMuted))),
                Text(value),
              ],
            ),
          ),
        const SizedBox(height: CutlabSpacing.lg),
        CanvasAndRatePicker(settings: s, onChanged: controller.updateSettings),
      ],
    );
  }
}
