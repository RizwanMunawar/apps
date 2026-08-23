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

# --- Licensing -----------------------------------------------------------------------------
# Verify-only. The matching private key lives on Rizwan's machine and is never read here, which
# is what stops a server compromise from minting licenses. See licensing.py.
LICENSE_PUBLIC_KEY = os.environ.get("REDACT_LICENSE_PUBLIC_KEY", "")

# The trial keypair is weaker on purpose: its private half *is* on the server, because trials
# must issue automatically. Anything it signs is capped at TRIAL_DAYS by the verifier, so
# stealing it buys an attacker only a trial they could have requested legitimately.
TRIAL_PRIVATE_KEY = os.environ.get("REDACT_TRIAL_PRIVATE_KEY", "")
TRIAL_PUBLIC_KEY = os.environ.get("REDACT_TRIAL_PUBLIC_KEY", "")

# Off by default: accounts are created by an admin, who sends a one-time invite link. Nobody
# can create themselves an account by visiting the licensing page. Set to 1 only if you decide
# you want open self-serve trials.
OPEN_SIGNUP = os.environ.get("REDACT_OPEN_SIGNUP", "0").strip().lower() in {"1", "true", "yes"}

# Public origin the licensing pages are served under, for canonical URLs and OG tags.
SITE_ORIGIN = os.environ.get("REDACT_SITE_ORIGIN", "https://rizwanai.com")


def licensing_configured() -> bool:
    """True when the service can verify licenses and issue trials."""
    return bool(LICENSE_PUBLIC_KEY and TRIAL_PRIVATE_KEY and TRIAL_PUBLIC_KEY)


def require_secret_key() -> str:
    if not SECRET_KEY or SECRET_KEY == "change-me-to-a-64-char-hex-string":
        raise RuntimeError(
            "REDACT_SECRET_KEY is unset. Copy services/.env.example to services/.env and set it."
        )
    return SECRET_KEY
