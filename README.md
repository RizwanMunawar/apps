# Redact

A native macOS SwiftUI app that blurs chosen object classes live on your webcam feed, entirely on-device — no network calls, no API keys, no per-frame cost.

## Install

Download `Redact.dmg` from the [latest release](../../releases/latest), open it, and drag **Redact** into **Applications**.

The app is ad-hoc signed (not notarized), so on first launch Gatekeeper will block it. Right-click `Redact.app` → **Open** → **Open** to approve it once.

## How it works

- **Capture** — `AVCaptureSession` streams webcam frames in real time.
- **Detect** — each frame is letterboxed to 640x640 and run through a bundled **YOLO26n-seg** CoreML model (`Sources/Redact/Resources/yolo26n-seg.mlpackage`), decoding its native end-to-end `[x1, y1, x2, y2, confidence, class, ...32 mask coefficients]` output plus its `[32, 160, 160]` prototype-mask output.
- **Blur** — detections matching your selected classes get a CoreImage pixelate/Gaussian patch composited over them. Two methods:
  - **Box** — fills the full bounding box (fast).
  - **Segmentation** — additionally clipped to the object's per-pixel mask via `CIBlendWithMask`, so only its actual silhouette blurs, not the background inside its box (slower, precise).
- **Display** — the composited frame is rendered back to the SwiftUI preview.

Everything runs locally on the Neural Engine/GPU via CoreML.

## Build from source

Camera access requires a real, LaunchServices-registered `.app` bundle — a bare `swift run` process is often silently denied. Build and launch the packaged app instead:

```sh
Scripts/build-app.sh      # debug build -> Redact.app
open Redact.app
```

To build the distributable installer:

```sh
Scripts/build-dmg.sh      # release build -> Redact.app -> Redact.dmg
```

Re-run after any code change to refresh the bundle. The first launch compiles the bundled `.mlpackage` into a cached `.mlmodelc` under `~/Library/Application Support/Redact/`; subsequent launches reuse it.

Grant camera access when macOS prompts for it. From the sidebar you can select which of the 80 COCO classes get blurred (or Select all / Clear), the blur style (pixelate / Gaussian), the blur method (box / segmentation), the blur strength, and light/dark theme.

## Architecture

```
Models/       Detection + DetectableClass (the 80 COCO classes) + BlurStyle + BlurMethod
Services/     CameraCaptureService, YOLODetector, FrameProcessor, BlurCompositor, PipelineSettings
ViewModels/   BlurSessionViewModel — owns the live pipeline, publishes preview + fps to SwiftUI
Views/        RootView, ClassPickerView, CameraPreviewView, DesignSystem, Theme
Resources/    yolo26n-seg.mlpackage (Ultralytics YOLO26 nano segmentation, COCO-pretrained)
AppIcon/      AppIcon.icns + source PNG for the app icon
Scripts/      build-app.sh (debug/release .app) + build-dmg.sh (release .dmg installer)
```

## Regenerating the model

The bundled model was exported with:

```sh
pip install ultralytics coremltools
yolo export model=yolo26n-seg.pt format=coreml imgsz=640
```

Swap in `yolo26s-seg`/`yolo26m-seg` for higher accuracy at the cost of frame rate, or a custom-trained YOLO26 segmentation checkpoint for classes beyond COCO's 80.
