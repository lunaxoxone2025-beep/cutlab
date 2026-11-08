/// Reading and writing .cutlab files: envelope, version migrations and
/// structural validation.
library;

import 'dart:convert';

import 'json_reader.dart';
import 'model.dart';

/// Identifies a CUTLAB project file.
const String projectFormatId = 'cutlab-project';

/// Current on-disk format version. Bump it together with a migration in
/// [defaultMigrations] whenever the JSON layout changes incompatibly.
const int currentFormatVersion = 2;

/// Transforms the `project` object of version N into version N + 1.
typedef Migration = Map<String, Object?> Function(Map<String, Object?> project);

/// Migrations keyed by the version they upgrade *from*.
const Map<int, Migration> defaultMigrations = {1: _v1ToV2};

/// v2 added image tracks and optional clip fields (fades, links). Every v1
/// file is already valid v2, so nothing needs rewriting.
Map<String, Object?> _v1ToV2(Map<String, Object?> project) => project;

class ProjectCodec {
  final Map<int, Migration> migrations;
  final int targetVersion;
  final String generator;

  const ProjectCodec({
    this.migrations = defaultMigrations,
    this.targetVersion = currentFormatVersion,
    this.generator = 'cutlab',
  });

  /// Serializes [project] to the pretty-printed .cutlab text.
  String encode(Project project) {
    final doc = {
      'format': projectFormatId,
      'formatVersion': targetVersion,
      'generator': generator,
      'project': project.toJson(),
    };
    return '${const JsonEncoder.withIndent('  ').convert(doc)}\n';
  }

  /// Parses .cutlab text, migrating older versions and validating the result.
  /// Throws [ProjectFormatException] with the JSON path of the first problem.
  Project decode(String text) {
    Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (e) {
      throw ProjectFormatException('not valid JSON: ${e.message}');
    }
    final root = JsonReader(json, r'$');
    if (root.raw('format') != projectFormatId) {
      throw const ProjectFormatException('not a CUTLAB project (missing "format": "cutlab-project")', r'$.format');
    }
    final version = root.integer('formatVersion', min: 1);
    if (version > targetVersion) {
      throw ProjectFormatException(
          'created by a newer CUTLAB (format $version); this build reads up to $targetVersion', r'$.formatVersion');
    }
    var body = JsonReader(root.raw('project'), r'$.project').map;
    for (var v = version; v < targetVersion; v++) {
      final step = migrations[v];
      if (step == null) {
        throw ProjectFormatException('no migration from format $v to ${v + 1}', r'$.formatVersion');
      }
      body = step(Map<String, Object?>.of(body));
    }
    final Project project;
    try {
      project = Project.fromReader(JsonReader(body, r'$.project'));
    } on ProjectFormatException {
      rethrow;
    } on FormatException catch (e) {
      throw ProjectFormatException(e.message, r'$.project');
    } on ArgumentError catch (e) {
      throw ProjectFormatException('${e.message}', r'$.project');
    }
    final issues = validateProject(project);
    if (issues.isNotEmpty) throw ProjectFormatException(issues.first.message, issues.first.path);
    return project;
  }
}

class ValidationIssue {
  final String path;
  final String message;
  const ValidationIssue(this.path, this.message);

  @override
  String toString() => '$path: $message';
}

/// Checks invariants that JSON types alone cannot express.
List<ValidationIssue> validateProject(Project p) {
  final issues = <ValidationIssue>[];
  final mediaIds = <String>{};
  for (var i = 0; i < p.media.length; i++) {
    if (!mediaIds.add(p.media[i].id)) issues.add(ValidationIssue('\$.project.media[$i].id', 'duplicate media id "${p.media[i].id}"'));
  }
  final trackIds = <String>{};
  final clipIds = <String>{};
  for (var t = 0; t < p.tracks.length; t++) {
    final track = p.tracks[t];
    final tp = '\$.project.tracks[$t]';
    if (!trackIds.add(track.id)) issues.add(ValidationIssue('$tp.id', 'duplicate track id "${track.id}"'));
    for (var c = 0; c < track.clips.length; c++) {
      final clip = track.clips[c];
      final cp = '$tp.clips[$c]';
      if (!clipIds.add(clip.id)) issues.add(ValidationIssue('$cp.id', 'duplicate clip id "${clip.id}"'));
      if (clip.mediaId != null && !mediaIds.contains(clip.mediaId)) {
        issues.add(ValidationIssue('$cp.mediaId', 'unknown media "${clip.mediaId}"'));
      } else if (clip.mediaId != null) {
        final kind = p.media.firstWhere((m) => m.id == clip.mediaId).kind;
        final ok = switch (track.kind) {
          TrackKind.video => kind == MediaKind.video || kind == MediaKind.image,
          TrackKind.image => kind == MediaKind.image,
          TrackKind.audio => kind == MediaKind.audio || kind == MediaKind.video,
          TrackKind.text => false,
        };
        if (!ok) issues.add(ValidationIssue('$cp.mediaId', '${kind.name} media on a ${track.kind.name} track'));
      }
      if (c > 0 && clip.startTicks < track.clips[c - 1].endTicks) {
        issues.add(ValidationIssue('$cp.startTicks', 'overlaps clip "${track.clips[c - 1].id}" on the same track'));
      }
      final tr = clip.transitionIn;
      if (tr != null && tr.durationTicks > clip.durationTicks) {
        issues.add(ValidationIssue('$cp.transitionIn', 'transition is longer than the clip'));
      }
    }
  }
  return issues;
}
