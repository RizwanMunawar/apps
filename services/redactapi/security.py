"""Password hashing and API-key minting. Stdlib only — no bcrypt/passlib dependency."""
from __future__ import annotations

import hashlib
import hmac
import secrets

_PBKDF2_ROUNDS = 240_000


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, _PBKDF2_ROUNDS)
    return f"pbkdf2_sha256${_PBKDF2_ROUNDS}${salt.hex()}${digest.hex()}"


def verify_password(password: str, encoded: str) -> bool:
    try:
        algorithm, rounds, salt_hex, digest_hex = encoded.split("$")
    except ValueError:
        return False
    if algorithm != "pbkdf2_sha256":
        return False
    expected = hashlib.pbkdf2_hmac(
        "sha256", password.encode(), bytes.fromhex(salt_hex), int(rounds)
    )
    return hmac.compare_digest(expected, bytes.fromhex(digest_hex))


def mint_key(prefix: str) -> tuple[str, str, str]:
    """Return `(secret, sha256_hash, last4)`.

    The secret is the only time the full key exists anywhere. 32 bytes of `secrets.token_urlsafe`
    is ~256 bits of entropy, so the hash is not brute-forceable and needs no salt — unlike a
    password, which is low-entropy and does.
    """
    body = secrets.token_urlsafe(32).replace("-", "").replace("_", "")[:40]
    secret = f"{prefix}_{body}"
    return secret, hash_key(secret), body[-4:]


def hash_key(secret: str) -> str:
    return hashlib.sha256(secret.encode()).hexdigest()
