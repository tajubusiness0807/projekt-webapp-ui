"""Versionierte Einstellungen mit Validierung, Historie und Rücksetzen auf sichere Standardwerte."""

from __future__ import annotations

import asyncio
import logging
from typing import Any, Callable

from pydantic import ValidationError

from ..models.settings import SCHEMA_VERSION, VehicleSettings, default_settings
from .database import Database

log = logging.getLogger(__name__)

SettingsListener = Callable[[VehicleSettings, int, str], None]


def migrate(data: dict[str, Any], schema_version: int) -> dict[str, Any]:
    """Hebt ältere Schemata auf den aktuellen Stand. Unbekannte Versionen werden abgelehnt."""
    if schema_version == SCHEMA_VERSION:
        return data
    raise ValueError(f"Unbekannte Schema-Version {schema_version}")


class SettingsStore:
    def __init__(self, db: Database) -> None:
        self._db = db
        self._settings = default_settings()
        self._version = 0
        self._listeners: list[SettingsListener] = []
        self._save_lock = asyncio.Lock()
        self.load_problem: str | None = None

    @property
    def settings(self) -> VehicleSettings:
        return self._settings

    @property
    def version(self) -> int:
        return self._version

    def add_listener(self, listener: SettingsListener) -> None:
        self._listeners.append(listener)

    def load(self) -> VehicleSettings:
        """Lädt die neueste gespeicherte Version. Ungültige Daten führen zu sicheren Standardwerten."""
        stored = self._db.latest_settings()
        if stored is None:
            self._settings = default_settings()
            self._version = 1
            self._db.insert_settings(self._version, SCHEMA_VERSION, "standardwerte", self._settings.model_dump(mode="json"))
            return self._settings
        try:
            data = migrate(stored.data, stored.schema_version)
            self._settings = VehicleSettings.model_validate(data)
            self._version = stored.version
        except (ValidationError, ValueError) as exc:
            log.error("Gespeicherte Einstellungen ungültig (Version %s): %s", stored.version, exc)
            self.load_problem = f"Version {stored.version} ungültig – sichere Standardwerte geladen"
            self._settings = default_settings()
            self._version = stored.version + 1
            self._db.insert_settings(
                self._version, SCHEMA_VERSION, "standardwerte-nach-fehler", self._settings.model_dump(mode="json")
            )
        return self._settings

    async def save(self, settings: VehicleSettings, source: str, expected_version: int | None = None) -> int:
        async with self._save_lock:
            if expected_version is not None and expected_version != self._version:
                raise VersionConflict(self._version)
            new_version = self._version + 1
            await asyncio.to_thread(
                self._db.insert_settings, new_version, SCHEMA_VERSION, source, settings.model_dump(mode="json")
            )
            self._settings = settings
            self._version = new_version
        for listener in list(self._listeners):
            listener(settings, new_version, source)
        return new_version

    async def reset(self, source: str) -> int:
        return await self.save(default_settings(), source)

    def history(self, limit: int = 20) -> list[dict[str, Any]]:
        return self._db.settings_history(limit)


class VersionConflict(Exception):
    def __init__(self, current_version: int) -> None:
        super().__init__(f"Einstellungen wurden zwischenzeitlich geändert (aktuelle Version {current_version})")
        self.current_version = current_version
