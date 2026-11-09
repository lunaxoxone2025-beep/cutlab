/// Timeline editing operations on the immutable [Project] model.
///
/// Every operation returns a new project (the caller keeps the old one for
/// undo) or throws [EditException] with a message for the user. Positions are
/// snapped to the project frame grid, clips on one track never overlap, and
/// locked tracks are never modified.
library;

import 'effects.dart';
import 'model.dart';
import 'time.dart';

class EditException implements Exception {
  const EditException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Creates unique ids for new clips/tracks/links.
typedef IdGenerator = String Function();

/// A clip together with the track it lives on.
class PlacedClip {
  const PlacedClip(this.track, this.clip);
  final Track track;
  final Clip clip;
}

/// Copied clips, positions relative to the earliest one.
class ClipboardContent {
  const ClipboardContent(this.items);
  final List<ClipboardItem> items;
  bool get isEmpty => items.isEmpty;
}

class ClipboardItem {
  const ClipboardItem({required this.clip, required this.trackId, required this.trackKind, required this.offsetTicks});
  final Clip clip;
  final String trackId;
  final TrackKind trackKind;
  final int offsetTicks;
}

/// Default length of photos and titles when added to the timeline.
const int defaultStillDurationTicks = 5 * ticksPerSecond;
const int defaultTextDurationTicks = 3 * ticksPerSecond;

TrackKind trackKindFor(MediaKind kind) => switch (kind) {
      MediaKind.video => TrackKind.video,
      MediaKind.audio => TrackKind.audio,
      MediaKind.image => TrackKind.image,
    };

extension TimelineQueries on Project {
  Rational get fps => settings.frameRate;

  /// Length of one project frame at frame index [frame] (exact for every rate).
  int frameTicksAt(int ticks) {
    final f = ticksToFrames(ticks, fps);
    return framesToTicks(f + 1, fps) - framesToTicks(f, fps);
  }

  /// Nominal frame length (frame 0 → 1).
  int get frameTicks => framesToTicks(1, fps);

  /// [t] snapped to the nearest frame boundary (never negative).
  int quantize(int t) => t <= 0 ? 0 : snapToFrame(t, fps);

  Track? trackById(String id) => tracks.where((t) => t.id == id).firstOrNull;

  PlacedClip? find(String clipId) {
    for (final t in tracks) {
      for (final c in t.clips) {
        if (c.id == clipId) return PlacedClip(t, c);
      }
    }
    return null;
  }

  MediaRef? mediaById(String? id) => id == null ? null : media.where((m) => m.id == id).firstOrNull;

  /// All clips sharing [clipId]'s link (including itself).
  List<PlacedClip> linkedGroup(String clipId) {
    final pc = find(clipId);
    if (pc == null) return const [];
    final link = pc.clip.linkId;
    if (link == null) return [pc];
    return [
      for (final t in tracks)
        for (final c in t.clips)
          if (c.linkId == link) PlacedClip(t, c),
    ];
  }

  /// [ids] plus every clip linked to one of them.
  Set<String> withLinked(Iterable<String> ids) => {
        for (final id in ids)
          for (final pc in linkedGroup(id)) pc.clip.id,
      };

  /// Clips under time [t] (start <= t < end), bottom track first.
  List<PlacedClip> clipsAt(int t) => [
        for (final tr in tracks)
          for (final c in tr.clips)
            if (c.startTicks <= t && t < c.endTicks) PlacedClip(tr, c),
      ];

  /// The picture shown at [t]: the clip on the top-most visible video/image
  /// track (later tracks draw over earlier ones).
  PlacedClip? topVisualAt(int t) {
    for (final tr in tracks.reversed) {
      if (tr.hidden || (tr.kind != TrackKind.video && tr.kind != TrackKind.image)) continue;
      for (final c in tr.clips) {
        if (c.startTicks <= t && t < c.endTicks) return PlacedClip(tr, c);
      }
    }
    return null;
  }

  /// Source time shown at timeline time [t] inside [c].
  int sourceTimeAt(Clip c, int t) => c.sourceInTicks + mulDiv((t - c.startTicks).clamp(0, c.durationTicks), c.speed.num, c.speed.den);

  /// Edges a moving point can snap to: 0, the playhead, markers and every
  /// clip edge (except the clips in [exclude]).
  List<int> snapPoints({int? playhead, Set<String> exclude = const {}}) {
    final points = <int>{0, if (playhead != null) playhead, for (final m in markers) m.timeTicks};
    for (final t in tracks) {
      for (final c in t.clips) {
        if (exclude.contains(c.id)) continue;
        points
          ..add(c.startTicks)
          ..add(c.endTicks);
      }
    }
    return points.toList()..sort();
  }

