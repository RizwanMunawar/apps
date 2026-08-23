"""Offline license signing CLI. Run this on your own machine — never on the server.

This is the only code that ever touches the private signing key. The web service imports
`licensing` for verification but has no path to `sign_license`, so a full server compromise
still cannot produce a license the app will accept.

    # Once, to create the keypair:
    python3 -m redactapi.licensetool keygen

    # For each license: copy the draft from the admin panel, then
    python3 -m redactapi.licensetool sign --draft <draft-string>

    # Paste the printed token back into the panel.
"""
from __future__ import annotations

import argparse
import json
import os
import stat
import sys
from pathlib import Path

from .licensing import (
    LicenseError, LicensePayload, generate_keypair, load_private_key, load_public_key,
    sign_license, verify_license,
)

DEFAULT_KEY_PATH = Path.home() / ".rizwanai" / "license-signing.key"
DEFAULT_TRIAL_KEY_PATH = Path.home() / ".rizwanai" / "trial-signing.key"


def _read_private_key(path: Path):
    if not path.exists():
        sys.exit(
            f"No signing key at {path}.\n"
            f"Run `python3 -m redactapi.licensetool keygen` first, or pass --key."
        )
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        print(
            f"warning: {path} is readable by other users (mode {mode:o}). "
            f"Run: chmod 600 {path}",
            file=sys.stderr,
        )
    return load_private_key(path.read_text())


def cmd_keygen(args: argparse.Namespace) -> None:
    default = DEFAULT_TRIAL_KEY_PATH if args.trial else DEFAULT_KEY_PATH
    path = Path(args.key or default)
    if path.exists() and not args.force:
        sys.exit(
            f"A signing key already exists at {path}.\n"
            f"Refusing to overwrite it — every license ever issued was signed with it, and\n"
            f"replacing it would invalidate all of them. Pass --force only if you are certain."
        )

    private_b64, public_b64 = generate_keypair()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(private_b64 + "\n")
    os.chmod(path, 0o600)

    print(f"Private signing key written to {path} (mode 600).")

    if args.trial:
        # The trial key is meant to live on the server, so print both halves.
        print("\nThis is the TRIAL key. Its private half belongs in services/.env, because")
        print("trials must issue automatically. Anything it signs is capped at 14 days.\n")
        print(f"  REDACT_TRIAL_PRIVATE_KEY={private_b64}")
        print(f"  REDACT_TRIAL_PUBLIC_KEY={public_b64}\n")
        return

    print("\nBack this file up somewhere offline. If you lose it you cannot issue or renew")
    print("any license, and if it leaks anyone can mint licenses for your app.")
    print("Never copy it to the server — keeping it off there is the whole point.\n")
    print("Put this public key in services/.env as REDACT_LICENSE_PUBLIC_KEY, and in the Mac")
    print("app as LicenseVerifier.licensePublicKey:\n")
    print(f"  {public_b64}\n")


def cmd_sign(args: argparse.Namespace) -> None:
    private_key = _read_private_key(Path(args.key or DEFAULT_KEY_PATH))

    if args.draft:
        try:
            payload = LicensePayload.from_dict(json.loads(_decode(args.draft)))
        except (ValueError, KeyError) as error:
            sys.exit(f"That draft could not be read: {error}")
    elif args.payload_file:
        payload = LicensePayload.from_dict(json.loads(Path(args.payload_file).read_text()))
    else:
        sys.exit("Pass --draft (copied from the admin panel) or --payload-file.")

    token = sign_license(payload, private_key)

    print(f"\nLicense for {payload.account_email}", file=sys.stderr)
    print(f"  id      {payload.license_id}", file=sys.stderr)
    print(f"  seats   {payload.seats}", file=sys.stderr)
    expiry = payload.expires_datetime
    print(f"  expires {expiry:%Y-%m-%d %H:%M UTC}" if expiry else "  expires never",
          file=sys.stderr)
    print("\nPaste this back into the admin panel:\n", file=sys.stderr)
    print(token)


def cmd_verify(args: argparse.Namespace) -> None:
    public_b64 = args.public or os.environ.get("REDACT_LICENSE_PUBLIC_KEY", "")
    if not public_b64:
        sys.exit("Pass --public or set REDACT_LICENSE_PUBLIC_KEY.")
    try:
        payload = verify_license(args.token, load_public_key(public_b64))
    except LicenseError as error:
        sys.exit(f"INVALID: {error}")

    expiry = payload.expires_datetime
    print("VALID")
    print(f"  id      {payload.license_id}")
    print(f"  account {payload.account_email} ({payload.account_name})")
    print(f"  seats   {payload.seats}")
    print(f"  expires {expiry:%Y-%m-%d %H:%M UTC}" if expiry else "  expires never")
    print(f"  expired {'yes' if payload.is_expired() else 'no'}")


def _decode(draft: str) -> str:
    """Drafts are base64url so a copy-paste can't be mangled by whitespace or quoting."""
    import base64

    cleaned = "".join(draft.split())
    return base64.urlsafe_b64decode(cleaned + "=" * (-len(cleaned) % 4)).decode()


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="licensetool", description="Sign RizwanAI app licenses offline."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    keygen = sub.add_parser("keygen", help="create the signing keypair (run once)")
    keygen.add_argument("--key", help=f"where to write the private key (default {DEFAULT_KEY_PATH})")
    keygen.add_argument("--force", action="store_true", help="overwrite an existing key")
    keygen.add_argument("--trial", action="store_true",
                        help="generate the weaker trial keypair that lives on the server")
    keygen.set_defaults(func=cmd_keygen)

    sign = sub.add_parser("sign", help="sign a draft copied from the admin panel")
    sign.add_argument("--draft", help="the draft string shown in the admin panel")
    sign.add_argument("--payload-file", help="a JSON payload file, instead of --draft")
    sign.add_argument("--key", help="path to the private signing key")
    sign.set_defaults(func=cmd_sign)

    verify = sub.add_parser("verify", help="check a token against the public key")
    verify.add_argument("token")
    verify.add_argument("--public", help="public key (default: REDACT_LICENSE_PUBLIC_KEY)")
    verify.set_defaults(func=cmd_verify)

    args = parser.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
