/// In-memory model of a CUTLAB project (format version 1).
///
/// All classes are immutable value objects. Times are integer ticks
/// (see time.dart). The JSON layout is documented in docs/PROJECT_FORMAT.md.
library;

import 'json_reader.dart';
import 'time.dart';

enum MediaKind { video, audio, image }

enum TrackKind { video, audio, text }

enum Interpolation { hold, linear, easeIn, easeOut, easeInOut, bezier }

enum EditorMode { beginner, advanced }

class ProjectSettings {
  final int width;
  final int height;
  final Rational frameRate;
  final int sampleRate;
  final int audioChannels;

  /// Canvas background: "#rrggbb" or "blur" (blurred copy of the active clip).
  final String background;

  const ProjectSettings({
    this.width = 1920,
    this.height = 1080,
    this.frameRate = Rational.fps30,
    this.sampleRate = 48000,
    this.audioChannels = 2,
    this.background = '#000000',
  });

  /// Common presets for new projects.
  static const landscape1080p = ProjectSettings();
  static const vertical1080p = ProjectSettings(width: 1080, height: 1920);
  static const square1080 = ProjectSettings(width: 1080, height: 1080);
  static const portrait4x5 = ProjectSettings(width: 1080, height: 1350);

  ProjectSettings copyWith({int? width, int? height, Rational? frameRate, int? sampleRate, int? audioChannels, String? background}) =>
      ProjectSettings(
        width: width ?? this.width,
        height: height ?? this.height,
        frameRate: frameRate ?? this.frameRate,
        sampleRate: sampleRate ?? this.sampleRate,
        audioChannels: audioChannels ?? this.audioChannels,
        background: background ?? this.background,
      );

  Map<String, Object?> toJson() => {
        'width': width,
        'height': height,
        'frameRate': frameRate.toJson(),
        'sampleRate': sampleRate,
        'audioChannels': audioChannels,
        'background': background,
      };

  static ProjectSettings fromReader(JsonReader r) {
    Rational fps;
    try {
      fps = Rational.fromJson(r.raw('frameRate'));
    } on FormatException catch (e) {
      throw ProjectFormatException(e.message, '${r.path}.frameRate');
    }
    if (!fps.isPositive) throw ProjectFormatException('frame rate must be positive', '${r.path}.frameRate');
    return ProjectSettings(
      width: r.integer('width', min: 16),
      height: r.integer('height', min: 16),
      frameRate: fps,
      sampleRate: r.integer('sampleRate', fallback: 48000, min: 8000),
      audioChannels: r.integer('audioChannels', fallback: 2, min: 1),
      background: r.string('background', fallback: '#000000'),
    );
  }
}

/// A reference to a source file. Media is never embedded in the project.
class MediaRef {
  final String id;
  final MediaKind kind;

  /// Absolute path, content:// URI or path relative to the project file.
  final String uri;
  final String displayName;
  final int durationTicks;
  final int? width;
  final int? height;
  final Rational? frameRate;
  final bool hasAudio;

  /// Cheap identity check used to detect moved/replaced files ("size:mtime").
  final String? fingerprint;
  final String? proxyUri;

  const MediaRef({
    required this.id,
    required this.kind,
    required this.uri,
    required this.displayName,
    required this.durationTicks,
    this.width,
    this.height,
    this.frameRate,
    this.hasAudio = false,
    this.fingerprint,
    this.proxyUri,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'uri': uri,
        'displayName': displayName,
        'durationTicks': durationTicks,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
        if (frameRate != null) 'frameRate': frameRate!.toJson(),
        'hasAudio': hasAudio,
        if (fingerprint != null) 'fingerprint': fingerprint,
        if (proxyUri != null) 'proxyUri': proxyUri,
      };

  static MediaRef fromReader(JsonReader r) => MediaRef(
        id: r.string('id'),
        kind: r.enumValue('kind', MediaKind.values),
        uri: r.string('uri'),
        displayName: r.string('displayName', fallback: ''),
        durationTicks: r.integer('durationTicks', min: 0),
        width: r.optInteger('width'),
        height: r.optInteger('height'),
        frameRate: r.has('frameRate') ? Rational.fromJson(r.raw('frameRate')) : null,
        hasAudio: r.boolean('hasAudio', fallback: false),
        fingerprint: r.optString('fingerprint'),
        proxyUri: r.optString('proxyUri'),
      );
}

class Keyframe {
  /// Offset from the clip start, in ticks.
  final int timeTicks;
  final double value;
  final Interpolation interpolation;