  bool _free(Track t, int start, int end, Set<String> ignore) {
    for (final c in t.clips) {
      if (ignore.contains(c.id)) continue;
      if (c.startTicks < end && start < c.endTicks) return false;
    }
    return true;
  }
}

/// Nearest of [points] within [threshold] of [t]; [t] itself otherwise.
int snapTo(int t, List<int> points, int threshold) {
  var best = t;
  var bestDist = threshold + 1;
  for (final p in points) {
    final d = (p - t).abs();
    if (d < bestDist) {
      bestDist = d;
      best = p;
    }
  }
  return best;
}

/// Snaps a moving range [start, start+length): whichever edge is closer to a
/// snap point wins. Returns the new start.
int snapRange(int start, int length, List<int> points, int threshold) {
  final a = snapTo(start, points, threshold);
  final b = snapTo(start + length, points, threshold) - length;
  final da = (a - start).abs();
  final db = (b - start).abs();
  if (a == start && b == start) return start;
  if (a == start) return b;
  if (b == start) return a;
  return da <= db ? a : b;
}

extension TimelineEdits on Project {
  // ---------------------------------------------------------------- helpers

  Project _withTracks(List<Track> tracks) => copyWith(tracks: tracks);

  Project _replaceClips(Map<String, Clip> byId, {Map<String, String> moveTo = const {}}) {
    // Remove moved/replaced clips from their tracks, then insert into targets.
    final targets = <String, List<Clip>>{};
    final out = <Track>[];
    for (final t in tracks) {
      final kept = <Clip>[];
      for (final c in t.clips) {
        final repl = byId[c.id];
        if (repl == null) {
          kept.add(c);
          continue;
        }
        final dest = moveTo[c.id] ?? t.id;
        targets.putIfAbsent(dest, () => []).add(repl);
      }
      out.add(t.copyWith(clips: kept));
    }
    return _withTracks([
      for (final t in out)
        if (targets[t.id] == null) t else t.copyWith(clips: _sorted([...t.clips, ...targets[t.id]!])),
    ]);
  }

  static List<Clip> _sorted(List<Clip> clips) => clips..sort((a, b) => a.startTicks.compareTo(b.startTicks));

  void _checkUnlocked(Track t) {
    if (t.locked) throw EditException('Track "${t.name}" is locked');
  }

  Track _newTrack(TrackKind kind, IdGenerator ids) {
    final n = tracks.where((t) => t.kind == kind).length + 1;
    final label = switch (kind) {
      TrackKind.video => 'Video',
      TrackKind.audio => 'Audio',
      TrackKind.text => 'Text',
      TrackKind.image => 'Image',
    };
    return Track(id: ids(), kind: kind, name: '$label $n');
  }

  /// Track order puts new tracks of a kind next to the others of that kind
  /// (above them for pictures, below for audio).
  Project _insertTrack(Track t) {
    final list = [...tracks];
    final lastSame = list.lastIndexWhere((x) => x.kind == t.kind);
    if (lastSame < 0) {
      // Visual tracks go after video; audio and text at the end.
      final lastVideo = list.lastIndexWhere((x) => x.kind == TrackKind.video);
      list.insert(t.kind == TrackKind.image && lastVideo >= 0 ? lastVideo + 1 : list.length, t);
    } else {
      list.insert(lastSame + 1, t);
    }
    return _withTracks(list);
  }

  /// Track of [kind] where [start, end) is free: [preferred] first, then the
  /// others of that kind; creates one when all are busy.
  (Project, String) _trackFor(TrackKind kind, int start, int end, IdGenerator ids, {String? preferred, Set<String> ignore = const {}}) {
    final candidates = [
      if (preferred != null) ...tracks.where((t) => t.id == preferred && t.kind == kind),
      ...tracks.where((t) => t.kind == kind && t.id != preferred),
    ];
    for (final t in candidates) {
      if (!t.locked && _free(t, start, end, ignore)) return (this, t.id);
    }
    final nt = _newTrack(kind, ids);
    return (_insertTrack(nt), nt.id);
  }

  // ------------------------------------------------------------------ add

  /// Adds [mediaId] at [at] (snapped to a frame) on the first free track of
  /// the matching kind, creating a track if needed. Returns the new project
  /// and the new clip id.
  (Project, String) addMediaClip(String mediaId, int at, IdGenerator ids, {String? trackId}) {
    final m = mediaById(mediaId);
    if (m == null) throw const EditException('Media not found');
    final start = quantize(at);
    int duration;
    if (m.kind == MediaKind.image) {
      duration = quantize(defaultStillDurationTicks);
    } else {
      if (m.durationTicks <= 0) {
        throw EditException('"${m.displayName}" is still being analysed; try again in a moment');
      }
      // Whole frames only (the last partial frame of the file is left out).
      duration = framesToTicks(ticksToFrames(m.durationTicks, fps), fps);
      if (duration <= 0) throw EditException('"${m.displayName}" is shorter than one frame');
    }
    final (p, tid) = _trackFor(trackKindFor(m.kind), start, start + duration, ids, preferred: trackId);
    final clip = Clip(id: ids(), mediaId: m.id, startTicks: start, durationTicks: duration);
    final tracks2 = [
      for (final t in p.tracks)
        if (t.id == tid) t.copyWith(clips: _sorted([...t.clips, clip])) else t,
    ];
    return (p._withTracks(tracks2), clip.id);
  }

