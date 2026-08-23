"""The admin portal: issue keys, assign them to accounts, set how long they live."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Form, Request, status
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.templating import Jinja2Templates
from sqlalchemy import desc, func, select
from sqlalchemy.orm import Session

from .. import config
from ..auth import SESSION_KEY, month_usage, require_admin
from ..config import BASE_DIR
from ..db import get_session
from ..models import (
    Admin, ApiKey, Customer, CustomerStatus, KeyEnvironment, UsageRecord, as_utc, utcnow,
)
from ..security import mint_key, verify_password

router = APIRouter(prefix="/admin", tags=["portal"])
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))

# What the "Expires" dropdown offers. `None` is the no-expiry option; `custom` reads the date field.
DURATION_CHOICES = [
    ("7", "7 days"),
    ("30", "30 days"),
    ("90", "90 days"),
    ("180", "6 months"),
    ("365", "1 year"),
    ("never", "Never expires"),
    ("custom", "Custom date…"),
]


def render(request: Request, template: str, **context) -> HTMLResponse:
    context.setdefault("brand", "RizwanAI Apps")
    context.setdefault("flash", request.query_params.get("flash"))
    context.setdefault("error", request.query_params.get("error"))
    return templates.TemplateResponse(request, template, context)


def redirect(path: str, flash: str | None = None, error: str | None = None) -> RedirectResponse:
    if flash:
        path += ("&" if "?" in path else "?") + f"flash={flash}"
    if error:
        path += ("&" if "?" in path else "?") + f"error={error}"
    return RedirectResponse(path, status_code=status.HTTP_303_SEE_OTHER)


def resolve_expiry(duration: str, custom_date: str) -> datetime | None:
    """Turn the form's duration choice into a concrete UTC instant, or None for 'never'."""
    if duration == "never":
        return None
    if duration == "custom":
        if not custom_date:
            raise ValueError("Pick a date for a custom expiry.")
        try:
            parsed = datetime.fromisoformat(custom_date)
        except ValueError:
            raise ValueError("That custom expiry date isn't a valid date.")
        parsed = parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
        if parsed <= utcnow():
            raise ValueError("A custom expiry has to be in the future.")
        return parsed
    try:
        days = int(duration)
    except ValueError:
        raise ValueError("That expiry duration isn't valid.")
    if days <= 0:
        raise ValueError("An expiry duration has to be at least one day.")
    return utcnow() + timedelta(days=days)


# --- Sign in -----------------------------------------------------------------------------

@router.get("/login", response_class=HTMLResponse)
def login_form(request: Request) -> HTMLResponse:
    return render(request, "login.html")


@router.post("/login")
def login(
    request: Request,
    email: str = Form(...),
    password: str = Form(...),
    session: Session = Depends(get_session),
) -> RedirectResponse:
    admin = session.scalar(select(Admin).where(Admin.email == email.strip().lower()))
    # Same message either way: never reveal whether an address has an account.
    if admin is None or not verify_password(password, admin.password_hash):
        return redirect("/admin/login", error="That email and password don't match.")

    admin.last_login_at = utcnow()
    session.commit()
    request.session[SESSION_KEY] = admin.id
    return redirect("/admin")


@router.post("/logout")
def logout(request: Request) -> RedirectResponse:
    request.session.clear()
    return redirect("/admin/login", flash="Signed out.")


# --- Dashboard ---------------------------------------------------------------------------

@router.get("", response_class=HTMLResponse)
@router.get("/", response_class=HTMLResponse)
def dashboard(
    request: Request,
    admin: Admin = Depends(require_admin),
    session: Session = Depends(get_session),
) -> HTMLResponse:
    keys = list(session.scalars(select(ApiKey).order_by(desc(ApiKey.created_at))))
    soon = utcnow() + timedelta(days=14)
    expiring = sorted(
        (k for k in keys if not k.is_revoked and k.expires_at and not k.is_expired
         and as_utc(k.expires_at) <= soon),
        key=lambda k: as_utc(k.expires_at),
    )
    calls_this_month = session.scalar(
        select(func.count(UsageRecord.id)).where(
            UsageRecord.at >= datetime(utcnow().year, utcnow().month, 1, tzinfo=timezone.utc)
        )
    ) or 0

    return render(
        request, "dashboard.html",
        admin=admin,
        customer_count=session.scalar(select(func.count(Customer.id))) or 0,
        active_keys=sum(1 for k in keys if k.status == "active"),
        unassigned_keys=sum(1 for k in keys if k.status == "unassigned"),
        expired_keys=sum(1 for k in keys if k.status == "expired"),
        calls_this_month=calls_this_month,
        expiring=expiring[:8],
        recent_keys=keys[:8],
        recent_usage=list(session.scalars(
            select(UsageRecord).order_by(desc(UsageRecord.at)).limit(12)
        )),
    )


