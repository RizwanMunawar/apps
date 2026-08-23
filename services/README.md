# Redact API + admin portal

Two faces of one FastAPI process:

| Path             | What it is                                                     | Auth                          |
|------------------|----------------------------------------------------------------|-------------------------------|
| `/v1/*`          | Hosted redaction API for third-party developers                | `Authorization: Bearer rdk_…` |
| `/v1/license/*`  | The Mac app's licensing channel — trials, activation, heartbeat | Account credentials or token  |
| `/admin/*`       | Admin portal — API keys **and** app licences                   | Admin session cookie          |
| `/apps/license`  | Customer licensing portal                                      | Customer session cookie       |
| `/docs`          | Generated OpenAPI reference                                    | —                             |

The macOS app in this repo is unchanged and still fully offline. This service is the separate,
hosted product: the same detect-and-blur pipeline, reachable over HTTP, gated by keys you issue.

## Run it

```bash
cd services
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
cp .env.example .env          # then edit it — see below
./run.sh                      # http://127.0.0.1:8000/admin
```

Two values in `.env` must be set before first boot:

- `REDACT_SECRET_KEY` — signs admin session cookies. `python3 -c "import secrets; print(secrets.token_hex(32))"`
- `REDACT_ADMIN_PASSWORD` — the first admin account's password.

The first admin is seeded only when the table is empty, so restarting never resets a password
you have changed. SQLite is the default; point `REDACT_DATABASE_URL` at Postgres for production.

## The portal

**Overview** — active/unassigned/expired key counts, what expires in the next 14 days, calls this
month, recent issuance and traffic.

**Accounts** — who keys belong to. Accounts never sign in here; they only hold keys. Suspending an
account blocks every key on it immediately.

**API keys** — the page that does the work:

- *Generate* with a label, an account (or leave it unassigned), live/test, an expiry, a monthly
  quota, and whether video is allowed.
- *Assign* by picking an account in the row's dropdown. Moving a key between accounts, or
  detaching it, takes effect on the next request.
- *Expiry* — 7 / 30 / 90 days, 6 months, 1 year, never, or a custom UTC datetime. Changeable
  after the fact from the row's "Change expiry…" dropdown.
- *Rotate* issues a fresh secret in place, keeping the account, quota and expiry. The old secret
  dies instantly — rotation usually means it leaked.
- *Revoke* kills a key permanently.

**Usage** — the last 200 calls with endpoint, key, status, duration and payload size.

## Key handling

A key is `rdk_live_…` or `rdk_test_…` followed by 40 URL-safe characters (~240 bits). Only its
SHA-256 hash is stored, alongside a prefix and last four characters for display. The plaintext is
shown exactly once, at creation, and cannot be recovered — lose it and you rotate.

Auth failures are deliberately distinct so a caller can tell what went wrong:

| Condition                   | Status |
|-----------------------------|--------|
| No or malformed header      | 401    |
| Unknown key                 | 401    |
| Revoked                     | 403    |
| Expired                     | 403    |
| Not assigned to an account  | 403    |
| Account suspended           | 403    |
| Monthly quota exhausted     | 429    |

Only successful calls (`status < 400`) count against quota.

## The API

```bash
curl -X POST http://127.0.0.1:8000/v1/redact/image \
  -H "Authorization: Bearer rdk_live_…" \
  -F "file=@photo.jpg" \
  -F "classes=0" \
  -F "style=pixelate" \
  -F "method=box" \
  -F "strength=25" \
  -o redacted.png
```

| Field      | Values                        | Mirrors                              |
|------------|-------------------------------|--------------------------------------|
| `classes`  | comma-separated class indices | `MediaBlurSettings.selectedClasses`  |
| `style`    | `pixelate` \| `gaussian`      | `BlurStyle`                          |
| `method`   | `box` \| `mask`               | `BlurMethod`                         |
| `strength` | 4–60 (default 25)             | the app's strength slider            |
| `tracking` | video only, default true      | `FastTracker`                        |

`GET /v1/me` returns the key's account, expiry and remaining quota. `GET /v1/models` lists the
class indices `classes` accepts. `POST /v1/redact/video` returns an MP4 — **without audio**: the
macOS app muxes the original track back in, which needs ffmpeg and is not wired up here.

