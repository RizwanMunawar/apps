"""Engine, session factory, and first-boot seeding."""
from __future__ import annotations

from collections.abc import Iterator

from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session, sessionmaker

from . import config
from .models import Admin, Base
from .security import hash_password

_connect_args = {"check_same_thread": False} if config.DATABASE_URL.startswith("sqlite") else {}
engine = create_engine(config.DATABASE_URL, connect_args=_connect_args, future=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def get_session() -> Iterator[Session]:
    """FastAPI dependency: one session per request, always closed."""
    session = SessionLocal()
    try:
        yield session
    finally:
        session.close()


def init_db() -> None:
    """Create tables, and seed the first admin so the portal is reachable on a fresh install."""
    Base.metadata.create_all(engine)

    if not (config.ADMIN_EMAIL and config.ADMIN_PASSWORD):
        return

    with SessionLocal() as session:
        if session.scalar(select(Admin).limit(1)) is not None:
            return  # An admin already exists; never silently reset their password.
        session.add(
            Admin(
                email=config.ADMIN_EMAIL.strip().lower(),
                password_hash=hash_password(config.ADMIN_PASSWORD),
            )
        )
        session.commit()
        print(f"[redactapi] seeded first admin: {config.ADMIN_EMAIL}")