  /// Adds a title clip with [text].
  (Project, String) addTextClip(String text, int at, IdGenerator ids, {int durationTicks = defaultTextDurationTicks}) {
    final start = quantize(at);
    final duration = quantize(durationTicks).clamp(frameTicks, 1 << 50);
    final (p, tid) = _trackFor(TrackKind.text, start, start + duration, ids);
    final clip = Clip(id: ids(), startTicks: start, durationTicks: duration, data: {'text': text});
    return (
      p._withTracks([
        for (final t in p.tracks)
          if (t.id == tid) t.copyWith(clips: _sorted([...t.clips, clip])) else t,
      ]),
      clip.id,
    );
  }

  // ----------------------------------------------------------------- move

  /// Moves one clip (and its linked clips by the same amount) to [newStart]
  /// on [targetTrackId] (same kind). When the spot is taken the clip goes to
  /// another free track of that kind, or a new one — nothing is overwritten.
  Project moveClip(String clipId, int newStart, IdGenerator ids, {String? targetTrackId}) {
    final pc = find(clipId);
    if (pc == null) throw const EditException('Clip not found');
    _checkUnlocked(pc.track);
    var start = quantize(newStart);
    final delta = start - pc.clip.startTicks;
    final group = linkedGroup(clipId);
    // Keep every linked clip at >= 0.
    final minStart = group.map((g) => g.clip.startTicks).reduce((a, b) => a < b ? a : b);
    var d = delta;
    if (minStart + d < 0) d = -minStart;
    start = pc.clip.startTicks + d;

    var target = targetTrackId == null ? pc.track : (trackById(targetTrackId) ?? pc.track);
    if (target.kind != pc.track.kind) target = pc.track;
    _checkUnlocked(target);

    var p = this;
    final moving = {for (final g in group) g.clip.id};
    final byId = <String, Clip>{};
    final moveTo = <String, String>{};
    for (final g in group) {
      _checkUnlocked(g.track);
      final c = g.clip;
      final s = c.startTicks + d;
      final preferred = c.id == clipId ? target.id : g.track.id;
      final (np, tid) = p._trackFor(g.track.kind, s, s + c.durationTicks, ids, preferred: preferred, ignore: moving);
      p = np;
      // Reserve the spot so linked clips of the same kind do not collide.
      byId[c.id] = c.copyWith(startTicks: s);
      moveTo[c.id] = tid;
    }
    return p._replaceClips(byId, moveTo: moveTo);
  }

  /// Shifts several clips (plus linked ones) in time by [deltaTicks],
  /// staying on their tracks. Fails if any would hit another clip.
  Project moveClipsBy(Iterable<String> clipIds, int deltaTicks) {
    final ids = withLinked(clipIds);
    if (ids.isEmpty) return this;
    final placed = [for (final id in ids) find(id)!];
    for (final pc in placed) {
      _checkUnlocked(pc.track);
    }
    final earliest = placed.map((pc) => pc.clip.startTicks).reduce((a, b) => a < b ? a : b);
    var d = deltaTicks;
    if (earliest + d < 0) d = -earliest;
    d = quantize(earliest + d) - earliest;
    if (d == 0) return this;
    for (final pc in placed) {
      final s = pc.clip.startTicks + d;
      if (!_free(pc.track, s, s + pc.clip.durationTicks, ids)) {
        throw const EditException('Not enough room: another clip is in the way');
      }
    }
    return _replaceClips({for (final pc in placed) pc.clip.id: pc.clip.copyWith(startTicks: pc.clip.startTicks + d)});
  }

  /// Moves clips by whole frames (A/V sync nudging).
  Project nudge(Iterable<String> clipIds, int frames, {bool includeLinked = false}) {
    final ids = includeLinked ? withLinked(clipIds) : clipIds.toSet();
    final placed = [for (final id in ids) find(id)].whereType<PlacedClip>().toList();
    if (placed.isEmpty) return this;
    for (final pc in placed) {
      _checkUnlocked(pc.track);
      if (pc.clip.linkId != null && !includeLinked) {
        throw const EditException('Unlink the clips first to shift audio against video');
      }
    }
    final d = frames * frameTicks;
    for (final pc in placed) {
      final s = pc.clip.startTicks + d;
      if (s < 0) throw const EditException('Cannot move before the start of the timeline');
      if (!_free(pc.track, s, s + pc.clip.durationTicks, ids)) throw const EditException('Not enough room: another clip is in the way');
    }
    return _replaceClips({for (final pc in placed) pc.clip.id: pc.clip.copyWith(startTicks: pc.clip.startTicks + d)});
  }

  // ----------------------------------------------------------------- trim

