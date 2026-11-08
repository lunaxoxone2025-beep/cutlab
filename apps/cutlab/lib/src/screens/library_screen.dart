import 'package:cutlab_project_format/cutlab_project_format.dart' hide Clip;
import 'package:flutter/material.dart';

import '../editor/editor_controller.dart';
import '../format.dart';
import '../media/media_platform.dart';
import '../services.dart';
import '../storage/project_store.dart';
import '../theme.dart';
import 'dialogs.dart';
import 'project_settings_form.dart';
import 'settings_screen.dart';
import 'workspace_screen.dart';

enum _ProjectAction { rename, duplicate, export, delete }

/// Start screen: every saved project, plus create / import.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.services});

  final AppServices services;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<ProjectEntry>? _entries;
  String? _loadError;

  ProjectStore get _store => widget.services.projects;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final entries = await _store.list();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loadError = null;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _loadError = '$e');
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _create() async {
    final req = await NewProjectSheet.show(context);
    if (req == null) return;
    final project = await _store.create(name: req.name, settings: req.settings, mode: widget.services.settings.value.defaultMode);
    await _edit(project);
  }

  Future<void> _open(ProjectEntry entry) async {
    Project? project;
    var recovered = false;
    try {
      if (entry.hasRecovery) {
        final restore = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text('Unsaved changes found'),
            content: Text('"${entry.name}" was closed before its last changes were saved. Restore them?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Discard')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Restore')),
            ],
          ),
        );
        if (restore == true) {
          project = await _store.openRecovery(entry.id);
          recovered = project != null;
        } else {
          await _store.discardRecovery(entry.id);
        }
      }
      project ??= await _store.open(entry.id);
    } on Object catch (e) {
      if (mounted) _snack('Could not open "${entry.name}": $e');
      await _refresh();
      return;
    }
    await _edit(project, recovered: recovered);
  }

  Future<void> _edit(Project project, {bool recovered = false}) async {
    final controller = EditorController(
      project: project,
      store: _store,
      media: widget.services.media,
      autosaveDelay: Duration(seconds: widget.services.settings.value.autosaveSeconds),
      startDirty: recovered,
    );
    if (!mounted) {
      controller.dispose();
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => WorkspaceScreen(controller: controller)));
    await controller.close();
    await _refresh();
  }

  Future<void> _import() async {
    try {
      final doc = await widget.services.media.pickProjectFile();
      if (doc == null) return;
      final p = await _store.importText(doc.text);
      _snack('Imported "${p.name}"');
    } on ProjectFormatException catch (e) {
      _snack('Not a valid CUTLAB project: ${e.message}');
    } on Object catch (e) {
      _snack('Import failed: $e');
    }
    await _refresh();
  }

  Future<void> _action(ProjectEntry entry, _ProjectAction action) async {
    try {
      switch (action) {
        case _ProjectAction.rename:
          final name = await promptText(context, title: 'Rename project', initial: entry.name);
          if (name == null || name.trim().isEmpty) return;
          await _store.rename(entry.id, name.trim());
        case _ProjectAction.duplicate:
          final copy = await _store.duplicate(entry.id);
          _snack('Created "${copy.name}"');
        case _ProjectAction.export:
          final p = await _store.open(entry.id);
          final ok = await widget.services.media.saveProjectFile('${safeFileName(p.name)}.cutlab', _store.exportText(p));
          if (ok) _snack('Exported "${p.name}"');
        case _ProjectAction.delete:
          final sure = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Delete project?'),
              content: Text('"${entry.name}" will be deleted. Your media files are not touched.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: CutlabColors.danger),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Delete'),
                ),
              ],
            ),
          );
          if (sure != true) return;
          await _store.delete(entry.id);
      }
    } on Object catch (e) {
      _snack('Failed: $e');
    } finally {
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('CUTLAB', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.2)),
        actions: [
          IconButton(
            key: const Key('importProject'),
            tooltip: 'Import project (.cutlab)',
            icon: const Icon(Icons.file_open_outlined),
            onPressed: _import,
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => SettingsScreen(services: widget.services)),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('newProject'),
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('New project'),
      ),
      body: SafeArea(
        child: _loadError != null
            ? Center(child: Text('Could not read projects: $_loadError'))
            : entries == null
                ? const Center(child: CircularProgressIndicator())
                : entries.isEmpty
                    ? const _EmptyLibrary()
                    : RefreshIndicator(
                        onRefresh: _refresh,
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(CutlabSpacing.lg, CutlabSpacing.sm, CutlabSpacing.lg, 96),
                          itemCount: entries.length,
                          separatorBuilder: (_, __) => const SizedBox(height: CutlabSpacing.sm),
                          itemBuilder: (_, i) => _ProjectCard(
                            entry: entries[i],
                            onOpen: () => _open(entries[i]),
                            onAction: (a) => _action(entries[i], a),
                          ),
                        ),
                      ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(CutlabSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.movie_creation_outlined, size: 56, color: CutlabColors.accent),
              SizedBox(height: CutlabSpacing.md),
              Text('No projects yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              SizedBox(height: CutlabSpacing.xs),
              Text('Tap "New project" to start.', style: TextStyle(color: CutlabColors.textMuted)),
            ],
          ),
        ),
      );
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.entry, required this.onOpen, required this.onAction});

  final ProjectEntry entry;
  final VoidCallback onOpen;
  final ValueChanged<_ProjectAction> onAction;

  @override
  Widget build(BuildContext context) {
    final s = entry.settings;
    final details = entry.error != null
        ? 'Damaged file — ${entry.error}'
        : [
            if (s != null) '${s.width}×${s.height} · ${formatFps(s.frameRate)} fps',
            '${entry.mediaCount} media',
            if (entry.durationTicks > 0) formatDuration(entry.durationTicks),
          ].join(' · ');
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(CutlabSpacing.radius),
        onTap: entry.error == null ? onOpen : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(CutlabSpacing.lg, CutlabSpacing.md, CutlabSpacing.xs, CutlabSpacing.md),
          child: Row(
            children: [
              _AspectBadge(settings: s),
              const SizedBox(width: CutlabSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15), overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(details,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: entry.error != null ? CutlabColors.danger : CutlabColors.textMuted)),
                    if (entry.modifiedAt != null)
                      Text('Edited ${formatDateTime(entry.modifiedAt!)}', style: const TextStyle(fontSize: 12, color: CutlabColors.textMuted)),
                    if (entry.hasRecovery)
                      const Padding(
                        padding: EdgeInsets.only(top: CutlabSpacing.xs),
                        child: Text('Unsaved changes can be restored', style: TextStyle(fontSize: 12, color: CutlabColors.accent)),
                      ),
                  ],
                ),
              ),
              PopupMenuButton<_ProjectAction>(
                key: Key('projectMenu-${entry.id}'),
                tooltip: 'Project actions',
                onSelected: onAction,
                itemBuilder: (_) => [
                  if (entry.error == null) ...const [
                    PopupMenuItem(value: _ProjectAction.rename, child: Text('Rename')),
                    PopupMenuItem(value: _ProjectAction.duplicate, child: Text('Duplicate')),
                    PopupMenuItem(value: _ProjectAction.export, child: Text('Export .cutlab')),
                  ],
                  const PopupMenuItem(value: _ProjectAction.delete, child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AspectBadge extends StatelessWidget {
  const _AspectBadge({this.settings});
  final ProjectSettings? settings;

  @override
  Widget build(BuildContext context) {
    final s = settings;
    final ratio = s == null ? 1.0 : s.width / s.height;
    const box = 44.0;
    return SizedBox(
      width: box,
      height: box,
      child: Center(
        child: Container(
          width: ratio >= 1 ? box : box * ratio,
          height: ratio >= 1 ? box / ratio : box,
          decoration: BoxDecoration(
            border: Border.all(color: CutlabColors.accent, width: 2),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    );
  }
}
