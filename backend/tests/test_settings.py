"""Einstellungen: Validierung, Rechte, Versionierung, Rücksetzen, ungültige gespeicherte Daten."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from pydantic import ValidationError

from app.models.settings import SettingsPatchError, VehicleSettings, apply_settings_patch, default_settings
from app.storage.database import Database
from app.storage.settings_store import SettingsStore, VersionConflict


def test_defaults_are_safe() -> None:
    s = default_settings()
    assert s.hardware.mode.value == "simulation"
    assert s.hardware.brake_method == "none" and s.hardware.brake_verified is False
    assert s.general.default_profile.value == "eco"
    for name in ("eco", "normal", "sport", "custom"):
        assert getattr(s.profiles, name).max_speed_kmh <= s.safety.absolute_max_speed_kmh


@pytest.mark.parametrize(
    "patch",
    [
        {"profiles": {"eco": {"max_throttle_percent": 150}}},
        {"profiles": {"eco": {"max_throttle_percent": float("nan")}}},
        {"profiles": {"eco": {"unbekannt": 1}}},
        {"power_split": {"awd_front_percent": 95}},
        {"tilt": {"pitch_function": "turbo"}},
        {"ui": {"speedometer_max_kmh": 5}},
    ],
)
def test_invalid_driver_patches_rejected(patch: dict) -> None:
    with pytest.raises(SettingsPatchError):
        apply_settings_patch(default_settings(), patch, allow_admin=False)


def test_driver_cannot_change_admin_sections() -> None:
    with pytest.raises(SettingsPatchError, match="Administratorrechte"):
        apply_settings_patch(default_settings(), {"safety": {"absolute_max_speed_kmh": 40}}, allow_admin=False)
    with pytest.raises(SettingsPatchError, match="Administratorrechte"):
        apply_settings_patch(default_settings(), {"hardware": {"mode": "hardware"}}, allow_admin=False)


def test_admin_can_change_safety_and_unknown_section_rejected() -> None:
    s = apply_settings_patch(default_settings(), {"safety": {"absolute_max_speed_kmh": 12}}, allow_admin=True)
    assert s.safety.absolute_max_speed_kmh == 12
    with pytest.raises(SettingsPatchError, match="Unbekannter Abschnitt"):
        apply_settings_patch(default_settings(), {"turbo": {}}, allow_admin=True)
    with pytest.raises(SettingsPatchError):
        apply_settings_patch(default_settings(), {"schema_version": 2}, allow_admin=True)


def test_cross_field_validation() -> None:
    with pytest.raises(SettingsPatchError):
        apply_settings_patch(default_settings(), {"battery": {"cell_critical_v": 3.6, "cell_warning_v": 3.5}}, allow_admin=True)
    with pytest.raises(SettingsPatchError):
        apply_settings_patch(default_settings(), {"safety": {"command_timeout_ms": 900, "connection_timeout_ms": 500}}, allow_admin=True)
    with pytest.raises(SettingsPatchError):
        apply_settings_patch(default_settings(), {"temperature": {"controller_warning_c": 80, "controller_critical_c": 70}}, allow_admin=True)


def test_controller_assignment_must_be_unique() -> None:
    data = default_settings().model_dump(mode="json")
    data["hardware"]["controllers"][1]["axle"] = "front"
    with pytest.raises(ValidationError):
        VehicleSettings.model_validate(data)
    data = default_settings().model_dump(mode="json")
    data["hardware"]["controllers"][0]["port"] = "/dev/ttyUSB0"
    data["hardware"]["controllers"][1]["port"] = "/dev/ttyUSB0"
    with pytest.raises(ValidationError):
        VehicleSettings.model_validate(data)


def test_axle_assignment_is_configurable() -> None:
    data = default_settings().model_dump(mode="json")
    data["hardware"]["controllers"][0]["axle"] = "rear"
    data["hardware"]["controllers"][1]["axle"] = "front"
    s = VehicleSettings.model_validate(data)
    assert s.hardware.controller_for(s.hardware.controllers[1].axle).id == "B"


async def test_store_versioning_history_and_reset(tmp_path: Path) -> None:
    db = Database(tmp_path / "s.sqlite3")
    db.open()
    store = SettingsStore(db)
    store.load()
    assert store.version == 1
    changed = apply_settings_patch(store.settings, {"ui": {"speedometer_max_kmh": 40}}, allow_admin=False)
    v2 = await store.save(changed, "test")
    assert v2 == 2
    with pytest.raises(VersionConflict):
        await store.save(changed, "test", expected_version=1)
    v3 = await store.reset("test")
    assert v3 == 3 and store.settings.ui.speedometer_max_kmh == 30
    history = store.history()
    assert [h["version"] for h in history] == [3, 2, 1]

    # Neu laden liefert die letzte Version
    store2 = SettingsStore(db)
    store2.load()
    assert store2.version == 3
    db.close()


def test_invalid_stored_settings_fall_back_to_defaults(tmp_path: Path) -> None:
    db = Database(tmp_path / "s.sqlite3")
    db.open()
    data = default_settings().model_dump(mode="json")
    data["safety"]["absolute_max_speed_kmh"] = 999  # manipuliert
    db.insert_settings(5, 1, "manipuliert", data)
    store = SettingsStore(db)
    settings = store.load()
    assert store.load_problem is not None
    assert settings.safety.absolute_max_speed_kmh == 20
    assert store.version == 6
    db.close()


def test_settings_json_contains_no_credentials() -> None:
    dumped = json.dumps(default_settings().model_dump(mode="json")).lower()
    assert "password" not in dumped and "pin" not in dumped