# --- Accounts ----------------------------------------------------------------------------

@router.get("/customers", response_class=HTMLResponse)
def customers(
    request: Request,
    admin: Admin = Depends(require_admin),
    session: Session = Depends(get_session),
) -> HTMLResponse:
    return render(
        request, "customers.html", admin=admin,
        customers=list(session.scalars(select(Customer).order_by(Customer.created_at.desc()))),
    )


@router.post("/customers")
def create_customer(
    email: str = Form(...),
    name: str = Form(""),
    company: str = Form(""),
    admin: Admin = Depends(require_admin),
    session: Session = Depends(get_session),
) -> RedirectResponse:
    email = email.strip().lower()
    if session.scalar(select(Customer).where(Customer.email == email)):
        return redirect("/admin/customers", error=f"{email} already has an account.")

    customer = Customer(email=email, name=name.strip(), company=company.strip())
    session.add(customer)
    session.commit()
    return redirect(f"/admin/customers/{customer.id}", flash="Account created.")


@router.get("/customers/{customer_id}", response_class=HTMLResponse)
def customer_detail(
    request: Request,
    customer_id: int,
    admin: Admin = Depends(require_admin),
    session: Session = Depends(get_session),
) -> HTMLResponse:
    customer = session.get(Customer, customer_id)
    if customer is None:
        return redirect("/admin/customers", error="No such account.")

    return render(
        request, "customer_detail.html", admin=admin, customer=customer,
        durations=DURATION_CHOICES,
        usage_by_key={key.id: month_usage(session, key) for key in customer.keys},
    )


@router.post("/customers/{customer_id}/status")
def set_customer_status(
    customer_id: int,
    new_status: str = Form(...),
    admin: Admin = Depends(require_admin),
    session: Session = Depends(get_session),
) -> RedirectResponse:
    customer = session.get(Customer, customer_id)
    if customer is None:
        return redirect("/admin/customers", error="No such account.")

    customer.status = (
        CustomerStatus.suspended if new_status == "suspended" else CustomerStatus.active
    )
    session.commit()
    # Suspension bites immediately: require_api_key rejects every key on a suspended account.
    return redirect(f"/admin/customers/{customer_id}", flash=f"Account {customer.status.value}.")


# --- Keys --------------------------------------------------------------------------------

@router.get("/keys", response_class=HTMLResponse)
def keys(
    request: Request,
    status_filter: str = "",
    admin: Admin = Depends(require_admin),
    session: Session = Depends(get_session),
) -> HTMLResponse:
    all_keys = list(session.scalars(select(ApiKey).order_by(desc(ApiKey.created_at))))
    shown = [k for k in all_keys if k.status == status_filter] if status_filter else all_keys
    return render(
        request, "keys.html", admin=admin, keys=shown, status_filter=status_filter,
        customers=list(session.scalars(select(Customer).order_by(Customer.email))),
        durations=DURATION_CHOICES,
        usage_by_key={key.id: month_usage(session, key) for key in shown},
    )


