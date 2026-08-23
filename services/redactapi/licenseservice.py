"""License operations shared by the admin panel, the customer portal, and the app API."""
from __future__ import annotations

import base64
import json
import secrets
from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from . import config
from .licensing import (
    KIND_FULL, KIND_TRIAL, TRIAL_DAYS, LicenseError, LicensePayload, canonical_payload,
    load_private_key, load_public_key, mint_trial, verify_any,
)
from .models import (
    Activation, Customer, License, LicenseKind, LicenseStatus, as_utc, utcnow,
)

_ID_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no I/O/0/1 — these get read aloud on support calls


def new_license_id() -> str:
    return "lic_" + "".join(secrets.choice(_ID_ALPHABET) for _ in range(10))


def license_public_key():
    if not config.LICENSE_PUBLIC_KEY:
        raise LicenseError("No license public key is configured on this server.")
    return load_public_key(config.LICENSE_PUBLIC_KEY)


def trial_public_key():
    return load_public_key(config.TRIAL_PUBLIC_KEY) if config.TRIAL_PUBLIC_KEY else None


def payload_for(license_row: License) -> LicensePayload:
    """The exact payload the offline signer must sign for this row."""
    return LicensePayload(
        license_id=license_row.license_id,
        account_email=license_row.customer.email,
        account_name=license_row.customer.company or license_row.customer.display_name,
        seats=license_row.seats,
        issued_at=int(as_utc(license_row.created_at).timestamp()),
        expires_at=(
            int(as_utc(license_row.expires_at).timestamp()) if license_row.expires_at else None
        ),
        features=license_row.feature_list,
        kind=KIND_FULL,
    )


def draft_string(license_row: License) -> str:
    """The blob an admin copies into `licensetool sign`.

    base64url of the canonical payload, so a copy-paste through a terminal, a chat window or an
    email cannot mangle it with quoting or line wrapping.
    """
    body = canonical_payload(payload_for(license_row))
    return base64.urlsafe_b64encode(body).decode().rstrip("=")


def attach_signed_token(session: Session, license_row: License, token: str) -> None:
    """Store a token produced offline, after checking it really matches this draft.

    Verifies twice over: the signature must be genuine under the production public key, and the
    payload must describe *this* license. Otherwise a mistyped paste could silently attach the
    wrong customer's license to a row.
    """
    payload = verify_any(token, license_public_key(), trial_public_key())

    if payload.kind != KIND_FULL:
        raise LicenseError("That is a trial token, not a full license.")
    if payload.license_id != license_row.license_id:
        raise LicenseError(
            f"That token is for {payload.license_id}, but this license is {license_row.license_id}."
        )
    if payload.account_email.lower() != license_row.customer.email.lower():
        raise LicenseError(
            f"That token is issued to {payload.account_email}, "
            f"not {license_row.customer.email}."
        )
    if payload.seats != license_row.seats:
        raise LicenseError(
            f"That token grants {payload.seats} seats, but this license records "
            f"{license_row.seats}. Re-sign the current draft."
        )

    license_row.token = "".join(token.split())
    license_row.status = LicenseStatus.active
    license_row.signed_at = utcnow()
    session.commit()


def create_draft(
    session: Session, customer: Customer, *, seats: int, features: list[str],
    expires_at: datetime | None, notes: str = "", created_by: str = "",
) -> License:
    row = License(
        license_id=new_license_id(),
        customer_id=customer.id,
        kind=LicenseKind.full,
        status=LicenseStatus.draft,
        seats=max(1, seats),
        features=",".join(features) or "redact",
        expires_at=expires_at,
        notes=notes,
        created_by=created_by,
    )
    session.add(row)
    session.commit()
    return row


def existing_trial(session: Session, customer: Customer) -> License | None:
    return session.scalar(
        select(License).where(
            License.customer_id == customer.id, License.kind == LicenseKind.trial
        )
    )


def issue_trial(session: Session, customer: Customer) -> tuple[License, str]:
    """Start this account's one and only trial.

    One per account, forever — re-requesting returns the original, expired or not. That is the
    whole enforcement story server-side: an account cannot farm fresh trials, and since every
    trial needs an account, neither can a person without making new email addresses.
    """
    if not config.TRIAL_PRIVATE_KEY:
        raise LicenseError("Trials are not available: no trial signing key is configured.")

    previous = existing_trial(session, customer)
    if previous is not None:
        return previous, previous.token or ""

    license_id = new_license_id()
    token, payload = mint_trial(
        license_id, customer.email, customer.company or customer.display_name,
        load_private_key(config.TRIAL_PRIVATE_KEY),
    )
    row = License(
        license_id=license_id,
        customer_id=customer.id,
        kind=LicenseKind.trial,
        status=LicenseStatus.active,
        seats=1,
        features="redact",
        expires_at=datetime.fromtimestamp(payload.expires_at, tz=timezone.utc),
        token=token,
        signed_at=utcnow(),
        created_by="self-serve trial",
    )
    session.add(row)
    session.commit()
    return row, token


def find_by_token(session: Session, token: str) -> License | None:
    return session.scalar(select(License).where(License.token == "".join(token.split())))


def activate(
    session: Session, license_row: License, machine_id: str, machine_name: str, app_version: str,
) -> Activation:
    """Claim a seat for one machine, or refresh the claim it already has."""
    existing = next(
        (a for a in license_row.activations
         if a.machine_id == machine_id and a.deactivated_at is None),
        None,
    )
    if existing is not None:
        existing.last_seen_at = utcnow()
        existing.machine_name = machine_name or existing.machine_name
        existing.app_version = app_version or existing.app_version
        session.commit()
        return existing

    if license_row.seats_free <= 0:
        raise LicenseError(
            f"All {license_row.seats} seat{'s' if license_row.seats != 1 else ''} on this "
            f"license are in use. Release one from your account page first."
        )

    activation = Activation(
        license_db_id=license_row.id,
        machine_id=machine_id,
        machine_name=machine_name,
        app_version=app_version,
    )
    session.add(activation)
    session.commit()
    return activation


def deactivate(session: Session, activation: Activation) -> None:
    activation.deactivated_at = utcnow()
    session.commit()


def trial_days_left(license_row: License) -> int:
    expires = as_utc(license_row.expires_at)
    if expires is None:
        return TRIAL_DAYS
    return max(0, (expires - utcnow()).days + (1 if (expires - utcnow()).seconds else 0))
