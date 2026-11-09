# The `.cutlab` project format

- **Extension:** `.cutlab` · **Encoding:** UTF-8 JSON · **Current version:** 4 (v1–v3 files open unchanged; see *Version history*)
- **Reference implementation:** `packages/project_format` (Dart), with tests in `packages/project_format/test/`.

## Principles

1. **Media is referenced, never embedded.** A project stays small even for 2-hour recordings.
2. **All times are integers** in ticks: **705,600,000 ticks = 1 second**. Every common frame and sample rate is an exact number of ticks, so a cut at frame N is the same cut on every device. Values stay below 2^53 for ~148 days, so they survive JSON parsers that use doubles.
3. **Versioned with migrations.** Readers upgrade older files step by step (`v1 → v2 → …`). A file from a newer version is rejected with a clear message instead of being silently damaged.
4. **Validated on load.** Errors name the exact JSON path, e.g. `$.project.tracks[0].clips[1].startTicks: overlaps clip "c1" on the same track`.

## Envelope

```json
{
  "format": "cutlab-project",
  "formatVersion": 1,
  "generator": "cutlab",
  "project": { … }
}
```

## `project`

| Field | Type | Notes |
|---|---|---|
| `id` | string | Stable unique id |
| `name` | string | |
| `createdAt`, `modifiedAt` | ISO-8601 UTC string | |
| `editorMode` | `"beginner"` \| `"advanced"` | Presentation only; never changes data |
| `settings` | object | Canvas and audio, below |
| `media` | `MediaRef[]` | Sources used by the project |
| `tracks` | `Track[]` | Order = stacking order for video (first = bottom) |
| `markers` | `Marker[]` | Timeline markers |
| `exportSettings` | object | Last-used export settings |

### `settings`

| Field | Type | Default |
|---|---|---|
| `width`, `height` | int ≥ 16 | 1920 × 1080 |
| `frameRate` | rational `{num, den}` | `{30, 1}` (29.97 is `{30000, 1001}`) |
| `sampleRate` | int | 48000 |
| `audioChannels` | int | 2 |
| `background` | `"#rrggbb"` or `"blur"` | `"#000000"` |

### `MediaRef`

| Field | Type | Notes |
|---|---|---|
| `id` | string | Unique in `media` |
| `kind` | `"video"` \| `"audio"` \| `"image"` | |
| `uri` | string | Absolute path, `content://` URI, or path relative to the `.cutlab` file (used by "collect media") |
| `displayName` | string | |
| `durationTicks` | int | Images use 0 (unbounded) |
| `width`, `height` | int? | |
| `frameRate` | rational? | Nominal/average; VFR sources keep per-frame timestamps in the source |
| `hasAudio` | bool | |
| `fingerprint` | string? | `"<bytes>:<mtime>"` — detects moved or replaced files for relinking |
| `proxyUri` | string? | Optional proxy; export always uses `uri` |

### `Track`

| Field | Type | Notes |
|---|---|---|
| `id` | string | Unique |
| `kind` | `"video"` \| `"audio"` \| `"text"` | |
| `name` | string | |
| `locked`, `hidden`, `muted` | bool | |
| `group` | string? | Tracks with the same group move/lock together |
| `clips` | `Clip[]` | Sorted by `startTicks`; clips on one track **must not overlap** |

### `Clip`

| Field | Type | Notes |
|---|---|---|
| `id` | string | Unique across the project |
| `mediaId` | string? | Must exist in `media`; absent for generated clips (text, solids) |
| `startTicks` | int ≥ 0 | Position on the timeline |
| `durationTicks` | int ≥ 1 | Length on the timeline |
| `sourceInTicks` | int ≥ 0 | Where the clip starts inside the source |
| `speed` | rational > 0 | `{1,4}` = 25 % slow motion. Source span = `durationTicks × speed` |
| `reversed` | bool | Omitted when false |
| `volume` | number | 1.0 = unity gain |
| `fadeInTicks`, `fadeOutTicks` | int ≥ 0 | Audio fades; omitted when 0 |
| `videoFadeInTicks`, `videoFadeOutTicks` | int ≥ 0 | Picture fades from / to black (v4); omitted when 0 |
| `effects` | `Effect[]` | Ordered stack, applied first → last (video and photo clips) |
| `transitionIn` | `{type, durationTicks, direction?}`? | Transition from the clip that ends exactly where this one starts on the same track (v4: `direction` `left`/`right`/`up`/`down`, default `left`). It plays only when that clip is there; the duration is centred on the cut and limited by the clips (see `docs/EFFECTS.md`) |
| `keyframes` | `{ "<param>": Keyframe[] }` | e.g. `"transform.scale"`, `"opacity"`, `"volume"`, `"effects.e1.intensity"` |
| `data` | object | Settings for generated clips (text content, font, style…) |

### `Effect`

`{ "id": string, "type": string, "enabled": bool, "params": object }`. `params` is free-form so files with effects added in later versions remain loadable; unknown effect types are preserved and skipped at render time.

Types rendered since v4 (parameters, ranges and defaults in `docs/EFFECTS.md`): `brightness`, `contrast`, `exposure`, `gamma`, `highlights`, `shadows`, `saturation`, `vibrance`, `temperature`, `tint`, `rgb`, `sharpen`, `blur`, `vignette`, `grayscale`, `black_white`, `sepia`, `filter`. A missing parameter takes its default; values outside the range are clamped. Disabled effects (`"enabled": false`) are kept but not drawn.

Transition types: `dissolve` (older files may say `crossfade`), `dip_black`, `dip_white`, `wipe`, `slide`, `zoom_in`, `zoom_out`, `blur`.

### `Keyframe`

`{ "timeTicks": int (offset from clip start), "value": number, "interpolation": "hold"|"linear"|"easeIn"|"easeOut"|"easeInOut"|"bezier", "bezier": [x1, y1, x2, y2]? }`

### `Marker`

`{ "id", "timeTicks", "label", "color" }`

### `exportSettings`

`{ "container": "mp4"|"mov"|"webm", "videoCodec": "h264"|"hevc"|"av1"|"vp9", "height", "frameRate", "videoBitrateKbps", "audioCodec": "aac"|"opus", "audioBitrateKbps" }`

## Version history

| Version | Change | Migration |
|---|---|---|
| 1 | First layout | — |
| 2 | Image tracks, clip fades, links | none needed |
| 3 | Track volume and solo, master volume | none needed |
| 4 | Working effects and transitions: transition `direction`, clip video fades | none needed (existing effect and transition data is kept as it is) |

## Versioning rules

- **Additive, optional fields** (with a default) do **not** bump the version.
- Renaming/removing a field or changing its meaning **does**: add `Migration` *N → N+1* to `defaultMigrations` in `lib/src/codec.dart`, bump `currentFormatVersion`, add a test that loads a version-N fixture.
- Writers always write the current version. Before overwriting a file from an older version, the app keeps a `.bak` copy (Phase 2).

## Files around a project (Phase 2+)

- `MyProject.cutlab` — the project
- `MyProject.cutlab.autosave` — recovery snapshot, written atomically every few seconds while editing
- `MyProject Media/` — optional folder produced by **Collect media**; `uri`s become relative

Thumbnails, waveforms and proxies live in the per-device cache (SQLite index + cache directory), never next to the project.