  int _maxSourceEnd(Clip c) {
    final m = mediaById(c.mediaId);
    if (m == null || m.kind == MediaKind.image || m.durationTicks <= 0) return 1 << 60; // stills/text: unlimited
    return m.durationTicks;
  }

  /// Moves the clip's start edge to [newStart] (the end stays). Clamped to
  /// the source media, the previous clip and a minimum of one frame.
  /// Linked clips are trimmed the same way.
  Project trimStart(String clipId, int newStart) {
    final pc = find(clipId);
    if (pc == null) throw const EditException('Clip not found');
    var t = quantize(newStart);
    final group = linkedGroup(clipId);
    for (final g in group) {
      _checkUnlocked(g.track);
      final c = g.clip;
      final end = c.endTicks;
      // Not past the end (keep one frame) …
      final maxStart = end - frameTicks;
      // … not before the source start …
      final minBySource = c.startTicks - mulDiv(c.sourceInTicks, c.speed.den, c.speed.num, Rounding.down);
      // … and not into the previous clip.
      var minByNeighbour = 0;
      for (final o in g.track.clips) {
        if (o.id != c.id && o.endTicks <= c.startTicks && o.endTicks > minByNeighbour) minByNeighbour = o.endTicks;
      }
      final lo = quantizeUp(minBySource > minByNeighbour ? minBySource : minByNeighbour);
      if (t < lo) t = lo;
      if (t > maxStart) t = maxStart;
    }
    final d = t - pc.clip.startTicks;
    if (d == 0) return this;
    return _replaceClips({
      for (final g in group)
        g.clip.id: g.clip.copyWith(
          startTicks: g.clip.startTicks + d,
          durationTicks: g.clip.durationTicks - d,
          sourceInTicks: g.clip.sourceInTicks + mulDiv(d, g.clip.speed.num, g.clip.speed.den),
          fadeInTicks: g.clip.fadeInTicks.clamp(0, g.clip.durationTicks - d),
          fadeOutTicks: g.clip.fadeOutTicks.clamp(0, g.clip.durationTicks - d),
          videoFadeInTicks: g.clip.videoFadeInTicks.clamp(0, g.clip.durationTicks - d),
          videoFadeOutTicks:
              (g.clip.videoFadeOutTicks).clamp(0, g.clip.durationTicks - d - g.clip.videoFadeInTicks.clamp(0, g.clip.durationTicks - d)),
        ),
    });
  }

  /// Moves the clip's end edge to [newEnd]. Clamped to the source media,
  /// the next clip and a minimum of one frame. Linked clips follow.
  Project trimEnd(String clipId, int newEnd) {
    final pc = find(clipId);
    if (pc == null) throw const EditException('Clip not found');
    var t = quantize(newEnd);
    final group = linkedGroup(clipId);
    final d0 = t - pc.clip.endTicks;
    var d = d0;
    for (final g in group) {
      _checkUnlocked(g.track);
      final c = g.clip;
      var end = c.endTicks + d;
      if (end < c.startTicks + frameTicks) end = c.startTicks + frameTicks;
      final sourceRoom = _maxSourceEnd(c) - c.sourceInTicks;
      final maxBySource = c.startTicks + mulDiv(sourceRoom, c.speed.den, c.speed.num, Rounding.down);
      var maxByNeighbour = 1 << 60;
      for (final o in g.track.clips) {
        if (o.id != c.id && o.startTicks >= c.endTicks && o.startTicks < maxByNeighbour) maxByNeighbour = o.startTicks;
      }
      final hi = quantizeDown(maxBySource < maxByNeighbour ? maxBySource : maxByNeighbour);
      if (end > hi) end = hi;
      d = end - c.endTicks;
    }
    // Apply the most restrictive change to the whole group.
    for (final g in group) {
      final e = g.clip.endTicks + d;
      if (e < g.clip.startTicks + frameTicks) d = g.clip.startTicks + frameTicks - g.clip.endTicks;
    }
    if (d == 0) return this;
    return _replaceClips({
      for (final g in group)
        g.clip.id: g.clip.copyWith(
          durationTicks: g.clip.durationTicks + d,
          fadeInTicks: g.clip.fadeInTicks.clamp(0, g.clip.durationTicks + d),
          fadeOutTicks: g.clip.fadeOutTicks.clamp(0, g.clip.durationTicks + d),
          videoFadeInTicks: g.clip.videoFadeInTicks.clamp(0, g.clip.durationTicks + d),
          videoFadeOutTicks:
              g.clip.videoFadeOutTicks.clamp(0, g.clip.durationTicks + d - g.clip.videoFadeInTicks.clamp(0, g.clip.durationTicks + d)),
        ),
    });
  }

  int quantizeUp(int t) {
    final q = quantize(t);
    return q < t ? q + frameTicksAt(q) : q;
  }

  int quantizeDown(int t) {
    final q = quantize(t);
    return q > t ? q - frameTicksAt(q - 1) : q;
  }

