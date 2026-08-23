"""Settings, read from the environment once at import."""
from __future__ import annotations

import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
SERVICE_DIR = BASE_DIR.parent


def _load_dotenv() -> None:
    """Minimal .env reader so the service runs without an extra dependency."""
    path = SERVICE_DIR / ".env"
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip())


_load_dotenv()

SECRET_KEY = os.environ.get("REDACT_SECRET_KEY", "")
ADMIN_EMAIL = os.environ.get("REDACT_ADMIN_EMAIL", "")
ADMIN_PASSWORD = os.environ.get("REDACT_ADMIN_PASSWORD", "")
DATABASE_URL = os.environ.get("REDACT_DATABASE_URL", "sqlite:///./redact.db")
MODEL_NAME = os.environ.get("REDACT_MODEL", "yolo26n-seg.pt")
CONFIDENCE = float(os.environ.get("REDACT_CONFIDENCE", "0.4"))
MAX_UPLOAD_BYTES = int(os.environ.get("REDACT_MAX_UPLOAD_MB", "100")) * 1024 * 1024

# Key prefix. `live` keys bill and count against quota; `test` keys are free and rate-limited
# harder, which is the split every API-key product ends up needing.
KEY_PREFIX_LIVE = "rdk_live"
KEY_PREFIX_TEST = "rdk_test"


def require_secret_key() -> str:
    if not SECRET_KEY or SECRET_KEY == "change-me-to-a-64-char-hex-string":
        raise RuntimeError(
            "REDACT_SECRET_KEY is unset. Copy services/.env.example to services/.env and set it."
        )
    return SECRET_KEY