  /// Cubic bezier control points (x1, y1, x2, y2) when [interpolation] is bezier.
  final List<double>? bezier;

  const Keyframe({required this.timeTicks, required this.value, this.interpolation = Interpolation.linear, this.bezier});

  Map<String, Object?> toJson() => {
        'timeTicks': timeTicks,
        'value': value,
        'interpolation': interpolation.name,
        if (bezier != null) 'bezier': bezier,
      };

  static Keyframe fromReader(JsonReader r) {
    final interp = r.enumValue('interpolation', Interpolation.values, fallback: Interpolation.linear);
    List<double>? bez;
    final raw = r.raw('bezier');
    if (raw != null) {
      if (raw is! List<Object?> || raw.length != 4 || raw.any((v) => v is! num)) {
        throw ProjectFormatException('bezier must be 4 numbers', '${r.path}.bezier');
      }
      bez = [for (final v in raw) (v as num).toDouble()];
    }
    return Keyframe(timeTicks: r.integer('timeTicks', min: 0), value: r.number('value'), interpolation: interp, bezier: bez);
  }
}

/// One effect in a clip's ordered effect stack. Parameters are kept as a
/// plain JSON map so effects added later stay readable by older builds.
class Effect {
  final String id;
  final String type;
  final bool enabled;
  final Map<String, Object?> params;

  const Effect({required this.id, required this.type, this.enabled = true, this.params = const {}});

  Map<String, Object?> toJson() => {'id': id, 'type': type, 'enabled': enabled, 'params': params};

  static Effect fromReader(JsonReader r) =>
      Effect(id: r.string('id'), type: r.string('type'), enabled: r.boolean('enabled', fallback: true), params: r.plainMap('params'));
}

class Transition {
  final String type;
  final int durationTicks;

  const Transition({required this.type, required this.durationTicks});

  Map<String, Object?> toJson() => {'type': type, 'durationTicks': durationTicks};

  static Transition fromReader(JsonReader r) => Transition(type: r.string('type'), durationTicks: r.integer('durationTicks', min: 1));
}

class Clip {
  final String id;

  /// Source media. Null for generated clips (text, solid colour, adjustment).
  final String? mediaId;
  final int startTicks;
  final int durationTicks;

  /// Position inside the source where this clip begins, in source time.
  final int sourceInTicks;
  final Rational speed;
  final bool reversed;
  final double volume;
  final List<Effect> effects;
  final Transition? transitionIn;

  /// Animated properties: parameter path (e.g. "transform.scale") -> keyframes.
  final Map<String, List<Keyframe>> keyframes;

  /// Free-form settings for generated clips (text content, style…).
  final Map<String, Object?> data;

  const Clip({
    required this.id,
    this.mediaId,
    required this.startTicks,
    required this.durationTicks,
    this.sourceInTicks = 0,
    this.speed = Rational.one,
    this.reversed = false,
    this.volume = 1.0,
    this.effects = const [],
    this.transitionIn,
    this.keyframes = const {},
    this.data = const {},
  });

  int get endTicks => startTicks + durationTicks;

  Clip copyWith({int? startTicks, int? durationTicks, int? sourceInTicks, Rational? speed, double? volume, List<Effect>? effects}) => Clip(
        id: id,
        mediaId: mediaId,
        startTicks: startTicks ?? this.startTicks,
        durationTicks: durationTicks ?? this.durationTicks,
        sourceInTicks: sourceInTicks ?? this.sourceInTicks,
        speed: speed ?? this.speed,
        reversed: reversed,
        volume: volume ?? this.volume,
        effects: effects ?? this.effects,
        transitionIn: transitionIn,
        keyframes: keyframes,
        data: data,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        if (mediaId != null) 'mediaId': mediaId,
        'startTicks': startTicks,
        'durationTicks': durationTicks,
        'sourceInTicks': sourceInTicks,
        'speed': speed.toJson(),
        if (reversed) 'reversed': true,
        'volume': volume,
        'effects': [for (final e in effects) e.toJson()],
        if (transitionIn != null) 'transitionIn': transitionIn!.toJson(),
        if (keyframes.isNotEmpty)
          'keyframes': {
            for (final e in keyframes.entries) e.key: [for (final k in e.value) k.toJson()]
          },
        if (data.isNotEmpty) 'data': data,
      };

