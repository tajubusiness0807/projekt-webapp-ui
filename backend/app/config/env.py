"""Umgebungsabhängige Startkonfiguration (Netzwerk, Pfade, Zugangsdaten, Hardware-Freigabe).

Fahrzeugeinstellungen liegen dagegen versioniert in SQLite (``app.storage``).
Alle Variablen beginnen mit ``AWC_`` und sind in ``.env.example`` dokumentiert.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Mapping

BACKEND_DIR = Path(__file__).resolve().parents[2]
REPO_DIR = BACKEND_DIR.parent


def _bool(value: str | None, default: bool = False) -> bool:
    if value is None or value.strip() == "":
        return default
    return value.strip().lower() in {"1", "true", "yes", "ja", "on"}


def _int(value: str | None, default: int) -> int:
    try:
        return int(value) if value not in (None, "") else default
    except ValueError:
        return default


@dataclass(frozen=True)
class EnvSettings:
    host: str = "0.0.0.0"
    port: int = 8080
    data_dir: Path = field(default_factory=lambda: BACKEND_DIR / "data")
    frontend_dist: Path | None = None
    driver_pin: str | None = None
    admin_password: str | None = None
    admin_password_hash: str | None = None
    hardware_enabled: bool = False
    allowed_origins: tuple[str, ...] = ()
    tls_certfile: Path | None = None
    tls_keyfile: Path | None = None
    log_level: str = "INFO"
    token_ttl_hours: int = 12
    wifi_interface: str = "wlan0"
    start_background_tasks: bool = True

    @classmethod
    def from_env(cls, environ: Mapping[str, str] | None = None) -> "EnvSettings":
        env = os.environ if environ is None else environ
        data_dir = Path(env.get("AWC_DATA_DIR") or (BACKEND_DIR / "data"))
        dist_env = env.get("AWC_FRONTEND_DIST")
        if dist_env:
            frontend_dist: Path | None = Path(dist_env)
        else:
            default_dist = REPO_DIR / "frontend" / "dist"
            frontend_dist = default_dist if default_dist.exists() else None
        origins = tuple(
            o.strip().rstrip("/") for o in (env.get("AWC_ALLOWED_ORIGINS") or "").split(",") if o.strip()
        )
        cert = env.get("AWC_TLS_CERTFILE")
        key = env.get("AWC_TLS_KEYFILE")
        return cls(
            host=env.get("AWC_HOST", "0.0.0.0"),
            port=_int(env.get("AWC_PORT"), 8080),
            data_dir=data_dir,
            frontend_dist=frontend_dist,
            driver_pin=(env.get("AWC_DRIVER_PIN") or None),
            admin_password=(env.get("AWC_ADMIN_PASSWORD") or None),
            admin_password_hash=(env.get("AWC_ADMIN_PASSWORD_HASH") or None),
            hardware_enabled=_bool(env.get("AWC_HARDWARE_ENABLED")),
            allowed_origins=origins,
            tls_certfile=Path(cert) if cert else None,
            tls_keyfile=Path(key) if key else None,
            log_level=(env.get("AWC_LOG_LEVEL") or "INFO").upper(),
            token_ttl_hours=max(1, min(168, _int(env.get("AWC_TOKEN_TTL_HOURS"), 12))),
            wifi_interface=env.get("AWC_WIFI_INTERFACE", "wlan0"),
        )


def load_dotenv(path: Path, environ: dict[str, str] | None = None) -> None:
    """Liest eine einfache ``.env``-Datei (``KEY=VALUE``) ohne vorhandene Variablen zu überschreiben."""
    target = os.environ if environ is None else environ
    if not path.is_file():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in target:
            target[key] = value