  /// Sets the length of a photo or title (other clips: use trimEnd).
  Project setDuration(String clipId, int durationTicks) {
    final pc = find(clipId);
    if (pc == null) throw const EditException('Clip not found');
    final m = mediaById(pc.clip.mediaId);
    if (m != null && m.kind != MediaKind.image) {
      throw const EditException('Video and audio length comes from the file: trim the clip instead');
    }
    return trimEnd(clipId, pc.clip.startTicks + durationTicks);
  }

  // ---------------------------------------------------------------- split

  /// Splits the given clips (or, if [clipIds] is null, every clip on an
  /// unlocked track) at frame [at]. Linked clips are split together and the
  /// right-hand halves keep a new shared link. Returns the ids of the new
  /// right-hand clips.
  (Project, List<String>) split(int at, IdGenerator ids, {Iterable<String>? clipIds}) {
    final t = quantize(at);
    final selected = clipIds == null
        ? {
            for (final tr in tracks)
              if (!tr.locked)
                for (final c in tr.clips)
                  if (c.startTicks < t && t < c.endTicks) c.id,
          }
        : withLinked(clipIds);
    final targets = [
      for (final id in selected)
        if (find(id) case final pc? when pc.clip.startTicks < t && t < pc.clip.endTicks) pc,
    ];
    if (targets.isEmpty) throw const EditException('Move the playhead inside a clip to split it');
    for (final pc in targets) {
      _checkUnlocked(pc.track);
    }
    final newLinks = <String, String>{};
    final created = <String>[];
    final out = <Track>[];
    for (final tr in tracks) {
      final clips = <Clip>[];
      for (final c in tr.clips) {
        if (!targets.any((pc) => pc.clip.id == c.id)) {
          clips.add(c);
          continue;
        }
        final leftDur = t - c.startTicks;
        final rightDur = c.endTicks - t;
        final rightId = ids();
        created.add(rightId);
        final link = c.linkId == null ? null : newLinks.putIfAbsent(c.linkId!, ids);
        clips
          ..add(c.copyWith(
            durationTicks: leftDur,
            fadeOutTicks: 0,
            fadeInTicks: c.fadeInTicks.clamp(0, leftDur),
            videoFadeOutTicks: 0,
            videoFadeInTicks: c.videoFadeInTicks.clamp(0, leftDur),
            keyframes: _keyframesBefore(c.keyframes, leftDur),
          ))
          ..add(c.copyWith(
            id: rightId,
            startTicks: t,
            durationTicks: rightDur,
            sourceInTicks: c.sourceInTicks + mulDiv(leftDur, c.speed.num, c.speed.den),
            fadeInTicks: 0,
            fadeOutTicks: c.fadeOutTicks.clamp(0, rightDur),
            videoFadeInTicks: 0,
            videoFadeOutTicks: c.videoFadeOutTicks.clamp(0, rightDur),
            linkId: link,
            transitionIn: null,
            keyframes: _keyframesFrom(c.keyframes, leftDur),
          ));
      }
      out.add(tr.copyWith(clips: clips));
    }
    return (_withTracks(out), created);
  }

  static Map<String, List<Keyframe>> _keyframesBefore(Map<String, List<Keyframe>> k, int t) => {
        for (final e in k.entries)
          if (e.value.any((kf) => kf.timeTicks < t))
            e.key: [
              for (final kf in e.value)
                if (kf.timeTicks < t) kf
            ],
      };

  static Map<String, List<Keyframe>> _keyframesFrom(Map<String, List<Keyframe>> k, int t) => {
        for (final e in k.entries)
          if (e.value.any((kf) => kf.timeTicks >= t))
            e.key: [
              for (final kf in e.value)
                if (kf.timeTicks >= t)
                  Keyframe(timeTicks: kf.timeTicks - t, value: kf.value, interpolation: kf.interpolation, bezier: kf.bezier),
            ],
      };

  // --------------------------------------------------------------- delete

  /// Removes clips (and linked ones). With [ripple], later clips on the
  /// same tracks slide left to close each gap.
  Project deleteClips(Iterable<String> clipIds, {bool ripple = false}) {
    final ids = withLinked(clipIds);
    if (ids.isEmpty) return this;
    final out = <Track>[];
    for (final tr in tracks) {
      final removed = tr.clips.where((c) => ids.contains(c.id)).toList();
      if (removed.isEmpty) {
        out.add(tr);
        continue;
      }
      _checkUnlocked(tr);
      var kept = tr.clips.where((c) => !ids.contains(c.id)).toList();
      if (ripple) {
        kept = [
          for (final c in kept)
            c.copyWith(
              startTicks: c.startTicks - removed.where((r) => r.endTicks <= c.startTicks).fold<int>(0, (sum, r) => sum + r.durationTicks),
            ),
        ];
      }
      out.add(tr.copyWith(clips: kept));
    }
    return _withTracks(out);
  }

  // ------------------------------------------------ duplicate / copy / paste