## Tests

```bash
.venv/bin/python test_portal.py     # 45 checks: auth, issuance, assignment, expiry, quota
.venv/bin/python test_engine.py     # 34 checks: compositing, masks, bounds, strength
.venv/bin/python test_licensing.py  # 52 checks: invites, trials, seats, forgery, revocation, SEO
```

The Swift verifier is checked against the Python signer separately, because both sides have to
agree on the exact bytes that were signed:

```bash
swift run redact-selfcheck   # with REDACT_TEST_* tokens exported by the Python side
```

`test_engine.py` stubs the detector, so both suites run without ultralytics or torch installed.
Real inference needs `pip install ultralytics`, which pulls torch (~2 GB); the weights named by
`REDACT_MODEL` download on the first redaction call.


---

# App licensing

Separate from the API keys above. API keys gate the *hosted API*; licences gate the *Mac app*.
They share accounts and the admin panel and nothing else.

## The two-keypair split

The requirement was that someone who gets into the admin panel still cannot mint a licence. That
rules out keeping a signing key on the server, so there are two keypairs with deliberately
different powers:

| Keypair     | Private half lives    | Can sign        | If stolen                          |
|-------------|-----------------------|-----------------|------------------------------------|
| **Licence** | Only on your Mac      | Full licences   | Total compromise — guard this file |
| **Trial**   | On the server (`.env`)| Trials only     | An attacker gets a 14-day trial    |

Anything signed by the trial key is capped at 14 days *by the verifier*, on both the server and
in the app, and is refused outright if it claims to be a full licence. So a fully compromised
backend yields nothing better than the trial anyone could have asked for.

Set them up once:

```bash
python3 -m redactapi.licensetool keygen           # licence keypair — private stays on your Mac
python3 -m redactapi.licensetool keygen --trial   # trial keypair — private goes in .env
```

Put both public keys in `services/.env`, and both into `LicenseVerifier` in
`Shared/Licensing/LicenseToken.swift`. **A build with empty keys does not enforce licensing at
all** — it fails open rather than bricking the app on a packaging slip. Catch that in your
release script:

```bash
REDACT_REQUIRE_LICENSE_KEYS=1 swift run redact-selfcheck
```

## Issuing a licence

The admin panel never signs. Issuing records a *draft*:

1. **Admin → App licenses → Issue** — pick the account, seats, expiry, features.
2. The draft page shows a command. Run it on your own Mac:
   `python3 -m redactapi.licensetool sign --draft <draft>`
3. Paste the signed token back. It is verified against the public key — signature, licence id,
   account and seat count all have to match — before it is stored.

A draft unlocks nothing. Someone who owns the admin panel can create drafts all day and not one
of them will start the app.

## Trials

Fourteen days, one per account, ever. Re-requesting returns the same token, expired or not.
Because a trial needs an account and accounts are invitation-only by default
(`REDACT_OPEN_SIGNUP=0`), there is no self-serve path to a second trial.

In the app, the trial is also defended against the obvious local attack: the Keychain holds a
watermark of the latest date ever seen, so winding the clock back shows up as time running
backwards and blocks the app rather than reviving an expired trial. Tolerance is 6 hours, so
timezone changes and NTP corrections are not mistaken for tampering. Storing the token in the
Keychain also means deleting and reinstalling the app does not reset a used trial.

## Accounts

Invitation-only unless you set `REDACT_OPEN_SIGNUP=1`. The admin creates the account and presses
**Create invite link**; the customer sets their own password through that link, which works once
and expires after 7 days. You never see their password.

Customers and admins are different tables with different session cookies, so a customer session
can never be escalated into an admin one.

## Revocation

The app verifies offline, so revocation only bites when the machine next reaches
`/v1/license/heartbeat`. That is the deliberate trade for an app that keeps working on a plane.
The heartbeat can only ever *remove* access, never grant it, so a spoofed service cannot unlock
anything.

## What is not built

- **Payments/billing.** Licences are issued by hand after you agree a deal.
- **Email delivery.** Invite links are shown in the panel for you to send yourself.
- **Seat transfer self-service** beyond releasing a machine.
