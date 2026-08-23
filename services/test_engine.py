"""Compositing tests for the redaction engine.

Uses stub detection results rather than real inference, so the suite runs without ultralytics or
torch installed and stays fast. What it pins down is the part that decides whether something is
actually hidden: which regions get obscured, how hard, and what is left untouched.
"""
from __future__ import annotations

import os
import types

import numpy as np

os.environ.setdefault("REDACT_SECRET_KEY", "test-secret-key-for-the-suite-only-0123456789ab")

from redactapi.engine import BlurSettings, _obscure, redact_frame  # noqa: E402

PASSED, FAILED = [], []


def check(name: str, condition: bool, detail: str = "") -> None:
    (PASSED if condition else FAILED).append(name)
    print(f"  {'PASS' if condition else 'FAIL'}  {name}{'' if condition else f'  <- {detail}'}")


def variance(image, y0=None, y1=None, x0=None, x1=None) -> float:
    region = image if y0 is None else image[y0:y1, x0:x1]
    return float(np.var(region.astype(float)))


def block_width(image) -> int:
    """Widest run of identical adjacent columns — i.e. the pixelation cell size."""
    best = run = 1
    for i in range(image.shape[1] - 1):
        run = run + 1 if np.array_equal(image[:, i], image[:, i + 1]) else 1
        best = max(best, run)
    return best


class _Boxes:
    def __init__(self, classes, xyxy):
        self._classes = classes
        self._xyxy = np.array(xyxy, dtype=float).reshape(-1, 4)
        self.cls = types.SimpleNamespace(
            int=lambda: types.SimpleNamespace(tolist=lambda: self._classes)
        )
        self.xyxy = types.SimpleNamespace(
            cpu=lambda: types.SimpleNamespace(numpy=lambda: self._xyxy)
        )

    def __len__(self):
        return len(self._classes)


def stub_result(classes, xyxy, masks=None):
    """Stands in for one ultralytics `Results` object."""
    result = types.SimpleNamespace(boxes=_Boxes(classes, xyxy), masks=None)
    if masks is not None:
        result.masks = types.SimpleNamespace(
            data=types.SimpleNamespace(cpu=lambda: types.SimpleNamespace(numpy=lambda: masks))
        )
    return result


def striped_frame():
    """A frame with high-detail texture inside the region the stub box covers."""
    frame = np.full((200, 300, 3), 30, np.uint8)
    stripes = ((np.indices((100, 140))[1] % 2) * 255).astype(np.uint8)
    frame[50:150, 80:220] = stripes[..., None].repeat(3, axis=2)
    return frame


BOX = [[80, 50, 220, 150]]

print("\n[compositing] selected classes are redacted, nothing else is")
frame = striped_frame()
detail = variance(frame, 50, 150, 80, 220)

out, applied = redact_frame(frame.copy(), stub_result([0], BOX), BlurSettings(classes={0}))
check("a selected detection is redacted", applied == 1)
check("detail inside the box is destroyed", variance(out, 50, 150, 80, 220) < detail * 0.5)
check("pixels outside the box are byte-identical",
      np.array_equal(out[160:200, :], frame[160:200, :]))

out, applied = redact_frame(frame.copy(), stub_result([1], BOX), BlurSettings(classes={0}))
check("an unselected class is left alone", applied == 0 and np.array_equal(out, frame))

out, applied = redact_frame(
    frame.copy(), stub_result([0, 1], [[80, 50, 220, 150], [0, 0, 60, 60]]),
    BlurSettings(classes={0, 1}),
)
check("every selected class is redacted", applied == 2)

print("\n[styles] both styles hide detail")
out, _ = redact_frame(frame.copy(), stub_result([0], BOX),
                      BlurSettings(classes={0}, style="gaussian"))
check("gaussian destroys detail", variance(out, 50, 150, 80, 220) < detail * 0.5)

print("\n[mask] mask method follows the silhouette, not the rectangle")
mask = np.zeros((200, 300), np.float32)
mask[60:100, 90:150] = 1.0
out, applied = redact_frame(frame.copy(), stub_result([0], BOX, masks=mask[None]),
                            BlurSettings(classes={0}, method="mask"))
check("mask method is applied", applied == 1)
check("inside the silhouette is obscured",
      not np.array_equal(out[65:95, 95:145], frame[65:95, 95:145]))
check("inside the box but outside the silhouette is preserved",
      np.array_equal(out[110:145, 160:215], frame[110:145, 160:215]))

print("\n[bounds] out-of-frame boxes are clamped, never fatal")
check("a box running off the top-left is clamped",
      redact_frame(frame.copy(), stub_result([0], [[-50, -50, 40, 40]]),
                   BlurSettings(classes={0}))[1] == 1)
check("a box entirely off-frame is skipped",
      redact_frame(frame.copy(), stub_result([0], [[500, 500, 600, 600]]),
                   BlurSettings(classes={0}))[1] == 0)
out, applied = redact_frame(frame.copy(), stub_result([], []), BlurSettings(classes={0}))
check("no detections is a no-op", applied == 0 and np.array_equal(out, frame))

print("\n[strength] strength maps onto the app's CIPixellate / CIGaussianBlur behaviour")
# Random noise, not a repeating pattern: a periodic input aliases against the pixelation grid
# and makes variance a misleading measure of how much was hidden.
noise = np.random.default_rng(7).integers(0, 256, (240, 240, 3), dtype=np.uint8)
previous = variance(noise) + 1
for strength in (4, 10, 25, 40, 60):
    out = _obscure(noise.copy(), BlurSettings(classes={0}, style="pixelate", strength=strength))
    width, current = block_width(out), variance(out)
    check(f"pixelate strength {strength} gives ~{strength}px cells",
          abs(width - strength) <= max(2, strength * 0.25), f"{width}px")
    check(f"pixelate strength {strength} hides more than the step below", current < previous)
    previous = current

previous = variance(noise) + 1
for strength in (4, 10, 25, 40, 60):
    current = variance(_obscure(noise.copy(),
                                BlurSettings(classes={0}, style="gaussian", strength=strength)))
    check(f"gaussian strength {strength} hides more than the step below", current < previous)
    previous = current

print("\n[settings] validation matches the app's ranges")
check("strength clamps to 60 at the top", BlurSettings(strength=999).strength == 60.0)
check("strength clamps to 4 at the bottom", BlurSettings(strength=0).strength == 4.0)
check("default strength matches the app", BlurSettings().strength == 25.0)
for bad, field in [({"style": "swirl"}, "style"), ({"method": "blob"}, "method"),
                   ({"classes": set()}, "classes")]:
    try:
        BlurSettings(**bad)
        check(f"an invalid {field} is refused", False, "no error raised")
    except ValueError:
        check(f"an invalid {field} is refused", True)
check("_obscure preserves the region's shape",
      _obscure(frame[50:150, 80:220], BlurSettings()).shape == (100, 140, 3))

print(f"\n{'=' * 58}\n{len(PASSED)} passed, {len(FAILED)} failed")
if FAILED:
    for name in FAILED:
        print(f"  FAILED: {name}")
    raise SystemExit(1)