  ClipboardContent copy(Iterable<String> clipIds) {
    final ids = withLinked(clipIds);
    final placed = [for (final id in ids) find(id)].whereType<PlacedClip>().toList();
    if (placed.isEmpty) return const ClipboardContent([]);
    final earliest = placed.map((pc) => pc.clip.startTicks).reduce((a, b) => a < b ? a : b);
    placed.sort((a, b) => a.clip.startTicks.compareTo(b.clip.startTicks));
    return ClipboardContent([
      for (final pc in placed)
        ClipboardItem(clip: pc.clip, trackId: pc.track.id, trackKind: pc.track.kind, offsetTicks: pc.clip.startTicks - earliest),
    ]);
  }

  /// Pastes copied clips starting at [at]: each on its original track when
  /// free, otherwise on another track of the same kind (or a new one).
  /// Links inside the pasted group are kept (with fresh link ids).
  (Project, List<String>) paste(ClipboardContent content, int at, IdGenerator ids) {
    if (content.isEmpty) throw const EditException('Nothing to paste');
    final base = quantize(at);
    var p = this;
    final links = <String, String>{};
    final created = <String>[];
    for (final item in content.items) {
      if (item.clip.mediaId != null && p.mediaById(item.clip.mediaId) == null) {
        throw const EditException('The copied clips use media that is not in this project');
      }
      final s = base + item.offsetTicks;
      final (np, tid) = p._trackFor(item.trackKind, s, s + item.clip.durationTicks, ids, preferred: item.trackId);
      final link = item.clip.linkId == null ? null : links.putIfAbsent(item.clip.linkId!, ids);
      final clip = item.clip.copyWith(id: ids(), startTicks: s, linkId: link);
      created.add(clip.id);
      p = np._withTracks([
        for (final t in np.tracks)
          if (t.id == tid) t.copyWith(clips: _sorted([...t.clips, clip])) else t,
      ]);
    }
    return (p, created);
  }

  /// Copies of the clips placed right after the last selected one.
  (Project, List<String>) duplicate(Iterable<String> clipIds, IdGenerator ids) {
    final content = copy(clipIds);
    if (content.isEmpty) throw const EditException('Select clips to duplicate');
    final end = [for (final i in content.items) i.clip.endTicks].reduce((a, b) => a > b ? a : b);
    return paste(content, end, ids);
  }

  // ---------------------------------------------------------------- audio

  Project setVolume(Iterable<String> clipIds, double volume) {
    final v = volume.clamp(0.0, 2.0);
    final placed = [for (final id in clipIds) find(id)].whereType<PlacedClip>().toList();
    for (final pc in placed) {
      _checkUnlocked(pc.track);
    }
    return _replaceClips({for (final pc in placed) pc.clip.id: pc.clip.copyWith(volume: v)});
  }

  /// Fade lengths, snapped to frames and limited so they fit in the clip.
  Project setFades(String clipId, {int? fadeInTicks, int? fadeOutTicks}) {
    final pc = find(clipId);
    if (pc == null) throw const EditException('Clip not found');
    _checkUnlocked(pc.track);
    final c = pc.clip;
    var fi = quantize(fadeInTicks ?? c.fadeInTicks).clamp(0, c.durationTicks);
    var fo = quantize(fadeOutTicks ?? c.fadeOutTicks).clamp(0, c.durationTicks);
    if (fi + fo > c.durationTicks) {
      if (fadeInTicks != null) {
        fo = c.durationTicks - fi;
      } else {
        fi = c.durationTicks - fo;
      }
    }
    return _replaceClips({c.id: c.copyWith(fadeInTicks: fi, fadeOutTicks: fo)});
  }

  /// Puts the sound of a video clip on an audio track as its own clip,
  /// linked to the video so they stay in sync. The video clip is muted.
  (Project, String) detachAudio(String videoClipId, IdGenerator ids) {
    final pc = find(videoClipId);
    if (pc == null) throw const EditException('Clip not found');
    final m = mediaById(pc.clip.mediaId);
    if (pc.track.kind != TrackKind.video || m == null || !m.hasAudio) {
      throw const EditException('This clip has no sound to separate');
    }
    _checkUnlocked(pc.track);
    final c = pc.clip;
    final link = c.linkId ?? ids();
    final (p0, tid) = _trackFor(TrackKind.audio, c.startTicks, c.endTicks, ids);
    final audio = Clip(
      id: ids(),
      mediaId: c.mediaId,
      startTicks: c.startTicks,
      durationTicks: c.durationTicks,
      sourceInTicks: c.sourceInTicks,
      speed: c.speed,
      volume: c.volume,
      linkId: link,
    );
    final p1 = p0._withTracks([
      for (final t in p0.tracks)
        if (t.id == tid) t.copyWith(clips: _sorted([...t.clips, audio])) else t,
    ]);
    return (p1._replaceClips({c.id: c.copyWith(volume: 0, linkId: link)}), audio.id);
  }

