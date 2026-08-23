"""The redaction pipeline, ported from the macOS app so the API and the app agree.

Mirrors `BlurCompositor` and `MediaProcessor`: the same model (yolo26n-seg), the same 0.4
confidence floor, the same two styles (pixelate / gaussian) crossed with the same two methods
(box / mask), and the same 4–60 strength range. A caller who gets one result in the desktop app
should get the same result here for the same settings.
"""
from __future__ import annotations

import threading
from dataclasses import dataclass, field
from pathlib import Path

import cv2
import numpy as np

from . import config

STRENGTH_MIN, STRENGTH_MAX = 4.0, 60.0
STRENGTH_DEFAULT = 25.0

STYLES = ("pixelate", "gaussian")
METHODS = ("box", "mask")

_model = None
_model_lock = threading.Lock()


def load_model():
    """Load the weights once, on first use, and share them across requests.

    Import is deferred so the portal boots (and the test suite runs) on a machine without
    ultralytics installed — only an actual redaction call needs it.
    """
    global _model
    if _model is None:
        with _model_lock:
            if _model is None:
                from ultralytics import YOLO

                _model = YOLO(config.MODEL_NAME)
    return _model


def class_names() -> dict[int, str]:
    return dict(load_model().names)


@dataclass
class BlurSettings:
    """The API-side twin of `MediaBlurSettings` in the Swift app."""

    classes: set[int] = field(default_factory=lambda: {0})  # 0 = person, the app's default
    style: str = "pixelate"
    method: str = "box"
    strength: float = STRENGTH_DEFAULT
    tracking: bool = True

    def __post_init__(self) -> None:
        if self.style not in STYLES:
            raise ValueError(f"style must be one of {STYLES}, got {self.style!r}")
        if self.method not in METHODS:
            raise ValueError(f"method must be one of {METHODS}, got {self.method!r}")
        self.strength = float(np.clip(self.strength, STRENGTH_MIN, STRENGTH_MAX))
        if not self.classes:
            raise ValueError("Select at least one class to redact.")


def _obscure(patch: np.ndarray, settings: BlurSettings) -> np.ndarray:
    """Pixelate or blur one region. Matches CIPixellate / CIGaussianBlur closely enough that the
    two products look the same at a given strength."""
    height, width = patch.shape[:2]
    if height == 0 or width == 0:
        return patch

    if settings.style == "pixelate":
        # CIPixellate's `scale` is the side of one output cell, so downsample to that grid and
        # blow it back up with nearest-neighbour to get hard square blocks.
        cell = max(4.0, settings.strength)
        small_w = max(1, int(width / cell))
        small_h = max(1, int(height / cell))
        small = cv2.resize(patch, (small_w, small_h), interpolation=cv2.INTER_AREA)
        return cv2.resize(small, (width, height), interpolation=cv2.INTER_NEAREST)

    # CIGaussianBlur takes a radius; OpenCV wants an odd kernel and a sigma.
    radius = max(1.0, settings.strength)
    kernel = int(radius) * 2 + 1
    return cv2.GaussianBlur(patch, (kernel, kernel), radius / 2.0)


def redact_frame(frame: np.ndarray, result, settings: BlurSettings) -> tuple[np.ndarray, int]:
    """Composite obscured regions over one frame. Returns the frame and how many hits landed."""
    boxes = getattr(result, "boxes", None)
    if boxes is None or len(boxes) == 0:
        return frame, 0

    height, width = frame.shape[:2]
    class_ids = boxes.cls.int().tolist()
    xyxy = boxes.xyxy.cpu().numpy()

    masks = None
    if settings.method == "mask" and getattr(result, "masks", None) is not None:
        masks = result.masks.data.cpu().numpy()

    applied = 0
    for index, class_id in enumerate(class_ids):
        if class_id not in settings.classes:
            continue

        x1, y1, x2, y2 = (int(round(v)) for v in xyxy[index])
        x1, y1 = max(0, x1), max(0, y1)
        x2, y2 = min(width, x2), min(height, y2)
        if x2 <= x1 or y2 <= y1:
            continue

        region = frame[y1:y2, x1:x2]
        obscured = _obscure(region, settings)

        if masks is not None and index < len(masks):
            # Mask method: only the object's own silhouette, not its bounding rectangle.
            mask = cv2.resize(masks[index], (width, height), interpolation=cv2.INTER_LINEAR)
            mask = mask[y1:y2, x1:x2]
            alpha = np.clip(mask, 0.0, 1.0)[..., None]
            frame[y1:y2, x1:x2] = (obscured * alpha + region * (1 - alpha)).astype(frame.dtype)
        else:
            frame[y1:y2, x1:x2] = obscured

        applied += 1

    return frame, applied


def redact_image(data: bytes, settings: BlurSettings) -> tuple[bytes, int]:
    """Redact one still image. Returns `(png_bytes, detections_applied)`."""
    buffer = np.frombuffer(data, dtype=np.uint8)
    frame = cv2.imdecode(buffer, cv2.IMREAD_COLOR)
    if frame is None:
        raise ValueError("Couldn't read that image file.")

    model = load_model()
    result = model.predict(
        frame, conf=config.CONFIDENCE, verbose=False,
        retina_masks=settings.method == "mask",
    )[0]
    frame, applied = redact_frame(frame, result, settings)

    ok, encoded = cv2.imencode(".png", frame)
    if not ok:
        raise ValueError("Couldn't encode the redacted image.")
    return encoded.tobytes(), applied


def redact_video(source: Path, destination: Path, settings: BlurSettings) -> tuple[int, int]:
    """Redact every frame of a video. Returns `(frames_written, total_detections)`.

    Note: this writes video only. The Swift app muxes the original audio back in; doing that here
    needs ffmpeg, so the API documents its output as silent rather than pretending otherwise.
    """
    capture = cv2.VideoCapture(str(source))
    if not capture.isOpened():
        raise ValueError("That file has no readable video track.")

    fps = capture.get(cv2.CAP_PROP_FPS) or 30.0
    width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))

    writer = cv2.VideoWriter(str(destination), cv2.VideoWriter_fourcc(*"mp4v"), fps, (width, height))
    if not writer.isOpened():
        capture.release()
        raise ValueError("Couldn't open an encoder for the output video.")

    model = load_model()
    frames = total = 0
    try:
        while True:
            ok, frame = capture.read()
            if not ok:
                break

            if settings.tracking:
                # `persist=True` carries track IDs across frames, the same job FastTracker does
                # in the app: the patch stays put through a missed detection.
                result = model.track(
                    frame, conf=config.CONFIDENCE, persist=True, verbose=False,
                    retina_masks=settings.method == "mask",
                )[0]
            else:
                result = model.predict(
                    frame, conf=config.CONFIDENCE, verbose=False,
                    retina_masks=settings.method == "mask",
                )[0]

            frame, applied = redact_frame(frame, result, settings)
            total += applied
            writer.write(frame)
            frames += 1
    finally:
        capture.release()
        writer.release()

    return frames, total
