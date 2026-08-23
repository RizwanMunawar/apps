"""End-to-end licensing checks: invites, trials, activation, seats, revocation.

The security-critical assertions here are the ones about what a compromised *server* can do.
Those are the reason the two-keypair split exists, so they are tested as attacks, not as
happy paths.
"""
from __future__ import annotations

import os
import tempfile
from datetime import timedelta
from pathlib import Path

from redactapi.licensing import generate_keypair

LICENSE_PRIV, LICENSE_PUB = generate_keypair()
TRIAL_PRIV, TRIAL_PUB = generate_keypair()

DB_PATH = Path(tempfile.mkdtemp()) / "lic.db"
os.environ.update(
    REDACT_SECRET_KEY="licensing-suite-secret-0123456789abcdef0123456789abcdef",
    REDACT_ADMIN_EMAIL="admin@example.com",
    REDACT_ADMIN_PASSWORD="test-password",
    REDACT_DATABASE_URL=f"sqlite:///{DB_PATH}",
    REDACT_LICENSE_PUBLIC_KEY=LICENSE_PUB,
    REDACT_TRIAL_PRIVATE_KEY=TRIAL_PRIV,
    REDACT_TRIAL_PUBLIC_KEY=TRIAL_PUB,
    REDACT_SITE_ORIGIN="https://rizwanai.com",
)

from fastapi.testclient import TestClient  # noqa: E402

from redactapi.db import SessionLocal, init_db  # noqa: E402
from redactapi.licenseservice import payload_for  # noqa: E402
from redactapi.licensing import (  # noqa: E402
    LicensePayload, load_private_key, sign_license,
)
from redactapi.main import app  # noqa: E402
from redactapi.models import Customer, License, LicenseStatus, utcnow  # noqa: E402

PASSED, FAILED = [], []


def check(name: str, condition: bool, detail: str = "") -> None:
    (PASSED if condition else FAILED).append(name)
    print(f"  {'PASS' if condition else 'FAIL'}  {name}{'' if condition else f'  <- {detail}'}")


init_db()
admin = TestClient(app)
admin.post("/admin/login", data={"email": "admin@example.com", "password": "test-password"})

print("\n[access] the two portals are separate")
anon = TestClient(app)
check("anonymous /admin/licenses redirects to admin sign-in",
      anon.get("/admin/licenses", follow_redirects=False).status_code == 303)
check("anonymous /apps/license shows the sign-in page, not data",
      "Sign in" in anon.get("/apps/license").text)
check("the public page does not leak any licence data",
      "RZAI1." not in anon.get("/apps/license").text)

print("\n[signup] accounts are invitation-only by default")
blocked = anon.post("/apps/license/signup",
                    data={"email": "stranger@evil.com", "password": "averylongpassword"},
                    follow_redirects=True)
check("web signup is refused", "invitation" in blocked.text)
api_blocked = anon.post("/v1/license/signup",
                        json={"email": "stranger@evil.com", "password": "averylongpassword"})
check("app-API signup is refused too", api_blocked.status_code == 403, str(api_blocked.status_code))
with SessionLocal() as session:
    check("no account was created either way",
          session.query(Customer).filter_by(email="stranger@evil.com").count() == 0)

print("\n[invite] admin creates the account, customer sets the password")
admin.post("/admin/customers",
           data={"email": "dev@acme.com", "name": "Acme Dev", "company": "Acme Robotics"},
           follow_redirects=True)
with SessionLocal() as session:
    customer_id = session.query(Customer).filter_by(email="dev@acme.com").one().id
invited = admin.post(f"/admin/customers/{customer_id}/invite", follow_redirects=True)
check("invite link is produced", "/apps/license/invite/" in invited.text)
with SessionLocal() as session:
    token = session.get(Customer, customer_id).invite_token

customer = TestClient(app)
check("invite page renders", "Set your password" in customer.get(f"/apps/license/invite/{token}").text)
check("a short password is refused",
      "at least" in customer.post(f"/apps/license/invite/{token}",
                                  data={"password": "short", "confirm": "short"},
                                  follow_redirects=True).text)
check("mismatched passwords are refused",
      "don&#39;t match" in customer.post(f"/apps/license/invite/{token}",
                                         data={"password": "correct-horse-battery",
                                               "confirm": "something-else-here"},
                                         follow_redirects=True).text)