  /// Links clips so they move and trim together.
  Project link(Iterable<String> clipIds, IdGenerator ids) {
    final placed = [for (final id in clipIds) find(id)].whereType<PlacedClip>().toList();
    if (placed.length < 2) throw const EditException('Select at least two clips to link');
    final l = ids();
    return _replaceClips({for (final pc in placed) pc.clip.id: pc.clip.copyWith(linkId: l)});
  }

  Project unlink(Iterable<String> clipIds) {
    final ids = withLinked(clipIds);
    return _replaceClips({
      for (final id in ids)
        if (find(id) case final pc?) id: pc.clip.copyWith(linkId: null),
    });
  }

  Project setText(String clipId, String text) {
    final pc = find(clipId);
    if (pc == null || pc.track.kind != TrackKind.text) throw const EditException('Not a text clip');
    _checkUnlocked(pc.track);
    return _replaceClips({
      clipId: pc.clip.copyWith(data: {...pc.clip.data, 'text': text})
    });
  }

  // ---------------------------------------------- effects and transitions

  PlacedClip _visualClip(String clipId) {
    final pc = find(clipId);
    if (pc == null) throw const EditException('Clip not found');
    if (pc.track.kind != TrackKind.video && pc.track.kind != TrackKind.image) {
      throw const EditException('Effects apply to video and photo clips');
    }
    _checkUnlocked(pc.track);
    return pc;
  }

  Effect _checked(Effect e) {
    final spec = effectSpec(e.type);
    if (spec == null) return e; // unknown (newer) types are kept as they are
    return e.copyWith(params: {
      ...e.params,
      for (final prm in spec.params)
        if (e.params[prm.name] is num) prm.name: prm.clamp((e.params[prm.name]! as num).toDouble()),
    });
  }

  /// Adds effects at the end of the clip's stack (or at [index]).
  Project addEffects(String clipId, List<Effect> effects, {int? index}) {
    final pc = _visualClip(clipId);
    final list = [...pc.clip.effects];
    final at = (index ?? list.length).clamp(0, list.length);
    list.insertAll(at, effects.map(_checked));
    return _replaceClips({clipId: pc.clip.copyWith(effects: list)});
  }

  /// Replaces the whole stack (looks / presets, reset).
  Project setEffects(String clipId, List<Effect> effects) {
    final pc = _visualClip(clipId);
    return _replaceClips({clipId: pc.clip.copyWith(effects: effects.map(_checked).toList())});
  }

  /// Changes parameter values (merged into the existing ones, clamped to
  /// their range) and/or switches the effect on or off.
  Project updateEffect(String clipId, String effectId, {Map<String, double>? params, bool? enabled}) {
    final pc = _visualClip(clipId);
    final i = pc.clip.effects.indexWhere((e) => e.id == effectId);
    if (i < 0) throw const EditException('Effect not found');
    final e = pc.clip.effects[i];
    final next = _checked(e.copyWith(enabled: enabled, params: params == null ? null : {...e.params, ...params}));
    final list = [...pc.clip.effects]..[i] = next;
    return _replaceClips({clipId: pc.clip.copyWith(effects: list)});
  }

  Project removeEffect(String clipId, String effectId) {
    final pc = _visualClip(clipId);
    return _replaceClips({
      clipId: pc.clip.copyWith(effects: [
        for (final e in pc.clip.effects)
          if (e.id != effectId) e
      ])
    });
  }

  /// Moves an effect to [newIndex] in the stack (effects apply top to bottom).
  Project moveEffect(String clipId, String effectId, int newIndex) {
    final pc = _visualClip(clipId);
    final list = [...pc.clip.effects];
    final i = list.indexWhere((e) => e.id == effectId);
    if (i < 0) throw const EditException('Effect not found');
    final e = list.removeAt(i);
    list.insert(newIndex.clamp(0, list.length), e);
    return _replaceClips({clipId: pc.clip.copyWith(effects: list)});
  }

  /// Copies [fromClipId]'s effects onto other clips (fresh effect ids).
  Project copyEffects(String fromClipId, Iterable<String> toClipIds, IdGenerator ids) {
    final src = _visualClip(fromClipId).clip.effects;
    var p = this;
    for (final id in toClipIds) {
      if (id == fromClipId) continue;
      final pc = find(id);
      if (pc == null || (pc.track.kind != TrackKind.video && pc.track.kind != TrackKind.image)) continue;
      p = p.setEffects(id, [for (final e in src) Effect(id: ids(), type: e.type, enabled: e.enabled, params: e.params)]);
    }
    return p;
  }

  /// Picture fades from/to black, snapped to frames and fitted in the clip.
  Project setVideoFades(String clipId, {int? fadeInTicks, int? fadeOutTicks}) {
    final pc = _visualClip(clipId);
    final c = pc.clip;
    var fi = quantize(fadeInTicks ?? c.videoFadeInTicks).clamp(0, c.durationTicks);
    var fo = quantize(fadeOutTicks ?? c.videoFadeOutTicks).clamp(0, c.durationTicks);
    if (fi + fo > c.durationTicks) {
      if (fadeInTicks != null) {
        fo = c.durationTicks - fi;
      } else {
        fi = c.durationTicks - fo;
      }
    }
    return _replaceClips({c.id: c.copyWith(videoFadeInTicks: fi, videoFadeOutTicks: fo)});
  }

