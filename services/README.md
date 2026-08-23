# Redact API + admin portal

Two faces of one FastAPI process:

| Path      | What it is                                                    | Auth                        |
|-----------|---------------------------------------------------------------|-----------------------------|
| `/v1/*`   | Hosted redaction API for third-party developers               | `Authorization: Bearer rdk_…` |
| `/admin/*`| Admin portal — issue keys, assign them, set how long they live | Session cookie              |
| `/docs`   | Generated OpenAPI reference                                    | —                           |

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
.venv/bin/python test_portal.py   # 45 checks: auth, issuance, assignment, expiry, quota
.venv/bin/python test_engine.py   # 34 checks: compositing, masks, bounds, strength
```

`test_engine.py` stubs the detector, so both suites run without ultralytics or torch installed.
Real inference needs `pip install ultralytics`, which pulls torch (~2 GB); the weights named by
`REDACT_MODEL` download on the first redaction call.
