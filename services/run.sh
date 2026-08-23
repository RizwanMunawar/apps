#!/usr/bin/env bash
# Start the API and admin portal. Portal: http://127.0.0.1:8000/admin
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "No services/.env found. Copy .env.example to .env and fill it in first." >&2
  exit 1
fi

exec python3 -m uvicorn redactapi.main:app --host 127.0.0.1 --port 8000 --reload
