"""License minting and verification.

The security property this file exists to provide: **a compromised server cannot mint a
license.** The Ed25519 private key lives only on Rizwan's machine and is never loaded by the web
process — `sign_license` is reachable solely from the offline CLI (`licensetool.py`). The server
holds the public key, so it can verify and display licenses but never create one.

That is also why the admin panel's "issue" flow produces an unsigned *draft*: the panel records
what a license should say, and signing happens out of band. Anyone who steals the admin login
gets the ability to write drafts nobody's app will accept.

Trials are the one thing that must mint automatically, so they use a **second, weaker keypair**
whose private half does live on the server. The app hard-caps anything signed by it at
`TRIAL_DAYS` and to trial features, so stealing the online key buys an attacker nothing better
than a 14-day trial they could have clicked a button for anyway. Full licenses are only ever
accepted under the offline key.

Token format, deliberately self-contained so the Mac app can verify with no network:

    RZAI1.<base64url(payload json)>.<base64url(ed25519 signature)>
"""
from __future__ import annotations

import base64
import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey, Ed25519PublicKey,
)

TOKEN_PREFIX = "RZAI1"
LICENSE_VERSION = 1
TRIAL_DAYS = 14

KIND_FULL = "full"
KIND_TRIAL = "trial"


class LicenseError(ValueError):
    """Raised for any malformed, mis-signed, or unverifiable license token."""


