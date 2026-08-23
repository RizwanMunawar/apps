"""Authentication for both faces of the service: bearer keys on /v1, sessions on /admin."""
from __future__ import annotations

from datetime import datetime, timezone

from fastapi import Depends, Header, HTTPException, Request, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .db import get_session
from .models import Admin, ApiKey, CustomerStatus, UsageRecord, as_utc, utcnow
from .security import hash_key


def month_start(now: datetime | None = None) -> datetime:
    now = now or utcnow()
    return datetime(now.year, now.month, 1, tzinfo=timezone.utc)


def month_usage(session: Session, key: ApiKey) -> int:
    """Successful calls this calendar month. Errors don't burn quota."""
    return session.scalar(
        select(func.count(UsageRecord.id)).where(
            UsageRecord.api_key_id == key.id,
            UsageRecord.at >= month_start(),
            UsageRecord.status_code < 400,
        )
    ) or 0


def require_api_key(
    authorization: str | None = Header(default=None),
    session: Session = Depends(get_session),
) -> ApiKey:
    """Resolve `Authorization: Bearer rdk_live_...` to a key that is allowed to run right now.

    Every rejection is a distinct status so a caller can tell "your key is wrong" from "your key
    expired" from "you're out of quota" without guessing.
    """
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED,
            detail="Missing API key. Send `Authorization: Bearer rdk_live_...`.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    secret = authorization.split(" ", 1)[1].strip()
    # Looked up by hash, so a timing attack on the lookup leaks nothing about the secret.
    key = session.scalar(select(ApiKey).where(ApiKey.key_hash == hash_key(secret)))
    if key is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Invalid API key.")

    if key.is_revoked:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="This API key has been revoked.")

    if key.is_expired:
        expired_on = as_utc(key.expires_at)
        raise HTTPException(
            status.HTTP_403_FORBIDDEN,
            detail=f"This API key expired on {expired_on:%Y-%m-%d %H:%M UTC}.",
        )

    if key.customer_id is None:
        raise HTTPException(
            status.HTTP_403_FORBIDDEN,
            detail="This API key is not assigned to an account yet.",
        )

    if key.customer and key.customer.status is CustomerStatus.suspended:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="This account is suspended.")

    if key.monthly_quota and month_usage(session, key) >= key.monthly_quota:
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            detail=f"Monthly quota of {key.monthly_quota} requests is used up.",
            headers={"Retry-After": "3600"},
        )

    return key


def record_usage(
    session: Session,
    key: ApiKey,
    *,
    endpoint: str,
    status_code: int,
    duration_ms: int,
    bytes_in: int = 0,
    detections: int = 0,
) -> None:
    """Append one usage row and refresh the key's rollup counters."""
    session.add(
        UsageRecord(
            api_key_id=key.id,
            endpoint=endpoint,
            status_code=status_code,
            duration_ms=duration_ms,
            bytes_in=bytes_in,
            detections=detections,
        )
    )
    key.last_used_at = utcnow()
    if status_code < 400:
        key.request_count += 1
    session.commit()


# --- Portal sessions ---------------------------------------------------------------------

SESSION_KEY = "admin_id"


def current_admin(request: Request, session: Session = Depends(get_session)) -> Admin | None:
    admin_id = request.session.get(SESSION_KEY)
    if admin_id is None:
        return None
    return session.get(Admin, admin_id)


def require_admin(admin: Admin | None = Depends(current_admin)) -> Admin:
    """Portal pages depend on this; unauthenticated hits are redirected by the exception handler."""
    if admin is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Sign in required.")
    return admin


# --- Customer sessions -------------------------------------------------------------------
# Deliberately a different session key from the admin one. A customer session can never be
# mistaken for an admin session, so no amount of cookie tampering promotes a customer into
# /admin — the two look up different tables entirely.

CUSTOMER_SESSION_KEY = "customer_id"


def current_customer(request: Request, session: Session = Depends(get_session)):
    from .models import Customer

    customer_id = request.session.get(CUSTOMER_SESSION_KEY)
    if customer_id is None:
        return None
    customer = session.get(Customer, customer_id)
    # A suspended or password-less account loses its session immediately, without waiting for
    # the cookie to expire.
    return customer if customer and customer.can_sign_in else None


def require_customer(customer=Depends(current_customer)):
    if customer is None:
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED, detail="Sign in to view your licenses."
        )
    return customer
