"""Startpunkt: ``python -m app`` (im Ordner ``backend``)."""

from __future__ import annotations

import json
import logging
import sys

import uvicorn

from .config.env import BACKEND_DIR, REPO_DIR, EnvSettings, load_dotenv
from .main import create_app


def main() -> None:
    load_dotenv(BACKEND_DIR / ".env")
    load_dotenv(REPO_DIR / ".env")
    env = EnvSettings.from_env()
    logging.basicConfig(
        level=getattr(logging, env.log_level, logging.INFO),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
    )
    app = create_app(env)

    cred_file = env.data_dir / "credentials.json"
    if sys.stdout.isatty() and cred_file.is_file() and not (env.driver_pin and env.admin_password):
        try:
            creds = json.loads(cred_file.read_text(encoding="utf-8"))
            print("\n  Generierte Zugangsdaten (nur in dieser Konsole angezeigt):")
            if "driver_pin" in creds and not env.driver_pin:
                print(f"    Fahrer-PIN:        {creds['driver_pin']}")
            if "admin_password" in creds and not (env.admin_password or env.admin_password_hash):
                print(f"    Admin-Passwort:    {creds['admin_password']}")
            print(f"    Datei:             {cred_file}\n")
        except (OSError, json.JSONDecodeError):
            pass

    ssl_kwargs = {}
    if env.tls_certfile and env.tls_keyfile:
        ssl_kwargs = {"ssl_certfile": str(env.tls_certfile), "ssl_keyfile": str(env.tls_keyfile)}

    uvicorn.run(
        app,
        host=env.host,
        port=env.port,
        log_level=env.log_level.lower(),
        access_log=False,
        proxy_headers=False,
        ws_max_size=16384,
        ws_ping_interval=5.0,
        ws_ping_timeout=5.0,
        timeout_graceful_shutdown=3,
        **ssl_kwargs,
    )


if __name__ == "__main__":
    main()
