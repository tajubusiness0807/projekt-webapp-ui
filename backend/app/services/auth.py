"""Zugangsschutz: Fahrer-PIN, Administrator-Passwort und signierte Tokens.

* Tokens sind HMAC-SHA256-signiert (Geheimnis in ``<data>/secret.key``, nur für den Dienst lesbar)
  und enthalten Rolle und Ablaufzeit. Ändern sich PIN oder Passwort, werden alte Tokens ungültig.
* Fehlversuche werden je IP begrenzt (5 pro Minute, danach 60 s Sperre).
* Sind keine Zugangsdaten konfiguriert, werden einmalig zufällige erzeugt und in
  ``<data>/credentials.json`` (Dateirechte 0600) abgelegt – nicht im Protokoll.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import logging
import os
import secrets
import time
from dataclasses import dataclass
from pathlib import Path

from ..config.env import EnvSettings
from ..models.common import Role

log = logging.getLogger(__name__)

PBKDF2_ITERATIONS = 120_000
MAX_FAILURES = 5
FAILURE_WINDOW_S = 60.0
LOCKOUT_S = 60.0


class AuthError(Exception):
    def __init__(self, message: str, *, status: int = 401, retry_after: int | None = None) -> None:
        super().__init__(message)
        self.status = status
        self.retry_after = retry_after


@dataclass(frozen=True)
class TokenInfo:
    role: Role
    expires_at: int
    token_id: str

    @property
    def is_admin(self) -> bool:
        return self.role == Role.ADMIN


def hash_password(password: str, *, iterations: int = PBKDF2_ITERATIONS) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    return f"pbkdf2_sha256${iterations}${_b64(salt)}${_b64(digest)}"


def verify_password_hash(password: str, encoded: str) -> bool:
    try:
        algorithm, iterations_s, salt_s, digest_s = encoded.split("$")
        if algorithm != "pbkdf2_sha256":
            return False
        iterations = int(iterations_s)
        salt = _unb64(salt_s)
        expected = _unb64(digest_s)
    except (ValueError, TypeError):
        return False
    actual = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    return hmac.compare_digest(actual, expected)


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _write_private(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(content)


class AuthService:
    def __init__(self, env: EnvSettings) -> None:
        self._env = env
        self._data_dir = env.data_dir
        self._secret = b""
        self._driver_pin = ""
        self._admin_password: str | None = None
        self._admin_hash: str | None = None
        self._failures: dict[str, tuple[int, float, float]] = {}
        self.generated_credentials_file: Path | None = None

    # ------------------------------------------------------------------ Einrichtung
    def initialize(self) -> None:
        secret_file = self._data_dir / "secret.key"
        if secret_file.is_file():
            self._secret = secret_file.read_bytes()
        if len(self._secret) < 32:
            self._secret = secrets.token_bytes(32)
            _write_private(secret_file, self._secret)

        generated: dict[str, str] = {}
        cred_file = self._data_dir / "credentials.json"
        if cred_file.is_file():
            try:
                generated = json.loads(cred_file.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                generated = {}

        pin = self._env.driver_pin or generated.get("driver_pin")
        admin_pw = self._env.admin_password or generated.get("admin_password")
        admin_hash = self._env.admin_password_hash
        changed = False
        if not pin:
            pin = f"{secrets.randbelow(10**6):06d}"
            generated["driver_pin"] = pin
            changed = True
        if not admin_pw and not admin_hash:
            admin_pw = secrets.token_urlsafe(12)
            generated["admin_password"] = admin_pw
            changed = True
        if not pin.isdigit() or not 4 <= len(pin) <= 12:
            raise ValueError("AWC_DRIVER_PIN muss aus 4 bis 12 Ziffern bestehen")
        if admin_pw is not None and len(admin_pw) < 8:
            raise ValueError("Das Administrator-Passwort muss mindestens 8 Zeichen haben")
        if changed:
            _write_private(cred_file, json.dumps(generated, indent=2).encode("utf-8"))
            self.generated_credentials_file = cred_file
            log.warning(
                "Zugangsdaten wurden zufällig erzeugt und in %s gespeichert (nur für den Dienst lesbar). "
                "Eigene Werte über AWC_DRIVER_PIN / AWC_ADMIN_PASSWORD setzen.",
                cred_file,
            )
        elif "driver_pin" in generated or "admin_password" in generated:
            self.generated_credentials_file = cred_file
        self._driver_pin = pin
        self._admin_password = admin_pw
        self._admin_hash = admin_hash

    @property
    def _credential_version(self) -> str:
        material = self._secret + self._driver_pin.encode() + (self._admin_hash or self._admin_password or "").encode()
        return hashlib.sha256(material).hexdigest()[:12]

    # ------------------------------------------------------------------ Login
    def login(self, role: Role, secret: str, client: str) -> tuple[str, TokenInfo]:
        self._check_lockout(client)
        if role == Role.DRIVER:
            ok = hmac.compare_digest(secret.encode("utf-8"), self._driver_pin.encode("utf-8"))
            # Das Admin-Passwort berechtigt auch zum Fahren.
            ok = ok or self._check_admin(secret)
        else:
            ok = self._check_admin(secret)
        if not ok:
            self._register_failure(client)
            raise AuthError("Zugangsdaten falsch")
        self._failures.pop(client, None)
        return self.issue_token(role)

    def _check_admin(self, secret: str) -> bool:
        if self._admin_hash:
            return verify_password_hash(secret, self._admin_hash)
        if self._admin_password:
            return hmac.compare_digest(secret.encode("utf-8"), self._admin_password.encode("utf-8"))
        return False

    def issue_token(self, role: Role) -> tuple[str, TokenInfo]:
        expires = int(time.time()) + self._env.token_ttl_hours * 3600
        info = TokenInfo(role, expires, secrets.token_hex(6))
        payload = json.dumps(
            {"r": role.value, "exp": expires, "jti": info.token_id, "kv": self._credential_version},
            separators=(",", ":"),
        ).encode("utf-8")
        body = _b64(payload)
        signature = _b64(hmac.new(self._secret, body.encode("ascii"), hashlib.sha256).digest())
        return f"{body}.{signature}", info

    def verify(self, token: str | None) -> TokenInfo | None:
        if not token or token.count(".") != 1 or len(token) > 1024:
            return None
        body, signature = token.split(".")
        expected = _b64(hmac.new(self._secret, body.encode("ascii"), hashlib.sha256).digest())
        if not hmac.compare_digest(signature, expected):
            return None
        try:
            payload = json.loads(_unb64(body))
            role = Role(payload["r"])
            expires = int(payload["exp"])
            kv = str(payload["kv"])
            token_id = str(payload["jti"])
        except (ValueError, KeyError, TypeError, json.JSONDecodeError):
            return None
        if expires < time.time() or kv != self._credential_version:
            return None
        return TokenInfo(role, expires, token_id)

    # ------------------------------------------------------------------ Begrenzung
    def _check_lockout(self, client: str) -> None:
        count, first, locked_until = self._failures.get(client, (0, 0.0, 0.0))
        now = time.monotonic()
        if locked_until > now:
            raise AuthError("Zu viele Fehlversuche – bitte warten", status=429, retry_after=int(locked_until - now) + 1)

    def _register_failure(self, client: str) -> None:
        now = time.monotonic()
        count, first, _ = self._failures.get(client, (0, now, 0.0))
        if now - first > FAILURE_WINDOW_S:
            count, first = 0, now
        count += 1
        locked_until = now + LOCKOUT_S if count >= MAX_FAILURES else 0.0
        self._failures[client] = (count, first, locked_until)
        if len(self._failures) > 1000:  # Schutz vor Speicherwachstum
            self._failures.clear()
