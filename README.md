# apps

A native macOS shell that hosts a family of small, free, single-purpose apps behind one launcher
— splash screen, then a persistent left rail to switch between them. **Redact** (blur objects
live on your webcam) is the first one; adding another is a new `Sources/AppShell/Apps/<Name>`
folder plus a case in `AppCatalog.swift`, nothing else changes.

## Install

Download `apps-releases.dmg` from the [latest release](../../releases/latest), open it, and drag
**apps-releases** into **Applications**.

The app is ad-hoc signed (not notarized), so on first launch Gatekeeper will block it. Right-click
`apps-releases.app` → **Open** → **Open** to approve it once.

## Apps

### Redact

Blurs chosen object classes live on your webcam feed, entirely on-device — no network calls, no
API keys, no per-frame cost. [rizwanai.com/apps/redact](https://rizwanai.com/apps/redact)

- **Capture** — `AVCaptureSession` streams webcam frames in real time.
- **Detect** — each frame is letterboxed to 640x640 and run through a bundled **YOLO26n-seg**
  CoreML model, decoding its native end-to-end
  `[x1, y1, x2, y2, confidence, class, ...32 mask coefficients]` output plus its `[32, 160, 160]`
  prototype-mask output.
- **Blur** — detections matching your selected classes get a CoreImage pixelate/Gaussian patch
  composited over them, either **Box** (fast, fills the bounding box) or **Segmentation**
  (precise, clipped to the object's per-pixel mask via `CIBlendWithMask`).
- **Display** — the composited frame is rendered back to the SwiftUI preview.

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

Re-run after any code change to refresh the bundle. Redact's first launch compiles its bundled
`.mlpackage` into a cached `.mlmodelc` under
`~/Library/Application Support/apps-releases/Redact/`; subsequent launches reuse it.

## Architecture

```
Sources/AppShell/
  ShellApp.swift        @main entry point
  Shell/                 The launcher itself — splash, app rail, navigation, catalog
    AppCatalog.swift      AppID enum: the single place a new app gets registered
    ShellRootView.swift    Splash -> persistent-rail-plus-content navigation
    AppRail.swift          The slim left nav strip of app icons
    ShellMark.swift        The shell's own logo (distinct from any app's own icon)
    SplashView.swift
  Apps/
    Redact/                Everything Redact-specific, own Models/Services/ViewModels/Views
Scripts/                 build-app.sh (debug/release .app) + build-dmg.sh (release .dmg)
AppIcon/
  Shell/                  apps-releases' own .icns (Dock/Finder icon) — a generic app-grid glyph
  Redact/                 Redact's own icon source, used for its rail tile (drawn natively, no
                          bitmap needed at runtime — see RedactMark in DesignSystem.swift)
```

## Regenerating Redact's model

```sh
pip install ultralytics coremltools
yolo export model=yolo26n-seg.pt format=coreml imgsz=640
```

Swap in `yolo26s-seg`/`yolo26m-seg` for higher accuracy at the cost of frame rate, or a
custom-trained YOLO26 segmentation checkpoint for classes beyond COCO's 80.