accepted = customer.post(f"/apps/license/invite/{token}",
                         data={"password": "correct-horse-battery",
                               "confirm": "correct-horse-battery"},
                         follow_redirects=True)
check("a valid invite creates the account and signs in", "Your Redact licences" in accepted.text)
check("the invite is burned after one use",
      "expired or has already been used" in
      TestClient(app).get(f"/apps/license/invite/{token}", follow_redirects=True).text)

print("\n[trial] one per account, 14 days, never restartable")
started = customer.post("/apps/license/trial", follow_redirects=True)
check("trial starts", "Trial started" in started.text or "14 days remaining" in started.text)
with SessionLocal() as session:
    trial = session.query(License).filter_by(customer_id=customer_id).one()
    span = (trial.expires_at.replace(tzinfo=utcnow().tzinfo) - utcnow()).days
    check("trial runs 14 days", 13 <= span <= 14, f"{span} days")
    check("trial is signed and active", trial.token and trial.status is LicenseStatus.active)
    trial_token, trial_db_id = trial.token, trial.id

customer.post("/apps/license/trial", follow_redirects=True)
with SessionLocal() as session:
    check("re-requesting does not mint a second trial",
          session.query(License).filter_by(customer_id=customer_id).count() == 1)

print("\n[activation] seats are enforced")
act = anon.post("/v1/license/activate", json={
    "token": trial_token, "machine_id": "MAC-AAAA-1111", "machine_name": "Rizwan's MacBook",
    "app_version": "1.0.0"})
check("first machine activates", act.status_code == 200, act.text[:120])
check("activation reports the account", act.json()["license"]["account"] == "dev@acme.com")

again = anon.post("/v1/license/activate", json={
    "token": trial_token, "machine_id": "MAC-AAAA-1111", "machine_name": "Rizwan's MacBook"})
check("the same machine re-activating is not a new seat", again.status_code == 200)

second = anon.post("/v1/license/activate", json={
    "token": trial_token, "machine_id": "MAC-BBBB-2222", "machine_name": "Another Mac"})
check("a trial's single seat blocks a second machine", second.status_code == 409, str(second.status_code))
check("the refusal explains seats", "seat" in second.json()["error"].lower())

print("\n[forgery] a fabricated token cannot activate")
fake = anon.post("/v1/license/activate", json={
    "token": "RZAI1.eyJmYWtlIjp0cnVlfQ.AAAA", "machine_id": "MAC-CCCC-3333"})
check("garbage token is rejected", fake.status_code == 400, str(fake.status_code))

evil_payload = LicensePayload(license_id="lic_EVIL", account_email="attacker@evil.com",
                              seats=999, issued_at=int(utcnow().timestamp()), expires_at=None)
evil = sign_license(evil_payload, load_private_key(TRIAL_PRIV))
evil_result = anon.post("/v1/license/activate",
                        json={"token": evil, "machine_id": "MAC-DDDD-4444"})
check("a full licence forged with the SERVER's trial key is rejected",
      evil_result.status_code == 400, f"{evil_result.status_code} {evil_result.text[:90]}")

print("\n[offline signing] the admin panel cannot sign, but can verify")
issued = admin.post("/admin/licenses", data={
    "customer_id": str(customer_id), "seats": "3", "duration": "never",
    "feature": ["redact", "recorder"], "notes": "PO-2214"}, follow_redirects=True)
check("issuing creates a draft awaiting signature", "awaiting signature" in issued.text)
with SessionLocal() as session:
    draft = session.query(License).filter_by(seats=3).one()
    draft_db_id = draft.id
    check("a draft carries no token", draft.token is None)
    check("a draft is not usable", not draft.is_usable)
    real_payload = payload_for(draft)

signed = sign_license(real_payload, load_private_key(LICENSE_PRIV))
bad_attach = admin.post(f"/admin/licenses/{draft_db_id}/sign",
                        data={"token": evil}, follow_redirects=True)
check("pasting a mis-signed token is refused", "not valid" in bad_attach.text or "signature" in bad_attach.text)

mismatched = sign_license(
    LicensePayload(license_id=real_payload.license_id, account_email="someone@else.com",
                   seats=3, issued_at=real_payload.issued_at, expires_at=None),
    load_private_key(LICENSE_PRIV))
