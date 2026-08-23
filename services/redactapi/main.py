"""Entry point. One process serves both the public API and the admin portal.

    /v1/*             key-authenticated redaction API
    /v1/license/*     the Mac app's licensing channel (trials, activation, heartbeat)
    /admin/*          session-authenticated admin portal
    /apps/license     customer licensing portal, behind a customer login
"""
from __future__ import annotations

from fastapi import FastAPI, HTTPException, Request, status
from fastapi.responses import JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from starlette.middleware.sessions import SessionMiddleware

from . import config
from .api.license_routes import router as license_api_router
from .api.routes import router as api_router
from .customer.routes import router as customer_router
from .db import init_db
from .portal.licenses import router as admin_licenses_router
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
app.include_router(license_api_router)
app.include_router(portal_router)
app.include_router(admin_licenses_router)
app.include_router(customer_router)


@app.on_event("startup")
def startup() -> None:
    init_db()


@app.exception_handler(HTTPException)
async def handle_http_exception(request: Request, exc: HTTPException):
    """Portal pages redirect to sign-in; API routes keep returning JSON."""
    if exc.status_code == status.HTTP_401_UNAUTHORIZED:
        # Both portals answer an unauthenticated hit with their own sign-in page rather than a
        # JSON body, so a customer who bookmarks a deep link lands somewhere useful.
        if request.url.path.startswith("/admin"):
            return RedirectResponse("/admin/login", status_code=status.HTTP_303_SEE_OTHER)
        if request.url.path.startswith("/apps/license"):
            return RedirectResponse("/apps/license", status_code=status.HTTP_303_SEE_OTHER)
    return JSONResponse(
        {"error": exc.detail}, status_code=exc.status_code, headers=exc.headers
    )


@app.get("/healthz", include_in_schema=False)
def healthz() -> dict:
    return {"status": "ok"}


@app.get("/robots.txt", include_in_schema=False)
def robots() -> Response:
    """Let the licensing sign-in page be indexed; keep crawlers out of both control planes."""
    body = (
        "User-agent: *\n"
        "Allow: /apps/license\n"
        "Disallow: /admin\n"
        "Disallow: /v1\n"
        f"\nSitemap: {config.SITE_ORIGIN}/sitemap.xml\n"
    )
    return Response(body, media_type="text/plain")


@app.get("/sitemap.xml", include_in_schema=False)
def sitemap() -> Response:
    body = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        f"  <url><loc>{config.SITE_ORIGIN}/apps/license</loc>"
        "<changefreq>monthly</changefreq><priority>0.6</priority></url>\n"
        "</urlset>\n"
    )
    return Response(body, media_type="application/xml")


@app.get("/", include_in_schema=False)
def root() -> RedirectResponse:
    return RedirectResponse("/admin")
