# CUTLAB timeline playback and audio engine (Phase 5)

## What works

### Playback of the edited timeline
- **Play, pause, resume, stop** from the timeline monitor or the keyboard. Stop goes back to where playback started.
- **Continuous playback across clips.** Cuts between clips, gaps (black and silence), overlapping clips on stacked tracks (the top-most visible picture wins), hidden tracks, photos and clips from different files all play in one pass.
- **The next clip is prepared ahead** (decoder opened and positioned up to 2 s before the cut), so cuts do not stall.
- **The timeline cursor follows the audio clock** and the timeline scrolls with it. Moving the cursor while playing (ruler, arrow keys, clicking) continues from there. While paused, every cursor move shows the exact frame; dragging uses fast keyframe seeks and the exact frame when you let go.
- Editing while playing is supported. Volume, mute, solo, master and fades are heard within ~0.2 s and do not interrupt the picture. Moving or trimming clips re-shows the picture at the current time.
- Frame-accurate. Each picture shown is the source frame for that timeline time; this is checked with frame-numbered test videos, across cuts, overlaps and the end.

### Audio engine
- **Every audible clip is mixed in real time.** That covers audio tracks and the sound of videos on video tracks, any number of tracks at once, resampled to 48 kHz stereo.
- **Gain.** Clip volume (0–200 % in the clip inspector) × fade × track volume (0–200 %, shown in dB in advanced mode) × master volume (0–200 %). The mix is limited to ±1 (clipped samples are counted).
- **Mute and solo.** A muted track is silent. When any track is soloed, only soloed tracks are heard (mute wins over solo).
- **Fade in and fade out** per clip: linear, sample-accurate, applied in the mix.
- **Mono sources** (a microphone) play at full level on both channels.
- **Level meters:** per track and master, peak with fast attack and ~0.3 s release, green / yellow (−6 dBFS) / red (−1 dBFS). They show what is being heard now, not what was mixed ahead.
- Clips with no sound, unreadable files and unsupported audio are silent. The rest of the mix keeps playing, and the problem is shown in the diagnostics.
- **Waveforms** on the timeline stay aligned with the sound: both use the same timeline time.

### Synchronisation
- **Master clock = audio samples the device has played**, minus the device's output latency. The picture follows this clock: video can never drift from the sound. With no audio device (or the null device) a steady system clock is used.
- **No drift on long recordings.** The mixer produces exactly 48,000 samples per second of timeline, positioned sample-exactly from integer tick times. The audio decoder fills gaps and drops overlaps in the source's own timestamps. 2-hour recordings are tested near their end.
- Variable-frame-rate video is shown by each frame's own timestamp.
- Seeking, pausing and resuming re-position audio and picture together. On pause, what was mixed ahead is dropped so playback resumes exactly where it stopped. The mix is prepared while paused, so play starts with sound at once.
- **Playback diagnostics** (tap the quality line under the monitor):
  - which clock is used, audio latency and audio mixed ahead, audio gaps (underruns);
  - audio clock vs wall clock, how late pictures are vs the sound (average and maximum);
  - pictures shown and dropped, clip changes (and how many were prepared ahead);
  - video decoder (hardware or software), audio decoders open, mixer CPU load, clipped samples, memory, last errors.

### Interface
- Under the monitor: Stop, Play/Pause, timecode, a quality line (decoder, dropped pictures, A/V lateness in advanced mode, audio gaps), and the master meter.
- **Mixer:** right panel on PC (Inspector / Mixer switch), Mixer tab on the phone. It has one strip per video and audio track (volume slider, M, S in advanced mode, meter) and the master strip.
- **Keyboard (PC):**
  - Space: play/pause;
  - Shift+Space: stop;
  - K: pause; L: play;
  - all Phase 4 editing shortcuts still work.
- Slider drags are heard while dragging and become one undo step.
- Beginner mode shows volume in %. Advanced mode adds solo, dB values and the A/V figure.

### Platforms
- **Android:** the AAudio/OpenSL output is opened by miniaudio. Playback pauses when the app goes to the background. Hardware video decoding is used only for kinds of video that passed the separate-process test (0.4.x); otherwise software.
- **Windows:** WASAPI output (low-latency profile). D3D11VA/DXVA2 decoding with software fallback. If no audio device is available, the steady clock is used.

## Performance (measured)

`cutlab_bench_timeline`, null audio device, software decoding, 2-core Linux machine (`/home/claude` dev container):

| Load | CPU | Pictures shown / dropped | Picture late vs sound (avg / max) | Memory |
|---|---|---|---|---|
| Mix 16 audio tracks | 1.6 % of one core (62× real time) | — | — | — |
| 1080p30 H.264 + music track, 720p preview | 18 % | 149 / 0 | 2.2 / 12.9 ms | 147 MB |
| 1080p60 H.264, 720p preview | 35 % | 295 / 0 | 1.6 / 13.7 ms | 197 MB |
| 1080p60 H.264, 1080p preview | 36 % | 281 / 0 | 1.8 / 11.5 ms | 266 MB |
| 1080p60 HEVC, 720p preview | 55 % | 232 / 0 | 2.2 / 13.9 ms | 292 MB |
| 4K HEVC 10-bit, 720p preview | 122 % | 60 / 0 | 2.2 / 13.8 ms | 464 MB |
| A cut every second, 1080p60 H.264 ↔ HEVC | 90 % | 237 / 0 | 2.0 / 11.2 ms | — |
| 120 fps source | 4 % | 475 / 1 | 2.0 / 7.0 ms | 55 MB |

