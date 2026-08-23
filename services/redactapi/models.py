"""Database schema: admins, customers, API keys, and per-request usage."""
from __future__ import annotations

import enum
from datetime import datetime, timezone

from sqlalchemy import Boolean, DateTime, Enum, ForeignKey, Integer, String, Text
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def as_utc(value: datetime | None) -> datetime | None:
    """SQLite hands back naive datetimes; re-stamp them UTC so comparisons never raise."""
    if value is None:
        return None
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


class Base(DeclarativeBase):
    pass


class KeyEnvironment(str, enum.Enum):
    live = "live"
    test = "test"


class CustomerStatus(str, enum.Enum):
    active = "active"
    suspended = "suspended"


class Admin(Base):
    """Someone who can sign in to the portal."""
    __tablename__ = "admins"

    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(320), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(255))
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    last_login_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)


class Customer(Base):
    """Someone keys get issued to. Not a portal login — they never sign in here."""
    __tablename__ = "customers"

    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(320), unique=True, index=True)
    name: Mapped[str] = mapped_column(String(200), default="")
    company: Mapped[str] = mapped_column(String(200), default="")
    status: Mapped[CustomerStatus] = mapped_column(
        Enum(CustomerStatus), default=CustomerStatus.active
    )
    notes: Mapped[str] = mapped_column(Text, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)

    keys: Mapped[list["ApiKey"]] = relationship(
        back_populates="customer", order_by="ApiKey.created_at.desc()"
    )

    @property
    def display_name(self) -> str:
        return self.name or self.email

    @property
    def active_key_count(self) -> int:
        return sum(1 for key in self.keys if key.is_usable)


class ApiKey(Base):
    """One issued key.

    The secret itself is never stored — only its SHA-256 hash, plus a prefix and last four
    characters so the portal can show `rdk_live_••••a1b2` next to the right row. That means a
    key is displayed exactly once, at creation, and is unrecoverable afterwards: lose it and you
    rotate rather than look it up.
    """
    __tablename__ = "api_keys"

    id: Mapped[int] = mapped_column(primary_key=True)
    label: Mapped[str] = mapped_column(String(200), default="")
    key_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    prefix: Mapped[str] = mapped_column(String(16))
    last4: Mapped[str] = mapped_column(String(8))
    environment: Mapped[KeyEnvironment] = mapped_column(
        Enum(KeyEnvironment), default=KeyEnvironment.live
    )

    # Null means the key exists but is not assigned to anyone yet — issue now, assign later.
    customer_id: Mapped[int | None] = mapped_column(
        ForeignKey("customers.id", ondelete="SET NULL"), nullable=True, index=True
    )
    customer: Mapped[Customer | None] = relationship(back_populates="keys")

    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    # Null means the key never expires.
    expires_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)

    request_count: Mapped[int] = mapped_column(Integer, default=0)
    # Requests allowed per calendar month. 0 means unlimited.
    monthly_quota: Mapped[int] = mapped_column(Integer, default=0)
    allow_video: Mapped[bool] = mapped_column(Boolean, default=True)

    created_by: Mapped[str] = mapped_column(String(320), default="")

    usage: Mapped[list["UsageRecord"]] = relationship(
        back_populates="key", cascade="all, delete-orphan"
    )

    @property
    def masked(self) -> str:
        return f"{self.prefix}_{'•' * 8}{self.last4}"

    @property
    def is_expired(self) -> bool:
        expires = as_utc(self.expires_at)
        return expires is not None and expires <= utcnow()

    @property
    def is_revoked(self) -> bool:
        return self.revoked_at is not None

    @property
    def is_usable(self) -> bool:
        return not self.is_revoked and not self.is_expired and self.customer_id is not None

    @property
    def status(self) -> str:
        """The single word the portal shows in the status column."""
        if self.is_revoked:
            return "revoked"
        if self.is_expired:
            return "expired"
        if self.customer_id is None:
            return "unassigned"
        if self.customer and self.customer.status is CustomerStatus.suspended:
            return "suspended"
        return "active"

    @property
    def expires_label(self) -> str:
        expires = as_utc(self.expires_at)
        if expires is None:
            return "Never"
        delta = expires - utcnow()
        if delta.total_seconds() <= 0:
            return "Expired"
        days = delta.days
        if days >= 1:
            return f"in {days} day{'s' if days != 1 else ''}"
        hours = int(delta.total_seconds() // 3600)
        if hours >= 1:
            return f"in {hours} hour{'s' if hours != 1 else ''}"
        return "in under an hour"


class UsageRecord(Base):
    """One API call. What the portal's usage view and the monthly quota are computed from."""
    __tablename__ = "usage_records"

    id: Mapped[int] = mapped_column(primary_key=True)
    api_key_id: Mapped[int] = mapped_column(
        ForeignKey("api_keys.id", ondelete="CASCADE"), index=True
    )
    key: Mapped[ApiKey] = relationship(back_populates="usage")

    at: Mapped[datetime] = mapped_column(DateTime, default=utcnow, index=True)
    endpoint: Mapped[str] = mapped_column(String(120))
    status_code: Mapped[int] = mapped_column(Integer)
    duration_ms: Mapped[int] = mapped_column(Integer, default=0)
    bytes_in: Mapped[int] = mapped_column(Integer, default=0)
    detections: Mapped[int] = mapped_column(Integer, default=0)