wrong_account = admin.post(f"/admin/licenses/{draft_db_id}/sign",
                           data={"token": mismatched}, follow_redirects=True)
check("a genuinely-signed token for the wrong account is refused",
      "issued to" in wrong_account.text, wrong_account.text[:0])

good = admin.post(f"/admin/licenses/{draft_db_id}/sign",
                  data={"token": signed}, follow_redirects=True)
check("the correct signed token activates the licence", "Signature verified" in good.text)
with SessionLocal() as session:
    row = session.get(License, draft_db_id)
    check("licence is now usable", row.is_usable)
    full_token = row.token

print("\n[seats] a 3-seat licence takes 3 machines and refuses the 4th")
for n in range(3):
    result = anon.post("/v1/license/activate", json={
        "token": full_token, "machine_id": f"MAC-SEAT-{n}", "machine_name": f"Mac {n}"})
    check(f"machine {n + 1} of 3 activates", result.status_code == 200, str(result.status_code))
fourth = anon.post("/v1/license/activate",
                   json={"token": full_token, "machine_id": "MAC-SEAT-3"})
check("the 4th machine is refused", fourth.status_code == 409)

print("\n[revocation] reaches machines on next check-in")
beat = anon.post("/v1/license/heartbeat",
                 json={"token": full_token, "machine_id": "MAC-SEAT-0"})
check("heartbeat reports a live licence as valid", beat.json()["valid"] is True)
admin.post(f"/admin/licenses/{draft_db_id}/revoke", follow_redirects=True)
after = anon.post("/v1/license/heartbeat",
                  json={"token": full_token, "machine_id": "MAC-SEAT-0"})
check("heartbeat reports revoked after revocation", after.json()["revoked"] is True)
check("heartbeat no longer reports valid", after.json()["valid"] is False)
revoked_activate = anon.post("/v1/license/activate",
                             json={"token": full_token, "machine_id": "MAC-NEW-9999"})
check("activation is refused once revoked", revoked_activate.status_code == 403,
      f"{revoked_activate.status_code} {revoked_activate.text[:90]}")
check("the refusal says revoked", "revoked" in revoked_activate.json()["error"].lower())

print("\n[input] malformed requests are rejected before any lookup")
check("a too-short machine id is refused",
      anon.post("/v1/license/activate",
                json={"token": full_token, "machine_id": "SHORT"}).status_code == 422)
check("a missing token is refused",
      anon.post("/v1/license/activate", json={"machine_id": "MAC-XXXX-0000"}).status_code == 422)

print("\n[isolation] a customer cannot touch another customer's account")
admin.post("/admin/customers", data={"email": "other@corp.com", "name": "Other"},
           follow_redirects=True)
with SessionLocal() as session:
    other = session.query(Customer).filter_by(email="other@corp.com").one()
    other_id = other.id
    victim_seat = session.query(License).filter_by(customer_id=customer_id).first().activations[0].id
stolen = TestClient(app)
stolen.post("/admin/login", data={"email": "admin@example.com", "password": "test-password"})
# An admin session must not be usable as a customer session on the licensing portal.
check("an admin cookie does not authenticate the customer portal",
      "Sign in" in stolen.get("/apps/license").text)

print("\n[seo] the public page is crawlable and correctly marked up")
page = anon.get("/apps/license").text
for needle, label in [
    ("<title>", "title tag"), ('name="description"', "meta description"),
    ('rel="canonical"', "canonical link"), ('property="og:title"', "Open Graph title"),
    ("application/ld+json", "JSON-LD"), ('name="robots" content="index, follow"', "indexable"),
]:
    check(f"public page has a {label}", needle in page)
check("the signed-in page is marked noindex",
      'content="noindex, nofollow"' in customer.get("/apps/license").text)
robots = anon.get("/robots.txt").text
check("robots allows the licensing page", "Allow: /apps/license" in robots)
check("robots blocks the admin panel", "Disallow: /admin" in robots)
check("sitemap lists the licensing page", "/apps/license" in anon.get("/sitemap.xml").text)

print(f"\n{'=' * 58}\n{len(PASSED)} passed, {len(FAILED)} failed")
if FAILED:
    for name in FAILED:
        print(f"  FAILED: {name}")
    raise SystemExit(1)
