"""Erzeugt einen Hash für ``AWC_ADMIN_PASSWORD_HASH``.

Aufruf: ``python -m app.utils.hash_password`` (Passwort wird verdeckt abgefragt).
"""

from __future__ import annotations

import getpass
import sys

from ..services.auth import hash_password


def main() -> int:
    password = getpass.getpass("Neues Administrator-Passwort: ")
    if len(password) < 8:
        print("Mindestens 8 Zeichen erforderlich.", file=sys.stderr)
        return 1
    if getpass.getpass("Wiederholen: ") != password:
        print("Eingaben stimmen nicht überein.", file=sys.stderr)
        return 1
    print(f"AWC_ADMIN_PASSWORD_HASH={hash_password(password)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