def _b64encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _b64decode(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


@dataclass
class LicensePayload:
    """What a license asserts. Kept short: every field is carried inside the token itself."""

    license_id: str
    account_email: str
    account_name: str = ""
    seats: int = 1
    # Unix seconds. `None` means perpetual — it never stops working.
    expires_at: int | None = None
    issued_at: int = 0
    features: list[str] = field(default_factory=lambda: ["redact"])
    product: str = "redact"
    # Which keypair is allowed to sign this: KIND_FULL (offline key) or KIND_TRIAL (online).
    kind: str = KIND_FULL
    version: int = LICENSE_VERSION

    def to_dict(self) -> dict[str, Any]:
        # Short keys, sorted at encode time: the token is pasted by humans, so every byte counts.
        return {
            "v": self.version,
            "id": self.license_id,
            "sub": self.account_email,
            "nm": self.account_name,
            "st": self.seats,
            "iat": self.issued_at,
            "exp": self.expires_at,
            "ft": self.features,
            "app": self.product,
            "k": self.kind,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "LicensePayload":
        try:
            return cls(
                version=int(data["v"]),
                license_id=str(data["id"]),
                account_email=str(data["sub"]),
                account_name=str(data.get("nm", "")),
                seats=int(data.get("st", 1)),
                issued_at=int(data.get("iat", 0)),
                expires_at=None if data.get("exp") is None else int(data["exp"]),
                features=list(data.get("ft", ["redact"])),
                product=str(data.get("app", "redact")),
                kind=str(data.get("k", KIND_FULL)),
            )
        except (KeyError, TypeError, ValueError) as error:
            raise LicenseError(f"License payload is malformed: {error}")

    @property
    def expires_datetime(self) -> datetime | None:
        if self.expires_at is None:
            return None
        return datetime.fromtimestamp(self.expires_at, tz=timezone.utc)

    def is_expired(self, now: datetime | None = None) -> bool:
        expires = self.expires_datetime
        if expires is None:
            return False
        return expires <= (now or datetime.now(timezone.utc))


def canonical_payload(payload: LicensePayload) -> bytes:
    """The exact bytes that get signed.

    Sorted keys and no whitespace, so the same payload always produces the same bytes on any
    machine — otherwise a signature made by the CLI would not verify on the server.
    """
    return json.dumps(payload.to_dict(), sort_keys=True, separators=(",", ":")).encode()


def sign_license(payload: LicensePayload, private_key: Ed25519PrivateKey) -> str:
    """Mint a license token. Only ever called by the offline CLI, never by the web process."""
    body = canonical_payload(payload)
    signature = private_key.sign(body)
    return f"{TOKEN_PREFIX}.{_b64encode(body)}.{_b64encode(signature)}"


def verify_license(token: str, public_key: Ed25519PublicKey) -> LicensePayload:
    """Parse and cryptographically check a token. Raises `LicenseError` if it is not genuine.

    Does *not* check expiry — callers decide how to treat an expired-but-genuine license, which
    differs between the app (block) and the portal (show as expired).
    """
    cleaned = "".join(token.split())
    parts = cleaned.split(".")
    if len(parts) != 3 or parts[0] != TOKEN_PREFIX:
        raise LicenseError("That does not look like a RizwanAI license key.")

    _, body_b64, signature_b64 = parts
    try:
        body = _b64decode(body_b64)
        signature = _b64decode(signature_b64)
    except (ValueError, base64.binascii.Error):
        raise LicenseError("This license key is damaged — some characters are missing or altered.")

    try:
        public_key.verify(signature, body)
    except InvalidSignature:
        raise LicenseError("This license key's signature is not valid. It was not issued by us.")

    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        raise LicenseError("This license key's contents are unreadable.")

    payload = LicensePayload.from_dict(data)
    if payload.version != LICENSE_VERSION:
        raise LicenseError(
            f"This license needs a newer version of the app (format v{payload.version})."
        )
    return payload


# --- Key material -------------------------------------------------------------------------

def generate_keypair() -> tuple[str, str]:
    """Create a fresh signing keypair. Returns `(private_b64, public_b64)`.

    Run once, by the CLI. The private half is written to a file only Rizwan holds; the public
    half goes into the server config and gets compiled into the Mac app.
    """
    from cryptography.hazmat.primitives import serialization

    private = Ed25519PrivateKey.generate()
    private_raw = private.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    )
    public_raw = private.public_key().public_bytes(
        encoding=serialization.Encoding.Raw, format=serialization.PublicFormat.Raw
    )
    return _b64encode(private_raw), _b64encode(public_raw)


def load_private_key(encoded: str) -> Ed25519PrivateKey:
    return Ed25519PrivateKey.from_private_bytes(_b64decode(encoded.strip()))


def load_public_key(encoded: str) -> Ed25519PublicKey:
    return Ed25519PublicKey.from_public_bytes(_b64decode(encoded.strip()))


def mint_trial(
    license_id: str, account_email: str, account_name: str, trial_private_key: Ed25519PrivateKey,
    now: datetime | None = None, days: int = TRIAL_DAYS,
) -> tuple[str, LicensePayload]:
    """Issue a time-boxed trial with the online key.

    `days` is clamped to `TRIAL_DAYS` here as well as at verification time — a bug or a tampered
    caller on this side should not be able to widen a trial either.
    """
    now = now or datetime.now(timezone.utc)
    payload = LicensePayload(
        license_id=license_id,
        account_email=account_email,
        account_name=account_name,
        seats=1,
        issued_at=int(now.timestamp()),
        expires_at=int(now.timestamp()) + min(days, TRIAL_DAYS) * 86_400,
        features=["redact"],
        kind=KIND_TRIAL,
    )
    return sign_license(payload, trial_private_key), payload


def verify_any(
    token: str,
    license_public_key: Ed25519PublicKey,
    trial_public_key: Ed25519PublicKey | None = None,
) -> LicensePayload:
    """Verify a token against whichever key its `kind` entitles it to, and enforce trial limits.

    The order matters: the token's claimed `kind` selects the key, and a trial is then held to
    `TRIAL_DAYS` regardless of what its payload says. So a token signed by the online trial key
    can never be inflated into a perpetual license by editing `exp` — editing it breaks the
    signature, and claiming `kind: full` sends it to a key that never signed it.
    """
    cleaned = "".join(token.split())
    parts = cleaned.split(".")
    if len(parts) != 3 or parts[0] != TOKEN_PREFIX:
        raise LicenseError("That does not look like a RizwanAI license key.")

    try:
        claimed = json.loads(_b64decode(parts[1])).get("k", KIND_FULL)
    except (ValueError, AttributeError, base64.binascii.Error):
        raise LicenseError("This license key is damaged — some characters are missing or altered.")

    if claimed == KIND_TRIAL:
        if trial_public_key is None:
            raise LicenseError("Trials are not accepted here.")
        payload = verify_license(token, trial_public_key)
        span_days = ((payload.expires_at or 0) - payload.issued_at) / 86_400
        if payload.expires_at is None or span_days > TRIAL_DAYS + 1:
            raise LicenseError(f"A trial cannot run longer than {TRIAL_DAYS} days.")
        return payload

    return verify_license(token, license_public_key)
