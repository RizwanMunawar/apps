"""Entry point. One process serves both the public API and the admin portal.

    /v1/*      key-authenticated redaction API
    /admin/*   session-authenticated admin portal
"""
from __future__ import annotations

from fastapi import FastAPI, HTTPException, Request, status
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from starlette.middleware.sessions import SessionMiddleware

from . import config
from .api.routes import router as api_router
from .db import init_db
from .portal.routes import router as portal_router

app = FastAPI(
    title="Redact API",
    description="Hosted object redaction, and the admin portal that issues its keys.",
    version="1.0.0",
)

app.add_middleware(
    SessionMiddleware,
    secret_key=config.require_secret_key(),
    session_cookie="redact_admin",
    https_only=False,  # Flip to True once the portal is behind TLS.
    same_site="lax",
)

app.mount("/static", StaticFiles(directory=str(config.BASE_DIR / "static")), name="static")
app.include_router(api_router)
app.include_router(portal_router)


@app.on_event("startup")
def startup() -> None:
    init_db()


@app.exception_handler(HTTPException)
async def handle_http_exception(request: Request, exc: HTTPException):
    """Portal pages redirect to sign-in; API routes keep returning JSON."""
    if exc.status_code == status.HTTP_401_UNAUTHORIZED and request.url.path.startswith("/admin"):
        return RedirectResponse("/admin/login", status_code=status.HTTP_303_SEE_OTHER)
    return JSONResponse(
        {"error": exc.detail}, status_code=exc.status_code, headers=exc.headers
    )


@app.get("/healthz", include_in_schema=False)
def healthz() -> dict:
    return {"status": "ok"}


@app.get("/", include_in_schema=False)
def root() -> RedirectResponse:
    return RedirectResponse("/admin")
