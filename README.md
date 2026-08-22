# apps

A native macOS workspace for focused tools, behind one launcher: a splash screen, then a
persistent sidebar to move between them. Everything runs on this device, and nothing you open is
sent anywhere.

**Redact**, which hides faces and objects in a webcam feed or a saved file, is the first tool.
Adding another is a new top-level folder plus a target in `Package.swift` and a case in
`AppCatalog.swift`; nothing else changes. Apps stay resident, so switching between them never
interrupts work that is already running.

## Version and updates

The app's version is `CFBundleShortVersionString` in `Info.plist`. It's linked into the binary and
copied into the bundle by `Scripts/build-app.sh`, and it's the only place the number is written.

The version sits in the top-left corner of the title bar and is also the update control.
Clicking it checks the GitHub Releases API for `RizwanMunawar/apps` and, if a release tag compares
higher than what is installed, immediately starts fetching it: no dialog to dismiss, with the
badge itself reporting progress. Hovering it shows what the latest release contained, pulled from
the same API. The app also checks quietly on launch, throttled to once a day.

Downloading puts the `.dmg` in Downloads and opens it; the drag-to-Applications step stays manual,
because silently swapping a running app needs a helper tool and a notarised update feed that an
ad-hoc signed build has no way to verify.

Publishing a new version means bumping `CFBundleShortVersionString`, building the installer, and
attaching `apps-releases.dmg` to a GitHub release whose tag is that version.

## Install

Download `apps-releases.dmg` from the [latest release](../../releases/latest), open it, and drag
**apps-releases** into **Applications**.

The app is ad-hoc signed (not notarized), so on first launch Gatekeeper will block it. Right-click
`apps-releases.app` → **Open** → **Open** to approve it once.

## Apps

### Redact