  static Clip fromReader(JsonReader r) {
    final kfReader = r.optObject('keyframes');
    final keyframes = <String, List<Keyframe>>{};
    if (kfReader != null) {
      for (final key in kfReader.map.keys) {
        keyframes[key] = kfReader.list(key, Keyframe.fromReader, optional: false);
      }
    }
    final speed = r.has('speed') ? Rational.fromJson(r.raw('speed')) : Rational.one;
    if (!speed.isPositive) throw ProjectFormatException('speed must be positive', '${r.path}.speed');
    return Clip(
      id: r.string('id'),
      mediaId: r.optString('mediaId'),
      startTicks: r.integer('startTicks', min: 0),
      durationTicks: r.integer('durationTicks', min: 1),
      sourceInTicks: r.integer('sourceInTicks', fallback: 0, min: 0),
      speed: speed,
      reversed: r.boolean('reversed', fallback: false),
      volume: r.number('volume', fallback: 1.0),
      effects: r.list('effects', Effect.fromReader),
      transitionIn: r.has('transitionIn') ? Transition.fromReader(r.object('transitionIn')) : null,
      keyframes: keyframes,
      data: r.plainMap('data'),
    );
  }
}

class Track {
  final String id;
  final TrackKind kind;
  final String name;
  final bool locked;
  final bool hidden;
  final bool muted;

  /// Optional group id; tracks sharing it move/lock together.
  final String? group;

  /// Clips sorted by start time; clips on one track never overlap.
  final List<Clip> clips;

  const Track({
    required this.id,
    required this.kind,
    this.name = '',
    this.locked = false,
    this.hidden = false,
    this.muted = false,
    this.group,
    this.clips = const [],
  });

  int get endTicks => clips.isEmpty ? 0 : clips.map((c) => c.endTicks).reduce((a, b) => a > b ? a : b);

  Track copyWith({String? name, bool? locked, bool? hidden, bool? muted, List<Clip>? clips}) => Track(
        id: id,
        kind: kind,
        name: name ?? this.name,
        locked: locked ?? this.locked,
        hidden: hidden ?? this.hidden,
        muted: muted ?? this.muted,
        group: group,
        clips: clips ?? this.clips,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'name': name,
        'locked': locked,
        'hidden': hidden,
        'muted': muted,
        if (group != null) 'group': group,
        'clips': [for (final c in clips) c.toJson()],
      };

  static Track fromReader(JsonReader r) {
    final clips = r.list('clips', Clip.fromReader)..sort((a, b) => a.startTicks.compareTo(b.startTicks));
    return Track(
      id: r.string('id'),
      kind: r.enumValue('kind', TrackKind.values),
      name: r.string('name', fallback: ''),
      locked: r.boolean('locked', fallback: false),
      hidden: r.boolean('hidden', fallback: false),
      muted: r.boolean('muted', fallback: false),
      group: r.optString('group'),
      clips: clips,
    );
  }
}

class Marker {
  final String id;
  final int timeTicks;
  final String label;
  final String color;

  const Marker({required this.id, required this.timeTicks, this.label = '', this.color = '#19e3c4'});

  Map<String, Object?> toJson() => {'id': id, 'timeTicks': timeTicks, 'label': label, 'color': color};

  static Marker fromReader(JsonReader r) => Marker(
        id: r.string('id'),
        timeTicks: r.integer('timeTicks', min: 0),
        label: r.string('label', fallback: ''),
        color: r.string('color', fallback: '#19e3c4'),
      );
}

class ExportSettings {
  final String container; // mp4 | mov | webm
  final String videoCodec; // h264 | hevc | av1 | vp9
  final int height;
  final Rational frameRate;
  final int videoBitrateKbps;
  final String audioCodec; // aac | opus
  final int audioBitrateKbps;

  const ExportSettings({
    this.container = 'mp4',
    this.videoCodec = 'h264',
    this.height = 1080,
    this.frameRate = Rational.fps30,
    this.videoBitrateKbps = 12000,
    this.audioCodec = 'aac',
    this.audioBitrateKbps = 192,
  });