  /// The clip just before [clipId] on its track, when it ends exactly where
  /// [clipId] starts (a transition needs that cut).
  Clip? clipBefore(String clipId) {
    final pc = find(clipId);
    if (pc == null) return null;
    final i = pc.track.clips.indexWhere((c) => c.id == clipId);
    if (i <= 0) return null;
    final a = pc.track.clips[i - 1];
    return a.endTicks == pc.clip.startTicks ? a : null;
  }

  /// The clip just after [clipId] on its track, starting exactly at its end.
  Clip? clipAfter(String clipId) {
    final pc = find(clipId);
    if (pc == null) return null;
    final i = pc.track.clips.indexWhere((c) => c.id == clipId);
    if (i < 0 || i + 1 >= pc.track.clips.length) return null;
    final b = pc.track.clips[i + 1];
    return b.startTicks == pc.clip.endTicks ? b : null;
  }

  /// How the transition into [clipId] plays (null: none plays).
  TransitionSpan? transitionInto(String clipId) {
    final pc = find(clipId);
    if (pc == null) return null;
    return transitionSpan(this, pc.track, pc.track.clips.indexWhere((c) => c.id == clipId));
  }

  /// Sets (or with null removes) the transition from the previous clip into
  /// [clipId]. The duration is snapped to frames: at least two frames, at
  /// most what the two clips allow ([maxTransitionTicks]).
  Project setTransition(String clipId, Transition? transition) {
    final pc = _visualClip(clipId);
    if (transition == null) {
      if (pc.clip.transitionIn == null) return this;
      return _replaceClips({clipId: pc.clip.copyWith(transitionIn: null)});
    }
    if (clipBefore(clipId) == null) throw const EditException('A transition needs a clip right before this one on the same track');
    final spec = transitionSpec(transition.type);
    if (spec == null) throw EditException('Unknown transition "${transition.type}"');
    if (!transitionDirections.contains(transition.direction)) throw EditException('Unknown direction "${transition.direction}"');
    final i = pc.track.clips.indexWhere((c) => c.id == clipId);
    final max = maxTransitionTicks(this, pc.track, i, spec.type);
    if (max < 2 * frameTicks) {
      throw EditException(spec.overlaps
          ? 'Not enough media beyond the cut for a ${spec.label.toLowerCase()}: trim the clips or use a dip'
          : 'The clips are too short for a transition');
    }
    var d = quantize(transition.durationTicks);
    if (d < 2 * frameTicks) d = 2 * frameTicks;
    if (d > max) d = quantizeDown(max);
    return _replaceClips(
        {clipId: pc.clip.copyWith(transitionIn: Transition(type: spec.type, durationTicks: d, direction: transition.direction))});
  }

  // --------------------------------------------------------------- tracks

  (Project, String) addTrack(TrackKind kind, IdGenerator ids) {
    final t = _newTrack(kind, ids);
    return (_insertTrack(t), t.id);
  }

  Project removeTrack(String trackId) {
    final t = trackById(trackId);
    if (t == null) return this;
    _checkUnlocked(t);
    if (t.clips.isNotEmpty) {
      // Linked partners on other tracks stay, unlinked.
      final p = unlink(t.clips.map((c) => c.id));
      return p._withTracks([
        for (final x in p.tracks)
          if (x.id != trackId) x
      ]);
    }
    return _withTracks([
      for (final x in tracks)
        if (x.id != trackId) x
    ]);
  }

  /// Track switches and mix settings. [volume] is clamped to 0–2.
  /// (Mixing — mute, solo, volume — also works on locked tracks: locking
  /// protects the clips, not the monitoring.)
  Project updateTrack(String trackId, {bool? locked, bool? hidden, bool? muted, bool? solo, double? volume, String? name}) => _withTracks([
        for (final t in tracks)
          t.id == trackId
              ? t.copyWith(locked: locked, hidden: hidden, muted: muted, solo: solo, volume: volume?.clamp(0.0, 2.0), name: name)
              : t,
      ]);

  /// Gain of the whole mix, clamped to 0–2.
  Project setMasterVolume(double volume) => copyWith(masterVolume: volume.clamp(0.0, 2.0));

  /// Whether [track] is heard: not muted, and soloed if any track is.
  bool isAudible(Track track) => !track.muted && (track.solo || !tracks.any((t) => t.solo));

  /// Moves a track up/down in the stacking order.
  Project reorderTrack(String trackId, int newIndex) {
    final list = [...tracks];
    final i = list.indexWhere((t) => t.id == trackId);
    if (i < 0) return this;
    final t = list.removeAt(i);
    list.insert(newIndex.clamp(0, list.length), t);
    return _withTracks(list);
  }
}