- "Late" is how long after its time a picture reached the screen poll (polling every 4 ms).
- The same benchmark runs in CI on Linux, on Windows and on the Android emulators; see the job logs ("Timeline benchmark").

GitHub Actions Linux runner (4 CPUs), same benchmark: mix 16 tracks 2.2 % of one CPU; 1080p60 H.264 35 % / 0 dropped; 1080p60 HEVC 56 % / 0 dropped; 4K HEVC 10-bit 95 % / 0 dropped; a cut every second 130 % / 0 dropped; 120 fps source 4 % / 2 dropped; 2-hour file 2 % / 0 dropped.

Android emulators (x86_64, 2 CPUs, software rendering of the whole app, no vendor decoders), integration test in the real app:

| Test | API 28 | API 34 |
|---|---|---|
| Renderer: 1080p30 H.264 → 1080p60 HEVC + sound track, 4 s | 4019 ms, 129 shown / 43 dropped, late 9.2 ms, 0 audio gaps, AAudio | 4042 ms, 135 shown / 45 dropped, late 11.2 ms, 0 audio gaps, AAudio |
| Editor: play 4 s timeline from the monitor, cursor reaches the end | 5.4–5.9 s after tapping Play (incl. 1.5 s before the first check) | 10–11 s after tapping Play |
| Editor diagnostics at the end | 28 shown / 64 dropped, 4 audio gaps, latency 30 ms | 104 shown / 62 dropped, 0 audio gaps, latency 90 ms, audio vs wall clock −91 ms |

On the emulators the picture drops many frames because the emulator draws the whole editor in software on 2 CPUs; the sound and the clock keep time (renderer test: 4 s of timeline in 4.0 s). Why the editor test on API 34 needs ~10 s to show the end is not yet explained: the engine clock reports no drift there, so it is most likely the slow test frames of the emulator, but this has not been proven.
- Phones are slower per core; hardware decoding (when it passes its test) takes the video work off the CPU.

## Plan format (app → engine)

The app sends the timeline as text whenever it changes (`buildTimelinePlan`, `cutlab_timeline_set_plan`):

```
cutlab-timeline 1
master <gain 0–2>
hardware <0|1>
track <id> <video|image|audio> <muted 0|1> <solo 0|1> <hidden 0|1> <gain 0–2>
clip <id> <start> <duration> <in-point> <volume> <fade-in> <fade-out> <audio 0|1> <still 0|1> <speed=1> <uri…>
```

- Times are ticks (705,600,000 per second). The uri is the rest of the line (a path, or `fd:N` on Android).
- Tracks are listed bottom to top: later picture tracks cover earlier ones.
- Text tracks are not sent: titles are drawn by the monitor.

## Tests

| Test | What |
|---|---|
| `core/tests/test_timeline.cpp` | 127 checks. Offline mix with exact tones: levels, clip × track × master gain, sample-accurate clip start, in-points, two tracks at once, mute, solo, fades, clipping, broken audio sources. Real-time playback of frame-numbered video: two clips, cut, seek in both clips and exactly at the cut, gaps (black), overlaps, hidden tracks, photos, VFR, rotated phone clip, 60 start/stop/seek cycles with plan changes, mix-only edit without picture interruption, meters, 2-hour file seek and play to the end. Runs on Linux, Windows, Android emulators, and under valgrind in CI. |
| `core/tests/bench_timeline.cpp` | The measurements above. |
| `test/playback_test.dart` | Plan builder (all clip and track settings, missing media, uris with spaces), dB labels, live slider edits as one undo step. |
| `test/widget_test.dart` | Play/pause/stop and L/K/Space keys, cursor follows the renderer clock, exact pause position, mixer mute/solo/master reach the renderer, phone Mixer tab. |
| `integration_test/timeline_playback_test.dart` | With the real engine inside the real app, on the **Android emulators** and on **Windows** (CI). The mix renders and mutes; two clips + a sound track play to the end in real time with cuts; 30 start/stop cycles; and the editor plays from the monitor with the cursor following, then opens the diagnostics. |

## Limitations (not done yet)

| Item | Status |
|---|---|
| Picture compositing | Only the top-most visible picture is shown; there is no blending, picture-in-picture or transparency. Transitions, effects, keyframes and colour work are not rendered yet (they are planned for later phases). |
| Clip speed / reverse | Not supported in playback (the editor has no control for them yet); such clips play at normal speed. |
| Title styling | Titles are plain centred text drawn over the picture. |
| Audio while scrubbing | No sound while dragging the cursor; sound only during playback. |
| Reaction time of mix changes | ~0.2 s (audio mixed ahead) plus the device latency. |
| Fades | Linear only (no curve choice yet). |
| Audio processing | No EQ, compressor, normalisation or ducking (Phase 8). |
| 120 fps on 60 Hz screens | Every other frame is skipped on screen; frame stepping and seeking stay at 120 fps. |
| 4K on phones | Decoded in full and scaled for preview. Without a hardware decoder that passes its test, a phone CPU may drop frames. |
| Device testing | Measured on CI machines and Android emulators; not yet measured on the owner's phone and PC. |
| Editor on slow emulators | On the API 34 emulator the editor test needed ~10 s to show the end of a 4 s timeline (see Performance); not investigated further, to be checked on a real phone. |
