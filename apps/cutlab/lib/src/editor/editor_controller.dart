import 'dart:async';

import 'package:cutlab_project_format/cutlab_project_format.dart';
import 'package:flutter/foundation.dart';

import '../media/media_platform.dart';
import '../storage/project_store.dart';

enum SaveState { saved, unsaved, saving, error }

/// Owns the project being edited: every change goes through [edit], which
/// records undo history and schedules an autosave to the recovery file.
/// [save] writes the real project file.
class EditorController extends ChangeNotifier {
  EditorController({
    required Project project,
    required this.store,
    required this.media,
    Duration autosaveDelay = const Duration(seconds: 10),
    this.historyLimit = 200,
    DateTime Function()? clock,
    bool startDirty = false,
  })  : _project = project,
        _autosaveDelay = autosaveDelay,
        _clock = clock ?? DateTime.now,
        _state = startDirty ? SaveState.unsaved : SaveState.saved;

  final ProjectStore store;
  final MediaPlatform media;
  final int historyLimit;
  final Duration _autosaveDelay;
  final DateTime Function() _clock;

  Project _project;
  final List<Project> _undo = [];
  final List<Project> _redo = [];
  SaveState _state;
  String? _lastError;
  Timer? _autosaveTimer;
  bool _disposed = false;

  /// Media availability (true = file reachable). Missing ids are unknown.
  final Map<String, bool> _available = {};
  final Map<String, Uint8List?> _thumbs = {};
  final Set<String> _thumbsLoading = {};

  Project get project => _project;
  SaveState get saveState => _state;
  String? get lastError => _lastError;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  bool get hasUnsavedChanges => _state == SaveState.unsaved || _state == SaveState.error;

  /// Applies [change] as one undoable step.
  void edit(Project Function(Project p) change) {
    final next = change(_project);
    if (identical(next, _project)) return;
    _undo.add(_project);
    if (_undo.length > historyLimit) _undo.removeAt(0);
    _redo.clear();
    _setProject(next.copyWith(modifiedAt: _clock().toUtc()));
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(_project);
    _setProject(_undo.removeLast());
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_project);
    _setProject(_redo.removeLast());
  }

  void _setProject(Project p) {
    _project = p;
    _state = SaveState.unsaved;
    _scheduleAutosave();
    _notify();
  }

  void _scheduleAutosave() {
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(_autosaveDelay, () => unawaited(autosaveNow()));
  }

  /// Writes unsaved changes to the recovery file now.
  Future<void> autosaveNow() async {
    _autosaveTimer?.cancel();
    if (_state != SaveState.unsaved) return;
    try {
      await store.autosave(_project);
    } on Object catch (e) {
      _lastError = 'Autosave failed: $e';
      _notify();
    }
  }

  /// Writes the project file. Returns false (and sets [lastError]) on failure.
  Future<bool> save() async {
    _autosaveTimer?.cancel();
    final saving = _project;
    _state = SaveState.saving;
    _notify();
    try {
      await store.save(saving);
      // Edits made while saving keep the project dirty.
      _state = identical(saving, _project) ? SaveState.saved : SaveState.unsaved;
      _lastError = null;
      _notify();
      return true;
    } on Object catch (e) {
      _state = SaveState.error;
      _lastError = 'Save failed: $e';
      _notify();
      return false;
    }
  }

  // ------------------------------------------------------------------ edits

  void rename(String name) {
    final n = name.trim();
    if (n.isEmpty || n == _project.name) return;
    edit((p) => p.copyWith(name: n));
  }

  void setMode(EditorMode mode) {
    if (mode == _project.editorMode) return;
    edit((p) => p.copyWith(editorMode: mode));
  }

  void updateSettings(ProjectSettings settings) => edit((p) => p.copyWith(settings: settings));

  /// Opens the picker and adds the chosen files. Returns how many were added.
  Future<int> importMedia() async {
    final picked = await media.pickMedia();
    return addMedia(picked);
  }

  int addMedia(List<PickedMedia> picked) {
    if (picked.isEmpty) return 0;
    final existing = {for (final m in _project.media) m.uri};
    final fresh = [
      for (final p in picked)
        if (!existing.contains(p.uri)) p.toMediaRef(store.newId()),
    ];
    if (fresh.isEmpty) return 0;
    edit((p) => p.copyWith(media: [...p.media, ...fresh]));
    for (final m in fresh) {
      _available[m.id] = true;
    }
    _notify();
    return fresh.length;
  }

  /// Removes media that no clip uses. Returns false when it is still in use.
  bool removeMedia(String mediaId) {
    if (_project.clipsUsingMedia(mediaId) > 0) return false;
    edit((p) => p.copyWith(media: [for (final m in p.media) if (m.id != mediaId) m]));
    _available.remove(mediaId);
    _thumbs.remove(mediaId);
    return true;
  }

  /// Lets the user pick a replacement file for [mediaId]. Clips keep pointing
  /// at the same media id. Returns an error message, or null on success or cancel.
  Future<String?> relinkMedia(String mediaId) async {
    final current = _project.media.where((m) => m.id == mediaId).firstOrNull;
    if (current == null) return 'Media not found';
    final picked = await media.pickMedia(multiple: false);
    if (picked.isEmpty) return null;
    final replacement = picked.first;
    if (replacement.kind != current.kind) {
      return 'Choose a ${current.kind.name} file (you picked ${replacement.kind.name}).';
    }
    final relinked = current.relinkedTo(replacement.toMediaRef(mediaId));
    edit((p) => p.copyWith(media: [for (final m in p.media) m.id == mediaId ? relinked : m]));
    _available[mediaId] = true;
    _thumbs.remove(mediaId);
    _notify();
    return null;
  }

  // -------------------------------------------------------- media status

  /// null = not checked yet.
  bool? isAvailable(String mediaId) => _available[mediaId];

  int get missingCount => _project.media.where((m) => _available[m.id] == false).length;

  /// Checks every media file and records which ones are missing.
  Future<void> checkMedia() async {
    for (final m in _project.media) {
      bool ok;
      try {
        ok = await media.exists(m.uri);
      } on Object {
        ok = false;
      }
      if (_disposed) return;
      _available[m.id] = ok;
    }
    _notify();
  }

  /// Cached thumbnail; starts loading it on first request.
  Uint8List? thumbnailFor(MediaRef m) {
    if (_thumbs.containsKey(m.id)) return _thumbs[m.id];
    if (_thumbsLoading.add(m.id)) {
      unawaited(media.thumbnail(m.uri, m.kind).then((bytes) {
        _thumbs[m.id] = bytes;
      }, onError: (Object _) {
        _thumbs[m.id] = null;
      }).whenComplete(() {
        _thumbsLoading.remove(m.id);
        _notify();
      }));
    }
    return null;
  }

  Future<void>? _closing;

  /// Saves pending changes (if any) and disposes the controller. Safe to
  /// call more than once; every caller gets the same future.
  Future<void> close() => _closing ??= () async {
        if (hasUnsavedChanges && !await save()) {
          // Keep the work recoverable even if the real save failed.
          try {
            await store.autosave(_project);
          } on Object {
            // Nothing more we can do; lastError already describes the failure.
          }
        }
        dispose();
      }();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _autosaveTimer?.cancel();
    super.dispose();
  }
}
