"""The public, key-authenticated API. Everything here requires `Authorization: Bearer rdk_...`."""
from __future__ import annotations

import tempfile
import time
from pathlib import Path

from fastapi import APIRouter, Depends, Form, HTTPException, Response, UploadFile, status
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session

from .. import config, engine
from ..auth import month_usage, record_usage, require_api_key
from ..db import get_session
from ..models import ApiKey, as_utc

router = APIRouter(prefix="/v1", tags=["redact"])


def _parse_classes(raw: str) -> set[int]:
    """`"0,2,7"` -> `{0, 2, 7}`. Class indices, matching the model's own output order."""
    try:
        parsed = {int(part) for part in raw.split(",") if part.strip()}
    except ValueError:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="`classes` must be comma-separated integers, e.g. `0,2`.",
        )
    if not parsed:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, detail="Select at least one class to redact."
        )
    return parsed


def _settings_or_422(**kwargs) -> engine.BlurSettings:
    try:
        return engine.BlurSettings(**kwargs)
    except ValueError as error:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, detail=str(error))


async def _read_upload(upload: UploadFile) -> bytes:
    data = await upload.read()
    if not data:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, detail="The upload was empty.")
    if len(data) > config.MAX_UPLOAD_BYTES:
        raise HTTPException(
            status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"Upload exceeds the {config.MAX_UPLOAD_BYTES // (1024 * 1024)} MB limit.",
        )
    return data


@router.get("/me")
def whoami(key: ApiKey = Depends(require_api_key), session: Session = Depends(get_session)) -> dict:
    """What this key is, who it belongs to, and how much of its quota is left."""
    used = month_usage(session, key)
    expires = as_utc(key.expires_at)
    return {
        "key": key.masked,
        "label": key.label,
        "environment": key.environment.value,
        "account": {
            "name": key.customer.display_name,
            "email": key.customer.email,
            "company": key.customer.company,
        },
        "expires_at": expires.isoformat() if expires else None,
        "quota": {
            "monthly_limit": key.monthly_quota or None,
            "used_this_month": used,
            "remaining": (key.monthly_quota - used) if key.monthly_quota else None,
        },
        "allow_video": key.allow_video,
        "total_requests": key.request_count,
    }


@router.get("/models")
def models(_: ApiKey = Depends(require_api_key)) -> dict:
    """The loaded model and the class indices `classes` accepts."""
    names = engine.class_names()
    return {
        "model": config.MODEL_NAME,
        "confidence_threshold": config.CONFIDENCE,
        "classes": [{"index": index, "name": name} for index, name in sorted(names.items())],
    }


@router.post("/redact/image")
async def redact_image(
    file: UploadFile,
    classes: str = Form("0"),
    style: str = Form("pixelate"),
    method: str = Form("box"),
    strength: float = Form(engine.STRENGTH_DEFAULT),
    key: ApiKey = Depends(require_api_key),
    session: Session = Depends(get_session),
) -> Response:
    """Redact one image. Returns the redacted PNG as the response body."""
    settings = _settings_or_422(
        classes=_parse_classes(classes), style=style, method=method, strength=strength
    )
    data = await _read_upload(file)

    started = time.monotonic()
    try:
        output, detections = engine.redact_image(data, settings)
    except ValueError as error:
        elapsed = int((time.monotonic() - started) * 1000)
        record_usage(
            session, key, endpoint="redact/image", status_code=422,
            duration_ms=elapsed, bytes_in=len(data),
        )
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, detail=str(error))

    elapsed = int((time.monotonic() - started) * 1000)
    record_usage(
        session, key, endpoint="redact/image", status_code=200,
        duration_ms=elapsed, bytes_in=len(data), detections=detections,
    )
    return Response(
        content=output,
        media_type="image/png",
        headers={
            "X-Redact-Detections": str(detections),
            "X-Redact-Duration-Ms": str(elapsed),
        },
    )


@router.post("/redact/video")
async def redact_video(
    file: UploadFile,
    classes: str = Form("0"),
    style: str = Form("pixelate"),
    method: str = Form("box"),
    strength: float = Form(engine.STRENGTH_DEFAULT),
    tracking: bool = Form(True),
    key: ApiKey = Depends(require_api_key),
    session: Session = Depends(get_session),
) -> FileResponse:
    """Redact every frame of a video. Returns an MP4. Note: the output has no audio track."""
    if not key.allow_video:
        raise HTTPException(
            status.HTTP_403_FORBIDDEN, detail="This key is not permitted to redact video."
        )

    settings = _settings_or_422(
        classes=_parse_classes(classes), style=style, method=method,
        strength=strength, tracking=tracking,
    )
    data = await _read_upload(file)

    workdir = Path(tempfile.mkdtemp(prefix="redact-"))
    source = workdir / (file.filename or "input.mp4")
    destination = workdir / "redacted.mp4"
    source.write_bytes(data)

    started = time.monotonic()
    try:
        frames, detections = engine.redact_video(source, destination, settings)
    except ValueError as error:
        elapsed = int((time.monotonic() - started) * 1000)
        record_usage(
            session, key, endpoint="redact/video", status_code=422,
            duration_ms=elapsed, bytes_in=len(data),
        )
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, detail=str(error))

    elapsed = int((time.monotonic() - started) * 1000)
    record_usage(
        session, key, endpoint="redact/video", status_code=200,
        duration_ms=elapsed, bytes_in=len(data), detections=detections,
    )
    return FileResponse(
        destination,
        media_type="video/mp4",
        filename="redacted.mp4",
        headers={
            "X-Redact-Frames": str(frames),
            "X-Redact-Detections": str(detections),
            "X-Redact-Duration-Ms": str(elapsed),
        },
    )
