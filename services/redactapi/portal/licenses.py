"""Admin pages for app licensing.

The panel never signs anything. Issuing a license creates a *draft* and shows the blob you feed
to `licensetool sign` on your own machine; you paste the signed token back here. That is the
whole point of the split: someone who takes over this panel can create drafts all day and not
one of them will unlock an app.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, Form, Request, status
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from sqlalchemy import desc, select
from sqlalchemy.orm import Session

from .. import config
from ..auth import require_admin
from ..db import get_session
from ..licensing import LicenseError
from ..licenseservice import (
    attach_signed_token, create_draft, deactivate, draft_string, payload_for,
)
from ..models import Activation, Admin, Customer, License, LicenseStatus, utcnow
from .routes import DURATION_CHOICES, redirect, render, resolve_expiry

router = APIRouter(prefix="/admin/licenses", tags=["portal"])

FEATURE_CHOICES = [
    ("redact", "Redaction (core)"),
    ("recorder", "Session recorder"),
    ("batch", "Batch / folder processing"),
    ("custom-models", "Custom model import"),
]


@router.get("", response_class=HTMLResponse)
@router.get("/", response_class=HTMLResponse)
def licenses(
    request: Request,
    status_filter: str = "",
    admin: Admin = Depends(require_admin),
    session: Session = Depends(get_session),
) -> HTMLResponse:
    rows = list(session.scalars(select(License).order_by(desc(License.created_at))))
    shown = [r for r in rows if r.display_status == status_filter] if status_filter else rows
    return render(
        request, "licenses.html", admin=admin, licenses=shown, status_filter=status_filter,
        customers=list(session.scalars(select(Customer).order_by(Customer.email))),
        durations=DURATION_CHOICES, features=FEATURE_CHOICES,
        drafts_awaiting=sum(1 for r in rows if r.status is LicenseStatus.draft),
        signing_ready=bool(config.LICENSE_PUBLIC_KEY),
    )


@router.post("")
def issue(
    customer_id: str = Form(...),
    seats: int = Form(1),
    duration: str = Form("365"),
    custom_date: str = Form(""),
    notes: str = Form(""),
    feature: list[str] = Form(default=["redact"]),
    admin: Admin = Depends(require_admin),
    session: Session = Depends(get_session),
) -> RedirectResponse:
    """Record a license. Produces a draft — signing happens offline."""
    customer = session.get(Customer, int(customer_id)) if customer_id else None
    if customer is None:
        return redirect("/admin/licenses", error="Pick an account to issue this license to.")

    try:
        expires_at = resolve_expiry(duration, custom_date)
    except ValueError as error:
        return redirect("/admin/licenses", error=str(error))

    row = create_draft(
        session, customer, seats=seats, features=feature or ["redact"],
        expires_at=expires_at, notes=notes.strip(), created_by=admin.email,
    )
    return redirect(f"/admin/licenses/{row.id}", flash="Draft created. Sign it to activate.")


@router.get("/{license_db_id}", response_class=HTMLResponse)
def detail(
    request: Request,
    license_db_id: int,
    admin: Admin = Depends(require_admin),
    session: Session = Depends(get_session),
) -> Response:
    row = session.get(License, license_db_id)
    if row is None:
        return redirect("/admin/licenses", error="No such license.")

    draft = payload = None
    if row.status is LicenseStatus.draft:
        try:
            draft, payload = draft_string(row), payload_for(row)
        except LicenseError as error:
            return redirect("/admin/licenses", error=str(error))

    return render(
        request, "license_detail.html", admin=admin, license=row, draft=draft, payload=payload,
        signing_ready=bool(config.LICENSE_PUBLIC_KEY),
    )


@router.post("/{license_db_id}/sign")
def attach(
    license_db_id: int,
    token: str = Form(...),
    admin: Admin = Depends(require_admin),
    session: Session = Depends(get_session),
) -> RedirectResponse:
    """Store a token that was signed offline, after verifying it matches this draft."""
    row = session.get(License, license_db_id)
    if row is None:
        return redirect("/admin/licenses", error="No such license.")

    try:
        attach_signed_token(session, row, token)
    except LicenseError as error:
        return redirect(f"/admin/licenses/{license_db_id}", error=str(error))

    return redirect(
        f"/admin/licenses/{license_db_id}",
        flash=f"Signature verified. {row.license_id} is now active.",
    )


@router.post("/{license_db_id}/revoke")
def revoke(
    license_db_id: int,
    admin: Admin = Depends(require_admin),
    session: Session = Depends(get_session),
) -> RedirectResponse:
    """Kill a license.

    Because the app verifies offline, revocation only bites when the app next reaches the
    heartbeat endpoint — an offline machine keeps working until then. That is inherent to
    offline verification, not an oversight; the alternative is an app that stops working on a
    plane.
    """
    row = session.get(License, license_db_id)
    if row is None:
        return redirect("/admin/licenses", error="No such license.")

    row.revoked_at = utcnow()
    row.status = LicenseStatus.revoked
    session.commit()
    return redirect(
        f"/admin/licenses/{license_db_id}",
        flash="Revoked. It stops working when that machine next checks in.",
    )


@router.post("/{license_db_id}/seats/{activation_id}/release")
def release_seat(
    license_db_id: int,
    activation_id: int,
    admin: Admin = Depends(require_admin),
    session: Session = Depends(get_session),
) -> RedirectResponse:
    activation = session.get(Activation, activation_id)
    if activation is None or activation.license_db_id != license_db_id:
        return redirect(f"/admin/licenses/{license_db_id}", error="No such activation.")

    deactivate(session, activation)
    return redirect(f"/admin/licenses/{license_db_id}", flash="Seat released.")
