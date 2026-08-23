"""What the Mac app talks to: trials, activation, and revocation checks.

None of these need an API key — they are the app's own licensing channel, authenticated by the
customer's own credentials or by possession of a license token.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, EmailStr, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import config
from ..db import get_session
from ..licensing import TRIAL_DAYS, LicenseError, verify_any
from ..licenseservice import (
    activate, find_by_token, issue_trial, license_public_key, trial_public_key,
)
from ..models import Customer, CustomerStatus, LicenseStatus, as_utc, utcnow
from ..security import hash_password, verify_password

router = APIRouter(prefix="/v1/license", tags=["licensing"])


class Credentials(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1)


class SignupRequest(Credentials):
    password: str = Field(min_length=10)
    name: str = ""
    company: str = ""


class ActivateRequest(BaseModel):
    token: str
    machine_id: str = Field(min_length=8, max_length=64)
    machine_name: str = ""
    app_version: str = ""


class HeartbeatRequest(BaseModel):
    token: str
    machine_id: str = Field(min_length=8, max_length=64)


def _authenticate(session: Session, credentials: Credentials) -> Customer:
    customer = session.scalar(
        select(Customer).where(Customer.email == credentials.email.strip().lower())
    )
    if customer is None or not customer.password_hash \
            or not verify_password(credentials.password, customer.password_hash):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Email or password is wrong.")
    if customer.status is CustomerStatus.suspended:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="This account is suspended.")
    return customer


def _license_summary(row, payload=None) -> dict:
    expires = as_utc(row.expires_at)
    return {
        "license_id": row.license_id,
        "kind": row.kind.value,
        "status": row.display_status,
        "seats": row.seats,
        "seats_used": row.seats_used,
        "features": row.feature_list,
        "expires_at": expires.isoformat() if expires else None,
        "account": row.customer.email,
    }


@router.post("/signup", status_code=status.HTTP_201_CREATED)
def signup(request: SignupRequest, session: Session = Depends(get_session)) -> dict:
    """Create the account a trial or license hangs off. Every license needs one.

    Disabled unless open signup is explicitly enabled, so the app cannot be used as a side door
    to create accounts the web portal would refuse.
    """
    if not config.OPEN_SIGNUP:
        raise HTTPException(
            status.HTTP_403_FORBIDDEN,
            detail="Accounts are issued by invitation. Contact RizwanAI for access.",
        )

    email = request.email.strip().lower()
    existing = session.scalar(select(Customer).where(Customer.email == email))
    if existing is not None and existing.password_hash:
        raise HTTPException(status.HTTP_409_CONFLICT, detail="That account already exists.")

    if existing is not None:
        existing.password_hash = hash_password(request.password)
        existing.name = existing.name or request.name
        existing.company = existing.company or request.company
        customer = existing
    else:
        customer = Customer(
            email=email, name=request.name, company=request.company,
            password_hash=hash_password(request.password),
        )
        session.add(customer)
    session.commit()
    return {"account": customer.email, "created": True}


@router.post("/trial")
def start_trial(request: Credentials, session: Session = Depends(get_session)) -> dict:
    """Issue this account's one trial, or hand back the one it already has.

    Re-requesting never extends anything: the same token comes back, expired or not. Combined
    with a trial requiring an account, that is what stops trial farming.
    """
    customer = _authenticate(session, request)
    try:
        row, token = issue_trial(session, customer)
    except LicenseError as error:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(error))

    return {
        "token": token,
        "trial_days": TRIAL_DAYS,
        "already_used": row.is_expired,
        "license": _license_summary(row),
    }


@router.post("/activate")
def activate_machine(request: ActivateRequest, session: Session = Depends(get_session)) -> dict:
    """Claim a seat for this Mac.

    The token is verified cryptographically first, so a forged one is rejected before any
    database lookup happens.
    """
    try:
        payload = verify_any(request.token, license_public_key(), trial_public_key())
    except LicenseError as error:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail=str(error))

    row = find_by_token(session, request.token)
    if row is None:
        raise HTTPException(
            status.HTTP_404_NOT_FOUND,
            detail="This license is genuine but unknown to us. Contact support.",
        )
    if row.is_revoked:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="This license has been revoked.")
    if row.is_expired:
        raise HTTPException(
            status.HTTP_403_FORBIDDEN,
            detail=f"This {row.kind.value} expired on {as_utc(row.expires_at):%Y-%m-%d}.",
        )

    try:
        seat = activate(
            session, row, request.machine_id, request.machine_name, request.app_version
        )
    except LicenseError as error:
        raise HTTPException(status.HTTP_409_CONFLICT, detail=str(error))

    return {
        "activated": True,
        "machine_id": seat.machine_id,
        "license": _license_summary(row, payload),
    }


@router.post("/heartbeat")
def heartbeat(request: HeartbeatRequest, session: Session = Depends(get_session)) -> dict:
    """Periodic check-in. The only way revocation reaches an already-activated machine.

    The app treats a failure to reach this endpoint as "keep working" — an offline Mac must not
    stop redacting because it cannot phone home. Revocation therefore takes effect on next
    contact, which is the accepted trade for offline verification.
    """
    row = find_by_token(session, request.token)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Unknown license.")

    seat = next(
        (a for a in row.activations
         if a.machine_id == request.machine_id and a.deactivated_at is None),
        None,
    )
    if seat is not None:
        seat.last_seen_at = utcnow()
        session.commit()

    return {
        "valid": row.is_usable and seat is not None,
        "revoked": row.is_revoked,
        "expired": row.is_expired,
        "seat_released": seat is None,
        "license": _license_summary(row),
    }


@router.get("/status")
def service_status() -> dict:
    """Lets the app tell "licensing is down" from "your license is bad"."""
    return {
        "licensing_configured": config.licensing_configured(),
        "trial_days": TRIAL_DAYS,
        "license_public_key": config.LICENSE_PUBLIC_KEY,
        "trial_public_key": config.TRIAL_PUBLIC_KEY,
    }
