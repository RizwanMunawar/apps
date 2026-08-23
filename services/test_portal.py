"""End-to-end check of the portal and the key-auth path it feeds.

Runs against a throwaway SQLite file, so it never touches a real database.
"""
from __future__ import annotations

import os
import tempfile
from datetime import timedelta
from pathlib import Path

DB_PATH = Path(tempfile.mkdtemp()) / "test.db"
os.environ["REDACT_SECRET_KEY"] = "test-secret-key-for-the-suite-only-0123456789abcdef"
os.environ["REDACT_ADMIN_EMAIL"] = "admin@example.com"
os.environ["REDACT_ADMIN_PASSWORD"] = "test-password"
os.environ["REDACT_DATABASE_URL"] = f"sqlite:///{DB_PATH}"

from fastapi.testclient import TestClient  # noqa: E402

from redactapi.db import SessionLocal, init_db  # noqa: E402
from redactapi.main import app  # noqa: E402
from redactapi.models import ApiKey, utcnow  # noqa: E402
from redactapi.portal.routes import resolve_expiry  # noqa: E402

PASSED, FAILED = [], []


def check(name: str, condition: bool, detail: str = "") -> None:
    (PASSED if condition else FAILED).append(name)
    print(f"  {'PASS' if condition else 'FAIL'}  {name}{'' if condition else f'  <- {detail}'}")


def secret_of(client: TestClient, response) -> str:
    """Pull the one-time secret out of the key-created page."""
    body = response.text
    start = body.index('id="secret">') + len('id="secret">')
    return body[start:body.index("<", start)].strip()


init_db()
client = TestClient(app)

print("\n[auth] portal requires sign-in")
anon = TestClient(app)
check("unauthenticated /admin/keys redirects to login",
      anon.get("/admin/keys", follow_redirects=False).status_code == 303)
bad_login = anon.post("/admin/login",
                      data={"email": "admin@example.com", "password": "nope"},
                      follow_redirects=False)
check("wrong password does not open a session",
      bad_login.status_code == 303 and "redact_admin" not in bad_login.cookies)
check("wrong password still cannot reach the portal",
      anon.get("/admin/keys", follow_redirects=False).status_code == 303)

print("\n[auth] sign in")
login = client.post("/admin/login",
                    data={"email": "admin@example.com", "password": "test-password"},
                    follow_redirects=False)
check("correct password signs in", login.status_code == 303)
check("dashboard renders", "Overview" in client.get("/admin").text)

print("\n[accounts] create")
client.post("/admin/customers",
            data={"email": "dev@acme.com", "name": "Acme Dev", "company": "Acme"},
            follow_redirects=True)
listing = client.get("/admin/customers").text
check("account appears in the list", "dev@acme.com" in listing)

with SessionLocal() as session:
    from redactapi.models import Customer
    customer = session.query(Customer).filter_by(email="dev@acme.com").one()
    customer_id = customer.id

print("\n[keys] generate with a duration")
created = client.post("/admin/keys", data={
    "label": "Production", "customer_id": str(customer_id), "environment": "live",
    "duration": "30", "monthly_quota": "3", "allow_video": "true",
}, follow_redirects=True)
check("secret is shown exactly once", 'id="secret">rdk_live_' in created.text)
live_secret = secret_of(client, created)
check("secret carries the live prefix", live_secret.startswith("rdk_live_"), live_secret[:20])

with SessionLocal() as session:
    key = session.query(ApiKey).filter_by(label="Production").one()
    delta = key.expires_at.replace(tzinfo=utcnow().tzinfo) - utcnow()
    check("30-day duration lands ~30 days out", 29 <= delta.days <= 30, f"{delta.days} days")
    check("plaintext secret is never stored",
          session.query(ApiKey).filter(ApiKey.key_hash == live_secret).count() == 0)
    key_id = key.id

print("\n[api] the key authenticates")
me = client.get("/v1/me", headers={"Authorization": f"Bearer {live_secret}"})
check("/v1/me returns 200", me.status_code == 200, me.text[:120])
check("/v1/me names the account", me.json()["account"]["email"] == "dev@acme.com")
check("/v1/me reports the quota", me.json()["quota"]["monthly_limit"] == 3)

print("\n[api] rejections are distinct")
check("no key -> 401", client.get("/v1/me").status_code == 401)
check("bad key -> 401",
      client.get("/v1/me", headers={"Authorization": "Bearer rdk_live_nonsense"}).status_code == 401)

print("\n[keys] unassigned keys do not authenticate")
unassigned = client.post("/admin/keys", data={
    "label": "Spare", "customer_id": "", "environment": "live", "duration": "never",
    "monthly_quota": "0",
}, follow_redirects=True)
spare_secret = secret_of(client, unassigned)
spare = client.get("/v1/me", headers={"Authorization": f"Bearer {spare_secret}"})
check("unassigned key -> 403", spare.status_code == 403, spare.text[:120])
check("403 explains why", "not assigned" in spare.json()["error"])