@router.post("/keys")
def create_key(
    request: Request,
    label: str = Form(""),
    customer_id: str = Form(""),
    environment: str = Form("live"),
    duration: str = Form("365"),
    custom_date: str = Form(""),
    monthly_quota: int = Form(0),
    allow_video: bool = Form(False),
    admin: Admin = Depends(require_admin),
    session: Session = Depends(get_session),
) -> Response:
    """Mint a key. This is the only moment the secret exists in plaintext."""
    back = f"/admin/customers/{customer_id}" if customer_id else "/admin/keys"

    try:
        expires_at = resolve_expiry(duration, custom_date)
    except ValueError as error:
        return redirect(back, error=str(error))

    customer = session.get(Customer, int(customer_id)) if customer_id else None
    if customer_id and customer is None:
        return redirect(back, error="No such account.")

    env = KeyEnvironment.test if environment == "test" else KeyEnvironment.live
    prefix = config.KEY_PREFIX_TEST if env is KeyEnvironment.test else config.KEY_PREFIX_LIVE
    secret, key_hash, last4 = mint_key(prefix)

    key = ApiKey(
        label=label.strip() or "Untitled key",
        key_hash=key_hash,
        prefix=prefix,
        last4=last4,
        environment=env,
        customer_id=customer.id if customer else None,
        expires_at=expires_at,
        monthly_quota=max(0, monthly_quota),
        allow_video=allow_video,
        created_by=admin.email,
    )
    session.add(key)
    session.commit()

    # Shown once, on its own page, because it can never be recovered after this response.
    return render(request, "key_created.html", admin=admin, key=key, secret=secret, back=back,
                  base_url=str(request.base_url).rstrip("/"))


@router.post("/keys/{key_id}/assign")
def assign_key(
    key_id: int,
    customer_id: str = Form(""),
    admin: Admin = Depends(require_admin),
    session: Session = Depends(get_session),
) -> RedirectResponse:
    """Attach an existing key to an account, move it to a different one, or detach it."""
    key = session.get(ApiKey, key_id)
    if key is None:
        return redirect("/admin/keys", error="No such key.")

    if not customer_id:
        key.customer_id = None
        session.commit()
        return redirect("/admin/keys", flash="Key unassigned; it will stop working immediately.")

    customer = session.get(Customer, int(customer_id))
    if customer is None:
        return redirect("/admin/keys", error="No such account.")

    key.customer_id = customer.id
    session.commit()
    return redirect(f"/admin/customers/{customer.id}", flash=f"Key assigned to {customer.email}.")


@router.post("/keys/{key_id}/expiry")
def update_expiry(
    key_id: int,
    duration: str = Form(...),
    custom_date: str = Form(""),
    admin: Admin = Depends(require_admin),
    session: Session = Depends(get_session),
) -> RedirectResponse:
    """Extend, shorten, or lift the time limit on a key that already exists."""
    key = session.get(ApiKey, key_id)
    if key is None:
        return redirect("/admin/keys", error="No such key.")

    try:
        key.expires_at = resolve_expiry(duration, custom_date)
    except ValueError as error:
        return redirect("/admin/keys", error=str(error))

    session.commit()
    return redirect("/admin/keys", flash=f"Expiry updated — now expires {key.expires_label}.")


@router.post("/keys/{key_id}/revoke")
def revoke_key(
    key_id: int,
    admin: Admin = Depends(require_admin),
    session: Session = Depends(get_session),
) -> RedirectResponse:
    key = session.get(ApiKey, key_id)
    if key is None:
        return redirect("/admin/keys", error="No such key.")

    key.revoked_at = utcnow()
    session.commit()
    return redirect("/admin/keys", flash="Key revoked. It stops working on the next request.")


@router.post("/keys/{key_id}/rotate")
def rotate_key(
    request: Request,
    key_id: int,
    admin: Admin = Depends(require_admin),
    session: Session = Depends(get_session),
) -> Response:
    """Issue a fresh secret in place, keeping the key's account, quota and expiry.

    The old secret stops working the moment this commits — there is deliberately no grace period,
    since rotation usually means the old one leaked.
    """
    key = session.get(ApiKey, key_id)
    if key is None:
        return redirect("/admin/keys", error="No such key.")

    secret, key_hash, last4 = mint_key(key.prefix)
    key.key_hash = key_hash
    key.last4 = last4
    key.revoked_at = None
    session.commit()

    return render(
        request, "key_created.html", admin=admin, key=key, secret=secret,
        back="/admin/keys", rotated=True, base_url=str(request.base_url).rstrip("/"),
    )


@router.get("/usage", response_class=HTMLResponse)
def usage(
    request: Request,
    admin: Admin = Depends(require_admin),
    session: Session = Depends(get_session),
) -> HTMLResponse:
    return render(
        request, "usage.html", admin=admin,
        records=list(session.scalars(
            select(UsageRecord).order_by(desc(UsageRecord.at)).limit(200)
        )),
    )