  Map<String, Object?> toJson() => {
        'container': container,
        'videoCodec': videoCodec,
        'height': height,
        'frameRate': frameRate.toJson(),
        'videoBitrateKbps': videoBitrateKbps,
        'audioCodec': audioCodec,
        'audioBitrateKbps': audioBitrateKbps,
      };

  static ExportSettings fromReader(JsonReader r) => ExportSettings(
        container: r.string('container', fallback: 'mp4'),
        videoCodec: r.string('videoCodec', fallback: 'h264'),
        height: r.integer('height', fallback: 1080, min: 16),
        frameRate: r.has('frameRate') ? Rational.fromJson(r.raw('frameRate')) : Rational.fps30,
        videoBitrateKbps: r.integer('videoBitrateKbps', fallback: 12000, min: 1),
        audioCodec: r.string('audioCodec', fallback: 'aac'),
        audioBitrateKbps: r.integer('audioBitrateKbps', fallback: 192, min: 1),
      );
}

class Project {
  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final EditorMode editorMode;
  final ProjectSettings settings;
  final List<MediaRef> media;
  final List<Track> tracks;
  final List<Marker> markers;
  final ExportSettings exportSettings;

  const Project({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.modifiedAt,
    this.editorMode = EditorMode.beginner,
    this.settings = const ProjectSettings(),
    this.media = const [],
    this.tracks = const [],
    this.markers = const [],
    this.exportSettings = const ExportSettings(),
  });

  /// A new empty project with one video, one audio and one text track.
  factory Project.create({required String id, required String name, ProjectSettings settings = const ProjectSettings(), DateTime? now}) {
    final t = (now ?? DateTime.now()).toUtc();
    return Project(
      id: id,
      name: name,
      createdAt: t,
      modifiedAt: t,
      settings: settings,
      tracks: const [
        Track(id: 'v1', kind: TrackKind.video, name: 'Video 1'),
        Track(id: 'a1', kind: TrackKind.audio, name: 'Audio 1'),
        Track(id: 't1', kind: TrackKind.text, name: 'Text 1'),
      ],
    );
  }

  /// Timeline length: end of the last clip on any track.
  int get durationTicks => tracks.fold(0, (m, t) => t.endTicks > m ? t.endTicks : m);

  Project copyWith({
    String? name,
    DateTime? modifiedAt,
    EditorMode? editorMode,
    ProjectSettings? settings,
    List<MediaRef>? media,
    List<Track>? tracks,
    List<Marker>? markers,
    ExportSettings? exportSettings,
  }) =>
      Project(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        editorMode: editorMode ?? this.editorMode,
        settings: settings ?? this.settings,
        media: media ?? this.media,
        tracks: tracks ?? this.tracks,
        markers: markers ?? this.markers,
        exportSettings: exportSettings ?? this.exportSettings,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'modifiedAt': modifiedAt.toUtc().toIso8601String(),
        'editorMode': editorMode.name,
        'settings': settings.toJson(),
        'media': [for (final m in media) m.toJson()],
        'tracks': [for (final t in tracks) t.toJson()],
        'markers': [for (final m in markers) m.toJson()],
        'exportSettings': exportSettings.toJson(),
      };

  static Project fromReader(JsonReader r) {
    DateTime date(String key) {
      final parsed = DateTime.tryParse(r.string(key));
      if (parsed == null) throw ProjectFormatException('expected an ISO-8601 date', '${r.path}.$key');
      return parsed.toUtc();
    }

    return Project(
      id: r.string('id'),
      name: r.string('name', fallback: 'Untitled'),
      createdAt: date('createdAt'),
      modifiedAt: date('modifiedAt'),
      editorMode: r.enumValue('editorMode', EditorMode.values, fallback: EditorMode.beginner),
      settings: ProjectSettings.fromReader(r.object('settings')),
      media: r.list('media', MediaRef.fromReader),
      tracks: r.list('tracks', Track.fromReader),
      markers: r.list('markers', Marker.fromReader),
      exportSettings: r.has('exportSettings') ? ExportSettings.fromReader(r.object('exportSettings')) : const ExportSettings(),
    );
  }
}
