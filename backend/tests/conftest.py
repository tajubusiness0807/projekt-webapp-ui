"""Gemeinsame Test-Hilfen.

Alle Tests laufen ohne Motorcontroller. Hardwareadapter werden mit einer simulierten seriellen
Schnittstelle (``FakeSerial``) geprüft, die niemals ein reales Gerät öffnet.
"""

from __future__ import annotations

import os
from dataclasses import replace
from pathlib import Path
from typing import Any, Iterator

import pytest

from app.config.env import EnvSettings
from app.controllers.foc_protocol import FocFeedback, decode_command, encode_feedback
from app.models.common import Role
from app.models.protocol import CLIENT_MESSAGE_ADAPTER
from app.models.settings import VehicleSettings
from app.services.auth import AuthService
from app.services.events import EventLog
from app.services.session_manager import Session
from app.services.vehicle_service import VehicleService
from app.storage.database import Database
from app.storage.settings_store import SettingsStore
from app.utils.clock import FakeClock

PIN = "4711"
ADMIN_PASSWORD = "geheim-admin-123"


@pytest.fixture
def env(tmp_path: Path) -> EnvSettings:
    return EnvSettings(
        data_dir=tmp_path / "data",
        driver_pin=PIN,
        admin_password=ADMIN_PASSWORD,
        frontend_dist=None,
        start_background_tasks=False,
    )


class FakeSerial:
    """Simulierte serielle Schnittstelle: zeichnet Befehle auf und liefert vorbereitete Rückmeldungen."""

    def __init__(self, port: str) -> None:
        self.port = port
        self.written: list[bytes] = []
        self.rx = bytearray()
        self.closed = False

    # pyserial-kompatible Methoden
    def write(self, data: bytes) -> int:
        self.written.append(bytes(data))
        return len(data)

    @property
    def in_waiting(self) -> int:
        return len(self.rx)

    def read(self, n: int) -> bytes:
        data = bytes(self.rx[:n])
        del self.rx[:n]
        return data

    def reset_input_buffer(self) -> None:
        self.rx.clear()

    def close(self) -> None:
        self.closed = True

    # Testhilfen
    def feed(self, fb: FocFeedback, *, odometry: bool = False) -> None:
        self.rx.extend(encode_feedback(fb, with_odometry=odometry))

    def last_command(self) -> tuple[int, int]:
        return decode_command(self.written[-1])


class FakeSerialFactory:
    def __init__(self) -> None:
        self.ports: dict[str, FakeSerial] = {}

    def __call__(self, cfg: Any) -> FakeSerial:
        port = FakeSerial(cfg.port)
        self.ports[cfg.port] = port
        return port


def hardware_settings(**overrides: Any) -> VehicleSettings:
    """Vollständig bestätigte Hardware-Konfiguration für Tests (nur mit FakeSerial verwendet)."""
    settings = VehicleSettings()
    hw = settings.hardware.model_dump()
    hw.update(
        mode="hardware",
        controller_model="STM32F103RCT6 (Test)",
        firmware="hoverboard-firmware-hack-foc",
        firmware_version="test",
        firmware_variant_usart=True,
        firmware_control_mode="torque",
        protocol_verified=True,
        signal_levels_verified=True,
        wiring_verified=True,
        independent_axle_control=True,
        wheel_diameter_verified=True,
        wheels_lifted_test_passed=True,
    )
    hw["controllers"][0]["port"] = "/dev/fake-front"
    hw["controllers"][1]["port"] = "/dev/fake-rear"
    hw.update(overrides)
    return VehicleSettings.model_validate({**settings.model_dump(), "hardware": hw})


class Harness:
    """Fahrzeugdienst mit manueller Uhr: ``tick()`` führt Regelzyklen deterministisch aus."""

    def __init__(self, env: EnvSettings, settings: VehicleSettings | None = None, serial_factory: Any = None) -> None:
        self.clock = FakeClock()
        self.db = Database(env.data_dir / "test.sqlite3")
        self.db.open()
        self.events = EventLog(self.clock, self.db)
        self.store = SettingsStore(self.db)
        self.store.load()
        if settings is not None:
            self.store._settings = settings  # Test-Abkürzung: ohne Versionseintrag
        self.auth = AuthService(env)
        self.auth.initialize()
        self.service = VehicleService(env, self.store, self.events, self.auth, self.clock, db=self.db, serial_factory=serial_factory)
        self._seq: dict[str, int] = {}

    async def start(self) -> None:
        await self.service.start(run_loops=False)
        self.tick()

    def tick(self, seconds: float = 0.04, steps: int = 1) -> None:
        for _ in range(steps):
            self.clock.advance(seconds)
            self.service.step()

    def run(self, duration: float, dt: float = 0.04, session: Session | None = None, **drive: Any) -> None:
        """Simuliert ``duration`` Sekunden; optional sendet ``session`` dabei laufend Fahrbefehle."""
        steps = int(round(duration / dt))
        for _ in range(steps):
            self.clock.advance(dt)
            if session is not None:
                self.send_sync(session, "drive", **drive)
            self.service.step()

    def open(self, client_id: str = "geraet1", role: Role = Role.DRIVER) -> Session:
        session = self.service.open_session(client_id, role, client_id, "127.0.0.1")
        self._seq[session.id] = 0
        return session

    def message(self, session: Session, kind: str, **fields: Any) -> Any:
        self._seq[session.id] = self._seq.get(session.id, 0) + 1
        payload: dict[str, Any] = {"type": kind, "seq": self._seq[session.id], "ts": self.clock.wall_ms()}
        if kind == "drive":
            payload.update({"throttle": 0.0, "brake": 0.0, "steer": 0.0, "profile": self.service.profile.value})
        payload.update(fields)
        return CLIENT_MESSAGE_ADAPTER.validate_python(payload)

    async def send(self, session: Session, kind: str, **fields: Any) -> dict[str, Any] | None:
        await self.service.handle_message(session, self.message(session, kind, **fields))
        return self.last_ack(session)

    def send_sync(self, session: Session, kind: str, **fields: Any) -> None:
        """Nur für Nachrichten mit synchronem Handler (z. B. ``drive``) – ohne Event-Loop-Wechsel."""
        coro = self.service.handle_message(session, self.message(session, kind, **fields))
        try:
            coro.send(None)
        except StopIteration:
            return
        coro.close()  # pragma: no cover
        raise AssertionError("Handler ist nicht synchron abgeschlossen")  # pragma: no cover

    def last_ack(self, session: Session) -> dict[str, Any] | None:
        import json

        ack = None
        while not session.outbox.empty():
            msg = json.loads(session.outbox.get_nowait())
            if msg.get("type") == "ack":
                ack = msg
        return ack

    def fault_codes(self) -> set[str]:
        return {f.code.value for f in self.service.safety.faults()}

    async def close(self) -> None:
        await self.service.stop()
        self.db.close()


@pytest.fixture
async def harness(env: EnvSettings) -> Iterator[Harness]:
    h = Harness(env)
    await h.start()
    yield h
    await h.close()


@pytest.fixture
def hw_env(env: EnvSettings) -> EnvSettings:
    return replace(env, hardware_enabled=True)


def pytest_collection_modifyitems(config: Any, items: list[Any]) -> None:
    if os.environ.get("AWC_HARDWARE_TESTS") == "1":
        return
    skip = pytest.mark.skip(reason="Hardwaretest – nur mit AWC_HARDWARE_TESTS=1 und sicher aufgebauter Hardware")
    for item in items:
        if "hardware" in item.keywords:
            item.add_marker(skip)
