"""Zugangsschutz, Messwertzustände, Akkuschätzung und WLAN-Auswertung."""

from __future__ import annotations

import json
import os
import stat
from dataclasses import replace

import pytest

from app.config.env import EnvSettings, load_dotenv
from app.models.common import MeasurementStatus, Role
from app.models.settings import BatterySettings
from app.services.auth import AuthError, AuthService, hash_password, verify_password_hash
from app.telemetry.battery import estimate_percent
from app.telemetry.measurement import TrackedValue
from app.telemetry.network import mac_for_ip, parse_iw_station, parse_proc_wireless, signal_quality


def test_tokens_signed_and_tamper_proof(env: EnvSettings) -> None:
    auth = AuthService(env)
    auth.initialize()
    token, info = auth.login(Role.DRIVER, env.driver_pin or "", "1.2.3.4")
    assert auth.verify(token) == info
    body, sig = token.split(".")
    forged_body = body[:-2] + ("AA" if body[-2:] != "AA" else "BB")
    assert auth.verify(f"{forged_body}.{sig}") is None
    assert auth.verify("abc") is None


def test_driver_cannot_login_as_admin_with_pin(env: EnvSettings) -> None:
    auth = AuthService(env)
    auth.initialize()
    with pytest.raises(AuthError):
        auth.login(Role.ADMIN, env.driver_pin or "", "x")
    token, info = auth.login(Role.ADMIN, env.admin_password or "", "x")
    assert info.is_admin


def test_changed_credentials_invalidate_tokens(env: EnvSettings) -> None:
    auth = AuthService(env)
    auth.initialize()
    token, _ = auth.issue_token(Role.DRIVER)
    auth2 = AuthService(replace(env, driver_pin="98765"))
    auth2.initialize()
    assert auth2.verify(token) is None


def test_generated_credentials_are_private(env: EnvSettings) -> None:
    auth = AuthService(replace(env, driver_pin=None, admin_password=None))
    auth.initialize()
    cred = env.data_dir / "credentials.json"
    assert cred.is_file()
    assert stat.S_IMODE(os.stat(cred).st_mode) == 0o600
    assert stat.S_IMODE(os.stat(env.data_dir / "secret.key").st_mode) == 0o600
    data = json.loads(cred.read_text())
    assert data["driver_pin"].isdigit() and len(data["admin_password"]) >= 8


def test_invalid_pin_configuration_rejected(env: EnvSettings) -> None:
    with pytest.raises(ValueError):
        AuthService(replace(env, driver_pin="12ab")).initialize()


def test_password_hash_roundtrip(env: EnvSettings) -> None:
    encoded = hash_password("sehr-geheim", iterations=1000)
    assert verify_password_hash("sehr-geheim", encoded)
    assert not verify_password_hash("falsch", encoded)
    auth = AuthService(replace(env, admin_password=None, admin_password_hash=encoded))
    auth.initialize()
    _, info = auth.login(Role.ADMIN, "sehr-geheim", "x")
    assert info.is_admin


def test_tracked_value_states() -> None:
    v = TrackedValue("V")
    assert v.measurement(0, 1.0).status == MeasurementStatus.UNAVAILABLE
    v.update(38.5, 10.0, simulated=False)
    assert v.measurement(10.5, 1.0).status == MeasurementStatus.VALID
    stale = v.measurement(12.0, 1.0)
    assert stale.status == MeasurementStatus.STALE and not stale.usable and stale.age_ms == 2000
    v.update(float("nan"), 13.0, simulated=False)
    assert v.measurement(13.0, 1.0).status == MeasurementStatus.UNAVAILABLE
    v.update(1.0, 14.0, simulated=True)
    assert v.measurement(14.0, 1.0).status == MeasurementStatus.SIMULATED


def test_battery_estimate_monotonic_and_bounded() -> None:
    battery = BatterySettings()
    values = [estimate_percent(v / 10, battery) for v in range(300, 430, 5)]
    assert values == sorted(values)
    assert estimate_percent(30.0, battery) == 0.0
    assert estimate_percent(42.0, battery) == 100.0


def test_wifi_parsers() -> None:
    proc = "Inter-| sta-|   Quality        |\n face | tus | link level noise\n wlan0: 0000   58.  -52.  -256        0      0      0      0      0        0\n"
    assert parse_proc_wireless(proc, "wlan0") == -52.0
    assert parse_proc_wireless(proc.replace("-52.", "0."), "wlan0") is None
    arp = "IP address       HW type     Flags       HW address            Mask     Device\n192.168.4.23     0x1         0x2         aa:bb:cc:dd:ee:ff     *        wlan0\n"
    assert mac_for_ip(arp, "192.168.4.23") == "aa:bb:cc:dd:ee:ff"
    assert mac_for_ip(arp, "192.168.4.99") is None
    assert parse_iw_station("Station aa:bb (on wlan0)\n\tsignal:  \t-61 [-63, -64] dBm\n") == -61.0
    assert signal_quality(-50) == "stark" and signal_quality(-80) == "schwach" and signal_quality(None) == "unbekannt"


def test_env_parsing_and_dotenv(tmp_path) -> None:  # type: ignore[no-untyped-def]
    env_file = tmp_path / ".env"
    env_file.write_text("# Kommentar\nAWC_PORT=9000\nAWC_HARDWARE_ENABLED=ja\nAWC_ALLOWED_ORIGINS=http://a, http://b/\n")
    environ: dict[str, str] = {"AWC_PORT": "8000"}
    load_dotenv(env_file, environ)
    settings = EnvSettings.from_env(environ)
    assert settings.port == 8000  # vorhandene Variablen werden nicht überschrieben
    assert settings.hardware_enabled is True
    assert settings.allowed_origins == ("http://a", "http://b")
    assert EnvSettings.from_env({}).hardware_enabled is False