Blurs whichever object classes you choose, entirely on-device: no network calls, no API keys, no
per-frame cost. [rizwanai.com/apps/redact](https://rizwanai.com/apps/redact)

Two modes, sharing one pipeline and one set of blur settings:

- **Live camera** uses `AVCaptureSession` to stream webcam frames in real time.
- **Process file** takes an image or video and works in four steps: drop the file in, look at it
  untouched, apply the blur (the processed frames appear as they are encoded), then export. Video
  exports carry a small black corner mark on every frame, and end on an animated card with the
  shell's logo and name, capped at four seconds.

Either way, each frame goes through:

- **Detect** — letterboxed to 640x640 and run through a bundled **YOLO26n-seg** CoreML model,
  decoding its native end-to-end
  `[x1, y1, x2, y2, confidence, class, ...32 mask coefficients]` output plus its `[32, 160, 160]`
  prototype-mask output.
- **Track** follows each object from frame to frame using **FastTracker**, the occlusion-aware
  tracker Ultralytics ships as `fasttrack.yaml` (arXiv:2508.14370). Ultralytics' trackers are
  Python and run beside a PyTorch model, so they can't be loaded into a CoreML app; this is the
  same algorithm written natively against our detections, with every threshold taken from
  `fasttrack.yaml` (`redact/Services/FastTracker.swift`).

  It matters because a per-frame detector is not stable: drop one frame and an unblurred flash of
  a face gets through. FastTracker is ByteTrack (two-stage matching, so a weak detection can still
  hold a track) plus occlusion handling: a track that gets covered by a neighbour has its motion
  rolled back to before the occlusion, its box widened once and its drift dampened, and it is kept
  alive through the pass-behind instead of being given up on. Switch it off under "Steadiness".

  One deliberate difference from upstream: Ultralytics emits only tracks matched on the current
  frame, because for analytics a coasted box is a false positive. Here it is the whole point, so
  predicted boxes for still-alive tracks are emitted too.
- **Blur** — detections matching your selected classes get a CoreImage pixelate/Gaussian patch
  composited over them, either **Box** (fills the bounding box) or **Mask** (clipped to the
  object's own outline via `CIBlendWithMask`). Mask is only offered when the loaded model actually
  has a mask branch; a plain detection model shows Box alone rather than a control that would
  quietly do nothing.
- **Mark** outlines what was covered in the accent colour. Box mode draws the full rectangle;
  segmentation traces the silhouette itself and draws no rectangle at all.
- **Display or encode** sends the composited frame back to the SwiftUI preview, or to an
  `AVAssetWriter` for file exports.

The bundled model is YOLO26n-seg, but you can load your own from the "i" next to Redact's name.
CoreML models load straight away; `.pt` and `.onnx` files are converted first via Ultralytics,
which has to be installed on this device (`pip install ultralytics coremltools`). Class names come
from the model's own metadata, so a custom model shows its own labels, and Mask is only offered
when the model actually has a mask branch.

What gets remembered between launches is the *compiled* model, not the file you picked. Storing the
original means re-running the whole conversion every launch, and quietly reverting to the built-in
model if that file has since moved or Python is no longer where it was.

`swift run redact-selfcheck` covers this path against a real model when you point it at one:

```sh
REDACT_MODEL=/path/to/yolo11n.pt swift run redact-selfcheck
```

Everything runs locally on the Neural Engine/GPU via CoreML.

## Build from source

Camera access requires a real, LaunchServices-registered `.app` bundle — a bare `swift run`
process is often silently denied. Build and launch the packaged app instead:

```sh
Scripts/build-app.sh      # debug build -> apps-releases.app
open apps-releases.app
```

To build the distributable installer:

```sh
Scripts/build-dmg.sh      # release build -> apps-releases.app -> apps-releases.dmg
```

Note that `redact/Services/RedactResources.swift` finds the bundled model rather than SwiftPM's
generated `Bundle.module`. `Bundle.module` looks next to `Bundle.main.bundleURL`, which for an
`.app` is the `.app` itself rather than `Contents/Resources` where a signable bundle has to live,
and then falls back to an absolute path into the build directory baked in at compile time. That
fallback exists on the machine that built the app and nowhere else, so `Bundle.module` would
`fatalError` on launch for everybody else.

Re-run after any code change to refresh the bundle. Redact's first launch compiles its bundled
`.mlpackage` into a cached `.mlmodelc` under
`~/Library/Application Support/apps-releases/Redact/`; subsequent launches reuse it.

## Checks

```sh
swift run redact-selfcheck
```

Exercises Redact's offline media pipeline end to end (outro placement, audio passthrough,
orientation, overwrite and failure handling, image processing, watermark geometry) against video
and image fixtures it synthesises on the fly, plus the tracker's behaviour: that it follows a
moving object, rides out a dropped frame, eventually lets a vanished one go, ignores a one-frame
blip, never swaps identities between classes, and survives an occlusion (with a control case
proving that is the occlusion path and not just a long buffer). It's a plain executable rather than a
`swift test` target on purpose: XCTest and swift-testing both ship with Xcode, not the Command
Line Tools, so a test target won't even compile on a CLT-only machine.

## Architecture

Three targets, and the dependency arrow only ever points one way — `AppShell` → `Redact` →
`AppCore` — so an app can't reach back into the launcher:

```
Shared/                 target AppCore — everything both sides share
  Palette.swift           light/dark design tokens + ThemeManager
  Controls.swift          reusable controls: cards, chips, buttons, search, disclosure sections
  Fonts.swift             the bundled Archivo typeface
  AppActivity.swift       apps publish "I'm running"; the sidebar reads it

redact/                 target Redact — the app, self-contained
  Models/ Services/ ViewModels/ Views/
  Resources/              the bundled YOLO26n-seg .mlpackage
  Views/RedactMark.swift  the one thing the shell imports, for the sidebar icon
  Services/ModelImporter  brings in your own .pt/.onnx/.mlpackage model

AppShell/               target AppShell — the launcher (the executable)
  ShellApp.swift          @main entry point
  ShellRootView.swift     splash -> title bar + app (or the App Hub)
  AppHubView.swift        the home grid of every app
  ShellTitleBar.swift     full-width top chrome
  AppCatalog.swift        AppID enum: the single place a new app gets registered
  ShellMark.swift         the shell's own logo, distinct from any app's icon

Tools/RedactSelfCheck/  target redact-selfcheck — the pipeline checks above
Scripts/                build-app.sh (debug/release .app) + build-dmg.sh (release .dmg)
AppIcon/
  Shell/                  apps-releases' own .icns (Dock/Finder icon) — a generic app-grid glyph
  Redact/                 Redact's icon source; the in-app mark is drawn natively, no bitmap
```

The window is a title bar over the selected app, and nothing else. There is no permanent app list
down the side: it was a column of chrome duplicating what the App Hub already shows, and every
point it took was a point the app inside it did not get. The mark in the title bar, and the grid
button beside it, go back to the hub.

Redact puts its own controls in a panel down the right. The steps are a sequence, and a column
reads as one more naturally than a row; each is a titled block whose numbered disc turns green
once that step is satisfied, so the panel answers "where am I up to" without being read.

The window opens at its own minimum size and can only be grown from there
(`AppShell/WindowSizing.swift`). SwiftUI's `.frame(minWidth:minHeight:)` alone did not hold it:
depending on saved state the window either collapsed to a fraction of the layout or restored far
larger, so `NSWindow.minSize` is pinned directly, which is what the window server enforces when
someone drags a corner. The stage is laid out inside a `GeometryReader` for the same reason: left
to intrinsic sizing, a 16:9 view asks for the height matching its full width and drags the whole
window up with it, past what a 13-inch display can show.

An app's state lives outside its views (`redact/RedactAppState.swift`), because SwiftUI destroys
a screen's `@StateObject`s the moment you navigate away. Switching apps, or going back to the App
Hub, therefore leaves a running camera or a half-finished export exactly where it was. What the
off-screen app stops doing is building preview images, which is where nearly all of the per-frame
memory went; one shared `CIContext` (`redact/Services/RenderContext.swift`) serves the detector,
the live pipeline and the encoder, preview frames are downscaled before they cross to the main
thread, and a picked still is held only as a thumbnail while the file on disk stays the source
for processing.

## Regenerating Redact's model

```sh
pip install ultralytics coremltools
yolo export model=yolo26n-seg.pt format=coreml imgsz=640
```

Swap in `yolo26s-seg`/`yolo26m-seg` for higher accuracy at the cost of frame rate, or a
custom-trained YOLO26 segmentation checkpoint for classes beyond COCO's 80.
