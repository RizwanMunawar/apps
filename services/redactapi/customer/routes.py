"""The customer-facing licensing portal at /apps/license.

Everything here is behind a customer login, by explicit request. That has a real consequence
worth stating plainly: search engines cannot index content they cannot reach, so this URL earns
no ranking for the licensing *content* itself. What it can do is present a well-marked-up,
fast, shareable sign-in page — correct title, description, Open Graph and JSON-LD — so the URL
resolves cleanly when linked and is not actively penalised. That is the honest ceiling for a
gated page.

Customers here are a different table and a different session key from admins. There is no route
in this module that can read another customer's data, and none that touches /admin.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, Form, Request, status
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.templating import Jinja2Templates
from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import config
from ..auth import CUSTOMER_SESSION_KEY, current_customer, require_customer
from ..config import BASE_DIR
from ..db import get_session
from ..licensing import TRIAL_DAYS, LicenseError
from ..licenseservice import deactivate, existing_trial, issue_trial, trial_days_left
from ..models import Activation, Customer, CustomerStatus, utcnow
from ..security import hash_password, verify_password

router = APIRouter(prefix="/apps/license", tags=["licensing"])
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))

MIN_PASSWORD_LENGTH = 10


def render(request: Request, template: str, **context) -> HTMLResponse:
    context.setdefault("brand", "RizwanAI Apps")
    context.setdefault("flash", request.query_params.get("flash"))
    context.setdefault("error", request.query_params.get("error"))
    context.setdefault("site_origin", config.SITE_ORIGIN)
    context.setdefault("canonical", f"{config.SITE_ORIGIN}/apps/license")
    context.setdefault("trial_days", TRIAL_DAYS)
    return templates.TemplateResponse(request, template, context)


def back(path: str = "/apps/license", flash: str | None = None, error: str | None = None):
    if flash:
        path += ("&" if "?" in path else "?") + f"flash={flash}"
    if error:
        path += ("&" if "?" in path else "?") + f"error={error}"
    return RedirectResponse(path, status_code=status.HTTP_303_SEE_OTHER)


@router.get("", response_class=HTMLResponse)
@router.get("/", response_class=HTMLResponse)
def index(
    request: Request,
    customer: Customer | None = Depends(current_customer),
    session: Session = Depends(get_session),
) -> HTMLResponse:
    """Sign-in page for anonymous visitors, licence list for signed-in ones."""
    if customer is None:
        return render(request, "license_public.html", open_signup=config.OPEN_SIGNUP)

    trial = existing_trial(session, customer)
    return render(
        request, "license_account.html", customer=customer,
        licenses=customer.licenses,
        trial=trial,
        trial_days_left=trial_days_left(trial) if trial else None,
        trial_available=trial is None and config.licensing_configured(),
    )


@router.post("/login")
def login(
    request: Request,
    email: str = Form(...),
    password: str = Form(...),
    session: Session = Depends(get_session),
) -> RedirectResponse:
    customer = session.scalar(select(Customer).where(Customer.email == email.strip().lower()))
    # One message for every failure mode — wrong address, wrong password, suspended, no password
    # set — so this page cannot be used to discover which addresses have accounts.
    if customer is None or not customer.password_hash or not customer.can_sign_in \
            or not verify_password(password, customer.password_hash):
        return back(error="That email and password don't match.")

    customer.last_login_at = utcnow()
    session.commit()
    request.session[CUSTOMER_SESSION_KEY] = customer.id
    return back()


@router.post("/signup")
def signup(
    request: Request,
    email: str = Form(...),
    name: str = Form(""),
    company: str = Form(""),
    password: str = Form(...),
    session: Session = Depends(get_session),
) -> RedirectResponse:
    """Create an account — only when open signup is deliberately switched on.

    Off by default. Accounts normally come from an admin invite, so visiting this page can never
    get a stranger an account, a trial, or a licence.
    """
    if not config.OPEN_SIGNUP:
        return back(error="Accounts here are issued by invitation. Contact us for access.")

    email = email.strip().lower()
    if len(password) < MIN_PASSWORD_LENGTH:
        return back(error=f"Choose a password of at least {MIN_PASSWORD_LENGTH} characters.")

    customer = session.scalar(select(Customer).where(Customer.email == email))
    if customer is not None:
        if customer.password_hash:
            # Do not confirm that the address is registered; point at sign-in instead.
            return back(error="That email can't be used to sign up. Try signing in.")
        # An account the admin created ahead of time, now claiming its password.
        customer.password_hash = hash_password(password)
        customer.name = customer.name or name.strip()
        customer.company = customer.company or company.strip()
    else:
        customer = Customer(
            email=email, name=name.strip(), company=company.strip(),
            password_hash=hash_password(password),
        )
        session.add(customer)

    session.commit()
    request.session[CUSTOMER_SESSION_KEY] = customer.id
    return back(flash="Account created.")


@router.post("/logout")
def logout(request: Request) -> RedirectResponse:
    request.session.pop(CUSTOMER_SESSION_KEY, None)
    return back(flash="Signed out.")


@router.post("/trial")
def start_trial(
    customer: Customer = Depends(require_customer),
    session: Session = Depends(get_session),
) -> RedirectResponse:
    try:
        row, _ = issue_trial(session, customer)
    except LicenseError as error:
        return back(error=str(error))

    return back(flash=f"Trial started — {trial_days_left(row)} days remaining.")


@router.post("/seats/{activation_id}/release")
def release_seat(
    activation_id: int,
    customer: Customer = Depends(require_customer),
    session: Session = Depends(get_session),
) -> RedirectResponse:
    activation = session.get(Activation, activation_id)
    # Ownership check, not just existence: without it any signed-in customer could release any
    # other customer's seat by guessing an id.
    if activation is None or activation.license.customer_id != customer.id:
        return back(error="No such machine on your account.")

    deactivate(session, activation)
    return back(flash="Machine released. Its seat is free for another Mac.")


@router.get("/invite/{token}", response_class=HTMLResponse)
def invite(
    request: Request,
    token: str,
    session: Session = Depends(get_session),
) -> Response:
    """Landing page for an admin-issued invite: set a password, get an account."""
    customer = session.scalar(select(Customer).where(Customer.invite_token == token))
    if customer is None or not customer.invite_is_live:
        return back(error="That invitation has expired or has already been used.")

    return render(request, "license_invite.html", customer=customer, token=token)


@router.post("/invite/{token}")
def accept_invite(
    request: Request,
    token: str,
    password: str = Form(...),
    confirm: str = Form(...),
    session: Session = Depends(get_session),
) -> RedirectResponse:
    customer = session.scalar(select(Customer).where(Customer.invite_token == token))
    if customer is None or not customer.invite_is_live:
        return back(error="That invitation has expired or has already been used.")
    if password != confirm:
        return back(f"/apps/license/invite/{token}", error="Those two passwords don't match.")
    if len(password) < MIN_PASSWORD_LENGTH:
        return back(
            f"/apps/license/invite/{token}",
            error=f"Choose a password of at least {MIN_PASSWORD_LENGTH} characters.",
        )

    customer.password_hash = hash_password(password)
    # Burn the invite: one use, and it cannot be replayed even from a leaked email.
    customer.invite_token = None
    customer.invite_expires_at = None
    session.commit()

    request.session[CUSTOMER_SESSION_KEY] = customer.id
    return back(flash="Your account is ready.")