print("\n[keys] assign from the portal")
with SessionLocal() as session:
    spare_id = session.query(ApiKey).filter_by(label="Spare").one().id
client.post(f"/admin/keys/{spare_id}/assign",
            data={"customer_id": str(customer_id)}, follow_redirects=True)
check("assigned key now authenticates",
      client.get("/v1/me", headers={"Authorization": f"Bearer {spare_secret}"}).status_code == 200)

print("\n[keys] expiry is enforced")
with SessionLocal() as session:
    expired = session.get(ApiKey, spare_id)
    expired.expires_at = utcnow() - timedelta(days=1)
    session.commit()
result = client.get("/v1/me", headers={"Authorization": f"Bearer {spare_secret}"})
check("expired key -> 403", result.status_code == 403, result.text[:120])
check("403 says it expired", "expired on" in result.json()["error"])

print("\n[keys] expiry can be changed from the portal")
client.post(f"/admin/keys/{spare_id}/expiry", data={"duration": "90"}, follow_redirects=True)
check("extending revives the key",
      client.get("/v1/me", headers={"Authorization": f"Bearer {spare_secret}"}).status_code == 200)
client.post(f"/admin/keys/{spare_id}/expiry", data={"duration": "never"}, follow_redirects=True)
with SessionLocal() as session:
    check("'never' clears the expiry", session.get(ApiKey, spare_id).expires_at is None)

print("\n[keys] custom dates")
future = (utcnow() + timedelta(days=45)).strftime("%Y-%m-%dT%H:%M")
check("a future custom date parses", resolve_expiry("custom", future) is not None)
try:
    resolve_expiry("custom", (utcnow() - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M"))
    check("a past custom date is refused", False, "no error raised")
except ValueError as error:
    check("a past custom date is refused", "future" in str(error))

print("\n[keys] rotate")
rotated = client.post(f"/admin/keys/{key_id}/rotate", follow_redirects=True)
new_secret = secret_of(client, rotated)
check("rotation issues a different secret", new_secret != live_secret)
check("old secret stops working",
      client.get("/v1/me", headers={"Authorization": f"Bearer {live_secret}"}).status_code == 401)
check("new secret works",
      client.get("/v1/me", headers={"Authorization": f"Bearer {new_secret}"}).status_code == 200)

print("\n[keys] revoke")
client.post(f"/admin/keys/{key_id}/revoke", follow_redirects=True)
revoked = client.get("/v1/me", headers={"Authorization": f"Bearer {new_secret}"})
check("revoked key -> 403", revoked.status_code == 403)
check("403 says revoked", "revoked" in revoked.json()["error"])

print("\n[accounts] suspending blocks every key on the account")
client.post(f"/admin/customers/{customer_id}/status",
            data={"new_status": "suspended"}, follow_redirects=True)
suspended = client.get("/v1/me", headers={"Authorization": f"Bearer {spare_secret}"})
check("suspended account -> 403", suspended.status_code == 403)
check("403 says suspended", "suspended" in suspended.json()["error"])
client.post(f"/admin/customers/{customer_id}/status",
            data={"new_status": "active"}, follow_redirects=True)

print("\n[quota] monthly limit is enforced")
with SessionLocal() as session:
    quota_key = session.get(ApiKey, spare_id)
    quota_key.monthly_quota = 2
    session.commit()
from redactapi.auth import record_usage  # noqa: E402
with SessionLocal() as session:
    quota_key = session.get(ApiKey, spare_id)
    for _ in range(2):
        record_usage(session, quota_key, endpoint="redact/image",
                     status_code=200, duration_ms=10, bytes_in=100)
over = client.get("/v1/me", headers={"Authorization": f"Bearer {spare_secret}"})
check("over quota -> 429", over.status_code == 429, f"{over.status_code} {over.text[:90]}")
check("429 explains the quota", "quota" in over.json()["error"])

print("\n[portal] every page renders")
for path in ["/admin", "/admin/customers", f"/admin/customers/{customer_id}",
             "/admin/keys", "/admin/keys?status_filter=revoked", "/admin/usage"]:
    response = client.get(path)
    check(f"GET {path}", response.status_code == 200, str(response.status_code))
check("usage shows the recorded calls", "redact/image" in client.get("/admin/usage").text)

print("\n[engine] settings validation")
from redactapi.engine import BlurSettings  # noqa: E402
check("strength clamps to the app's 4-60 range", BlurSettings(strength=999).strength == 60.0)
check("strength clamps at the bottom", BlurSettings(strength=0).strength == 4.0)
for bad, field in [({"style": "swirl"}, "style"), ({"method": "blob"}, "method"),
                   ({"classes": set()}, "classes")]:
    try:
        BlurSettings(**bad)
        check(f"invalid {field} is refused", False, "no error raised")
    except ValueError:
        check(f"invalid {field} is refused", True)

print(f"\n{'=' * 58}\n{len(PASSED)} passed, {len(FAILED)} failed")
if FAILED:
    for name in FAILED:
        print(f"  FAILED: {name}")
    raise SystemExit(1)
