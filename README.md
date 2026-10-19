# ScreenFrame

A native macOS screen recorder in the spirit of Screen Studio: record raw, polish later.
Design notes from the Screen Studio teardown: `~/screenstudio-re/BLUEPRINT.md`.

```
./build.sh          # build .build/ScreenFrame.app
./build.sh --run    # build, install to /Applications, launch
```

First launch: allow ScreenFrame under System Settings › Privacy & Security › Screen & System Audio
Recording, then press **Relaunch**. Builds are signed with the local "Flow App Signing" identity, so
the grant survives rebuilds.

## How it works

| Stage | Where | What |
|---|---|---|
| Capture | `Capture/Recorder.swift` | ScreenCaptureKit (display, single window, or dragged area via `AreaSelector`), system cursor hidden, HEVC `.mov`; system audio + mic to separate `.m4a` with offsets |
| Input | `Capture/InputSampler.swift` | 120 Hz mouse/button polling on the host clock (no Accessibility permission), cursor images deduped to `cursors/*.png` |
| Model | `Model/` | project folder = `recording.json` (immutable raw data) + `project.json` (clips, texts, settings) + media; added clips are copied into `clips/` (recordings) and `media/` (video files) |
| Clips | `Render/Composer.swift` | clips play back to back on two alternating video tracks, one RenderModel per clip; zooms live on the clip in source time |
| Text | `Render/TextRenderer.swift` | CoreText sprites (pill / shadow / plain), drawn in output space after the camera, 0.25 s fade-and-rise |
| Audio | `Render/Composer.swift`, `Render/Waveform.swift` | A/B composition tracks per lane (voice, system, clip audio); `AVAudioMix` applies lane volume × clip volume, fades across transitions; waveform peaks for the timeline |
| Timeline | `Model/TimelineLayout.swift` | shared by editor and composer: clip speed stretches a clip (pitch kept, `.spectral`), a transition overlaps it with the next |
| Transitions | `Render/Composer.swift` | crossfade, fade through black, slide; two-layer instructions over the overlap |
| Webcam | `Capture/WebcamRecorder.swift`, `Render/RenderModel.swift` | AVCaptureSession → H.264 `webcam.mov` on the host clock; the draggable preview bubble's position is logged (`webcamPath`) and replayed spring-smoothed; in the editor drag the bubble anywhere or pick a corner; circle / square / 16:9, size, mirror; per clip overlay / fullscreen / hidden |
| Camera lane | `Model/EditSettings.swift` (`CameraKey`), `Render/RenderModel.swift` | timeline keyframes: from each one the bubble glides (0.5 s) to a position and/or switches overlay / fullscreen / hidden (0.35 s fade); dragging the bubble on the preview sets the keyframe at the playhead |
| Smart camera | `Analysis/FaceTracker.swift`, `Analysis/SmartCamera.swift` | Vision face track (cached `webcam.mov.faces.json`) keeps the face centred; person segmentation blurs or removes the background; "Auto layout" goes fullscreen while talking without screen activity |
| Clean up | `Analysis/Cleanup.swift`, `Model/EditOps.swift` | pauses from the voice level (keeps silent demos with clicks/typing/mouse), filler words from the transcript; cuts preview red on the timeline; `EditOps` cuts/splits/retimes and moves titles, captions and camera keys with the content |
| Privacy | `Analysis/PrivacyScanner.swift` | Vision OCR at 1 fps (unchanged frames skipped): emails, phone numbers, keys/tokens, full names (two capitalised words, UI words excluded), faces → `BlurRegion`s, rendered as average-pixelate-blur |
| Edit by prompt | `Analysis/AIClient.swift`, `Analysis/AIEditor.swift` | Claude via the newest local Claude Code binary (`-p --output-format json --tools ""`, so the user's own auth/Bedrock); project + transcript as JSON in, a whitelisted operation list out, applied as one undo step |
| Social | `Editor/EditorModel+AI.swift` | 9:16/1:1 "fill frame & follow cursor"; "Make Short" lets Claude pick 30–60 s from the transcript and builds a vertical copy with a hook title |
| Script editing | `Editor/PublishViews.swift` (`TranscriptPanel`) | on-device transcript as clickable words; shift-click selects, ⌫ cuts the words from the video (`EditOps.remove`) |
| Take again | `Analysis/Retakes.swift` | ⌘⇧1 or ↺ in the stop pill marks a retake; on stop the 15 s before each mark are transcribed and the last sentence (punctuation, else the biggest word gap / voice pause) is cut |
| Brand kit | `Model/BrandKit.swift`, `Render/CardRenderer.swift` | app-wide kits (Application Support/ScreenFrame): gradient, font, colours, logo watermark, lower third, intro/outro cards rendered to MP4 and added as full-bleed clips; default "snipKI" from the snipki-design skill |
| Content package | `Analysis/ContentPackager.swift` | Claude writes titles, chapters, YouTube description, LinkedIn post and newsletter snippet (LinkedIn/newsletter in the jens-voice style) → `content/` with content.md, chapters.txt, captions.srt |
| Thumbnails | `Analysis/ThumbnailMaker.swift` | frame candidates scored by face + detail, headline by Claude, face cut-out (person segmentation around the largest face), brand logo → YouTube / LinkedIn / square PNGs in `thumbnails/` |
| Step guide | `Analysis/GuideMaker.swift` | one step per click: screenshot with marker, clicked label via OCR, text by Claude → `guide/` index.html, guide.md, guide.pdf |
| Video projects | `Model/ProjectStore.swift` (`createProject(fromVideos:)`) | "Open Video…", drop on the home window, or open a video with ScreenFrame: first file becomes the project's recording (its audio as the voice lane), the rest clips |
| Activity strip | `Editor/EditorModel.swift` (`begin/report/end`), `ActivityStrip` | every long task registers by id: shown with progress and elapsed time on the preview, a second start is refused with a notice, transcription is shared between features |
| Subtitles | `Editor/SubtitleEditor.swift`, `Model/Glossary.swift` | own window: every line editable and playable, find & replace across all, one style for all; glossary (app-wide) gives the recognizer vocabulary hints and fixes every transcript (phrase-level, after splitting multi-word segments); "Fix with Claude" proofreads names/spelling/punctuation without rewording, marks changes, and can teach the glossary what it corrected |
| Stop control | `Home/RecordingControls.swift` | floating pill with timer + Stop while recording (not captured); clicks on own controls aren't recorded, the move to Stop is trimmed off the clip |
| Captions | `Render/Captioner.swift` | audio read as 16 kHz mono from any file, split at quiet points (<55 s), each chunk level-normalized (+30 dB max), Apple Speech on-device → words → subtitle lines |
| Typing | `Capture/InputSampler.swift` | opt-in key-press *times* (no keys, needs Accessibility) → "Speed up typing" splits those stretches to a faster clip speed |
| Undo | `Editor/EditorModel.swift` | snapshot stack of settings/clips/texts; changes within 0.6 s coalesce (drags, sliders) |
| Effects | `Render/RenderModel.swift` | background + shadow + rounded mask (pre-rendered), spring-smoothed cursor, click squish + ripple, spring camera that follows the cursor during zoom segments |
| Auto zoom | `Render/AutoZoom.swift` | clicks grouped by time (≤3 s) and distance (≤35 % of diagonal), zoom starts 0.9 s before |
| Playback/export | `Render/Composer.swift` | one custom `AVVideoCompositing` drives AVPlayer preview, AVAssetExportSession (H.264 MP4) and stills |
| Import | `Import/ScreenStudioImporter.swift` | converts `.screenstudio` projects (video, audio, mouse logs, cursor PNGs) |

Shortcuts: **⌘⇧2** start/stop recording anywhere (menu-bar icon also stops), **⌘⇧1** take again (cuts the sentence you just said). In the editor: **Space**
play/pause, **Z** all zooms on/off, **T** add text, **B** / **⌘B** split at playhead, **⌘D** duplicate,
**⌫** delete the selection, **⌘Z / ⇧⌘Z** undo/redo, **← →** step a frame (with ⇧: a second), **⌘E** export.
Right-click anything on the timeline for speed, volume, camera layout, transitions, duplicate, delete. `open -a ScreenFrame <project>` opens a
project folder.

Each zoom either follows the cursor or holds a fixed focus point (`focusX`/`focusY`, normalized,
top-left origin) chosen by dragging the zoom frame over a still in the inspector.

## CLI

```
ScreenFrame --import <x.screenstudio>
ScreenFrame --record <seconds> [window=<id>|area=x,y,w,h] [system-audio]
ScreenFrame --add-clip <project> <video file or recording folder>
ScreenFrame --list-windows
ScreenFrame --transcribe <audio or video file> [de-DE|en-US|…]
ScreenFrame --faces <camera video>
ScreenFrame --privacy <project>
ScreenFrame --pauses <project> [apply]
ScreenFrame --ai <project> "<request>"
ScreenFrame --short <project>
ScreenFrame --still  <project> <seconds> <out.png> [key=value ...]
ScreenFrame --export <project> <out.mp4> [key=value ...]   # e.g. aspect=square background=sunset
```

## Not yet

Camera layouts that change mid-clip (split the clip instead), caption styling for all captions at once,
GIF export (not wanted).
