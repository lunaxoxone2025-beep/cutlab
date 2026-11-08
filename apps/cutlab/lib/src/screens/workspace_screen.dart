import 'dart:async';

import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../editor/editor_controller.dart';
import '../engine/media_engine.dart';
import '../format.dart';
import '../theme.dart';
import '../storage/app_settings.dart';
import 'dialogs.dart';
import 'project_settings_form.dart';
import 'source_viewer.dart';

/// Width at which the desktop workspace (side panels) replaces the
/// touch-first mobile layout.
const double kDesktopBreakpoint = 1000;

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
  String? _selectedMediaId;

  EditorController get c => widget.controller;

  MediaRef? get _selected => c.project.media.where((m) => m.id == _selectedMediaId).firstOrNull;

  void _select(MediaRef m) => setState(() => _selectedMediaId = m.id);

  @override
  void initState() {
    super.initState();
    // Going to the background may be the last chance before the OS kills
    // the app: write unsaved work to the recovery file.
    _lifecycle = AppLifecycleListener(onHide: () => unawaited(c.autosaveNow()));
    unawaited(c.checkMedia());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(c.close());
    super.dispose();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
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
              IconButton(key: const Key('undo'), tooltip: 'Undo', icon: const Icon(Icons.undo), onPressed: c.canUndo ? c.undo : null),
              IconButton(key: const Key('redo'), tooltip: 'Redo', icon: const Icon(Icons.redo), onPressed: c.canRedo ? c.redo : null),
              _SaveButton(state: c.saveState, onSave: _save),
              if (wide)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: CutlabSpacing.sm),
                  child: _ModeSwitch(mode: c.project.editorMode, onChanged: c.setMode),
                ),
            ],
          ),
          body: SafeArea(child: wide ? _desktop() : _mobile()),
        );
      },
    );
  }

  Widget _mediaPanel() => _MediaPanel(
        controller: c,
        selectedId: _selectedMediaId,
        onSelect: _select,
        onImport: _import,
        onRelink: _relink,
        onRemove: _remove,
      );

  Widget _preview() => ValueListenableBuilder<AppSettings>(
        valueListenable: widget.settings,
        builder: (context, settings, _) => _PreviewPanel(
          controller: c,
          media: _selected,
          available: _selected == null ? null : c.isAvailable(_selected!.id),
          settings: settings,
        ),
      );

  Widget _desktop() {
    return Padding(
      padding: const EdgeInsets.all(CutlabSpacing.sm),
      child: Column(
        children: [
          Expanded(
            flex: 3,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 300, child: _Panel(title: 'Media (${c.project.media.length})', child: _mediaPanel())),
                const SizedBox(width: CutlabSpacing.sm),
                Expanded(child: _preview()),
                const SizedBox(width: CutlabSpacing.sm),
                SizedBox(width: 320, child: _Panel(title: 'Project', child: _ProjectPanel(controller: c, showMode: false))),
              ],
            ),
          ),
          const SizedBox(height: CutlabSpacing.sm),
          Expanded(flex: 2, child: _Panel(title: 'Timeline', child: _TimelineView(project: c.project))),
        ],
      ),
    );
  }

  Widget _mobile() {
    return DefaultTabController(
      length: 3,
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
              Tab(text: 'Media (${c.project.media.length})'),
              const Tab(text: 'Timeline'),
              const Tab(text: 'Project'),
            ],
          ),
          Expanded(
            flex: 5,
            child: TabBarView(
              children: [
                _mediaPanel(),
                _TimelineView(project: c.project),
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
    required this.onImport,
    required this.onRelink,
    required this.onRemove,
  });

  final EditorController controller;
  final String? selectedId;
  final ValueChanged<MediaRef> onSelect;
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
    return Padding(
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

// -------------------------------------------------------------- timeline

class _TimelineView extends StatelessWidget {
  const _TimelineView({required this.project});
  final Project project;

  Color _color(TrackKind k) => switch (k) {
        TrackKind.video => CutlabColors.videoTrack,
        TrackKind.audio => CutlabColors.audioTrack,
        TrackKind.text => CutlabColors.textTrack,
        TrackKind.image => CutlabColors.imageTrack,
      };

  IconData _icon(TrackKind k) => switch (k) {
        TrackKind.video => Icons.movie_outlined,
        TrackKind.audio => Icons.music_note_outlined,
        TrackKind.text => Icons.title,
        TrackKind.image => Icons.image_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final advanced = project.editorMode == EditorMode.advanced;
    return ListView(
      padding: const EdgeInsets.all(CutlabSpacing.sm),
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            formatTimecode(project.durationTicks, project.settings.frameRate),
            key: const Key('timelineDuration'),
            style: const TextStyle(fontSize: 11, color: CutlabColors.textMuted),
          ),
        ),
        const SizedBox(height: CutlabSpacing.xs),
        for (final t in project.tracks)
          Container(
            margin: const EdgeInsets.only(bottom: CutlabSpacing.xs),
            height: 36,
            decoration: BoxDecoration(
              color: CutlabColors.surfaceRaised,
              borderRadius: BorderRadius.circular(8),
              border: Border(left: BorderSide(color: _color(t.kind), width: 4)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: CutlabSpacing.sm),
            child: Row(
              children: [
                Icon(_icon(t.kind), size: 16, color: CutlabColors.textMuted),
                const SizedBox(width: CutlabSpacing.sm),
                Expanded(child: Text(t.name, overflow: TextOverflow.ellipsis)),
                Text('${t.clips.length} clips', style: const TextStyle(fontSize: 11, color: CutlabColors.textMuted)),
                if (advanced) ...[
                  const SizedBox(width: CutlabSpacing.sm),
                  Icon(t.locked ? Icons.lock : Icons.lock_open, size: 14, color: CutlabColors.textMuted),
                  const SizedBox(width: CutlabSpacing.xs),
                  Icon(t.hidden ? Icons.visibility_off : Icons.visibility, size: 14, color: CutlabColors.textMuted),
                  const SizedBox(width: CutlabSpacing.xs),
                  Icon(t.muted ? Icons.volume_off : Icons.volume_up, size: 14, color: CutlabColors.textMuted),
                ],
              ],
            ),
          ),
        const Padding(
          padding: EdgeInsets.only(top: CutlabSpacing.sm),
          child: Text('Placing and editing clips — Phase 4.',
              textAlign: TextAlign.center, style: TextStyle(color: CutlabColors.textMuted, fontSize: 12)),
        ),
      ],
    );
  }
}
