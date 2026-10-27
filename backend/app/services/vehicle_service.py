"""Zentraler Fahrzeugdienst: Regelschleife, Überwachung, Befehlsverarbeitung und Telemetrie.

Ablauf eines Regelzyklus (Standard 25 Hz, siehe ``step``):

1. Rückmeldungen beider Controller lesen und plausibilisieren.
2. Überwachung: Loop-Zeit, Controller, Akku, Temperatur, Steuergerät-Verbindung.
3. Fahreranforderung bestimmen (nur Besitzer, nur frisch, Neutralverriegelung).
4. Fahrlogik berechnet begrenzte Radanforderungen.
5. Nur im Zustand ARMED gehen Fahranforderungen an die Controller, sonst sicherer Stopp.
6. Simulation fortschreiben (nur im Simulationsmodus), Zähler und Lebenszeichen aktualisieren.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from collections import deque
from typing import Any, Callable

from .. import PROTOCOL_VERSION, __version__
from ..config.env import EnvSettings
from ..controllers.base import BrakeSupport, WheelCommand
from ..controllers.factory import DrivetrainBuild, build_drivetrain
from ..controllers.foc_serial import SerialFactory
from ..models.common import (
    Axle,
    BrakeState,
    Direction,
    DriveMode,
    DriveProfileName,
    OperatingMode,
    Role,
    VehicleState,
)
from ..models.faults import FAULT_CATALOG, FaultCode
from ..models.protocol import OWNER_ONLY
from ..models.settings import (
    HardwareSettings,
    ProfilesSettings,
    SettingsPatchError,
    VehicleSettings,
    apply_settings_patch,
)
from ..safety.command_gate import CommandRejected
from ..safety.limits import (
    EffectiveProfile,
    axle_distribution_available,
    axle_scales,
    axle_weights,
    drive_mode_availability,
    effective_profile,
)
from ..safety.state_machine import SafetyManager
from ..safety.watchdog import LoopSupervisor
from ..simulation.fault_injection import SIMULATION_FAULTS
from ..storage.database import Database
from ..storage.settings_store import SettingsStore, VersionConflict
from ..telemetry.aggregator import DrivetrainTelemetry
from ..telemetry.battery import pack_limits
from ..telemetry.measurement import Measurement
from ..telemetry.network import WifiMonitor, signal_quality
from ..telemetry.system import SystemMonitor
from ..utils.clock import Clock
from ..utils.sdnotify import SystemdNotifier
from .auth import AuthService
from .drive_logic import DriveComputer, DriveContext, DriveOutput, DriverInput
from .events import Event, EventLog
from .session_manager import Session, SessionManager

log = logging.getLogger(__name__)

STARTUP_GRACE_S = 2.0
SAFE_STOP_BRAKE_LEVEL = 0.7
BATTERY_PERSIST_S = 2.0
HYSTERESIS_V = 0.3
TEMP_HYSTERESIS_C = 3.0
CHECKSUM_ERRORS_LIMIT = 10
CHECKSUM_WINDOW_S = 2.0
INVALID_MESSAGES_LIMIT = 50
INVALID_WINDOW_S = 10.0


class ProtocolViolation(Exception):
    """Zu viele ungültige Nachrichten – die Verbindung wird getrennt."""


class VehicleService:
    def __init__(
        self,
        env: EnvSettings,
        store: SettingsStore,
        events: EventLog,
        auth: AuthService,
        clock: Clock,
        db: Database | None = None,
        serial_factory: SerialFactory | None = None,
        notifier: SystemdNotifier | None = None,
    ) -> None:
        self.env = env
        self.store = store
        self.events = events
        self.auth = auth
        self.clock = clock
        self.db = db
        self._serial_factory = serial_factory
        self.notifier = notifier or SystemdNotifier()
        settings = store.settings
        self.safety = SafetyManager(clock, events)
        self.sessions = SessionManager(clock, settings.safety.max_sessions)
        self.drive = DriveComputer()
        self.telemetry = DrivetrainTelemetry()
        self.system_monitor = SystemMonitor()
        self.build: DrivetrainBuild | None = None
        self._build_hardware: HardwareSettings = settings.hardware.model_copy(deep=True)
        self.profile = settings.general.default_profile
        self.drive_mode = settings.general.default_drive_mode
        self.direction = Direction.FORWARD
        self.last_output = DriveOutput()
        self.last_input = DriverInput.neutral()
        self.brake_state = BrakeState.INACTIVE
        self.brake_support: BrakeSupport | None = None
        self.restart_required = False
        self.wifi = WifiMonitor(env.wifi_interface, clock, simulated_fallback=True)
        self._speed_history: deque[tuple[float, float]] = deque(maxlen=40)
        self._bad_frames: dict[Axle, deque[tuple[float, int]]] = {a: deque(maxlen=200) for a in Axle}
        self._battery_low_since: float | None = None
        self._battery_warn_since: float | None = None
        self._trip_s = 0.0
        self._total_s = 0.0
        self._total_persisted_at = 0.0
        self._last_step: float | None = None
        self._loop_periods: deque[float] = deque(maxlen=50)
        self._rt_heartbeat = time.monotonic()
        self._supervisor = LoopSupervisor(lambda: self._rt_heartbeat, self._on_loop_stall, settings.safety.loop_stall_ms / 1000)
        self._tasks: list[asyncio.Task[Any]] = []
        self._broadcast_now = asyncio.Event()
        self._telemetry_seq = 0
        self._system_cache: dict[str, Any] = {}
        self._owner_timeout_reported: str | None = None
        self._last_watchdog_notify = 0.0
        self._started_at = clock.monotonic()

    # ================================================================== Lebenszyklus
    @property
    def settings(self) -> VehicleSettings:
        return self.store.settings

    @property
    def mode(self) -> OperatingMode:
        return self.build.mode if self.build else self.settings.hardware.mode

    async def start(self, *, run_loops: bool = True) -> None:
        self.events.info("START", "system", f"AllWheel Control {__version__} gestartet")
        self.events.add_listener(self._on_event)
        self.safety.add_listener(self._on_state_change)
        self.store.add_listener(self._on_settings_changed)
        if self.db is not None:
            try:
                self._total_s = float(self.db.get_kv("total_drive_s") or 0.0)
            except ValueError:
                self._total_s = 0.0

        if self.store.load_problem:
            self.safety.raise_fault(FaultCode.CONFIG_INVALID, "konfiguration", self.store.load_problem)

        self.build = build_drivetrain(self.settings, self.env, self.clock, self._serial_factory)
        self._build_hardware = self.settings.hardware.model_copy(deep=True)
        if self.build.coordinator is None:
            self.safety.set_condition(
                FaultCode.HARDWARE_NOT_INITIALIZED, "hardware", True, self.build.init_error or "Unbekannter Grund"
            )
        else:
            await self.build.coordinator.connect_all(self.clock.monotonic())
            self.events.info(
                "CONNECT",
                "controller",
                "Controller verbunden" if self.build.mode == OperatingMode.HARDWARE else "Simulierte Controller verbunden",
                {"modus": self.build.mode.value},
            )
        if self.build.commissioning:
            self.safety.set_condition(FaultCode.COMMISSIONING, "hardware", True)
        if not drive_mode_availability(self.mode, self._build_hardware)[self.drive_mode].available:
            self.drive_mode = DriveMode.AWD
        self.safety.finish_initialization()
        self.events.info(
            "MODE",
            "system",
            "Betriebsart: " + ("SIMULATION – keine realen Motorbefehle" if self.mode == OperatingMode.SIMULATION else "HARDWARE"),
        )
        if run_loops:
            loop = asyncio.get_running_loop()
            self._tasks = [
                loop.create_task(self._control_loop(), name="awc-control"),
                loop.create_task(self._broadcast_loop(), name="awc-broadcast"),
                loop.create_task(self._monitor_loop(), name="awc-monitor"),
            ]
            self._supervisor.start()
            self.notifier.ready()

    async def stop(self) -> None:
        self.notifier.stopping()
        self._supervisor.stop()
        for task in self._tasks:
            task.cancel()
        for task in self._tasks:
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass
        self._tasks = []
        if self.build and self.build.coordinator:
            await self.build.coordinator.close_all()
        self._persist_total(force=True)
        self.events.info("STOP", "system", "AllWheel Control beendet")

    # ================================================================== Regelschleife
    async def _control_loop(self) -> None:
        period = 1.0 / self.settings.telemetry.control_loop_hz
        next_tick = time.monotonic()
        while True:
            try:
                self.step()
            except Exception:
                log.exception("Fehler in der Regelschleife – sicherer Zustand")
                self._emergency_neutral()
                self.safety.raise_fault(FaultCode.WATCHDOG, "regelschleife", "Ausnahme in der Regelschleife")
            period = 1.0 / self.settings.telemetry.control_loop_hz
            next_tick += period
            delay = next_tick - time.monotonic()
            if delay < -period:  # Rückstand nicht aufholen
                next_tick = time.monotonic()
                delay = 0
            await asyncio.sleep(max(0.0, delay))

    def step(self) -> None:
        now = self.clock.monotonic()
        dt = 0.0 if self._last_step is None else now - self._last_step
        self._last_step = now
        settings = self.settings
        stale_s = settings.safety.telemetry_stale_ms / 1000

        if dt > 0:
            self._loop_periods.append(dt)
        if dt * 1000 > settings.safety.loop_stall_ms:
            self.safety.raise_fault(FaultCode.WATCHDOG, "regelschleife", f"Zyklus dauerte {dt * 1000:.0f} ms")
        if self._supervisor.tripped.is_set():
            self._supervisor.tripped.clear()
            self.safety.raise_fault(FaultCode.WATCHDOG, "supervisor", "Regelschleife hing – Nullbefehl durch Supervisor")

        coordinator = self.build.coordinator if self.build else None
        if coordinator is not None:
            for axle, telemetry in coordinator.poll().items():
                self.telemetry.ingest(axle, telemetry)

        speed = self._speed(now, stale_s)
        if speed.usable and speed.value is not None:
            self._speed_history.append((now, speed.value))

        self._evaluate_controllers(now)
        battery_factor = self._evaluate_battery(now, stale_s)
        temperature_factor = self._evaluate_temperature(now, stale_s)
        self._evaluate_owner_connection(now)
        self.safety.set_condition(
            FaultCode.SPEED_UNAVAILABLE, "geschwindigkeit", self.safety.armed and not speed.usable
        )

        driver_input = self._current_input(now)
        weights = self._weights()
        ctx = DriveContext(
            armed=self.safety.armed,
            direction=self.direction,
            profile=self.effective_profile(),
            weights=weights,
            speed=speed,
            reverse_max_speed_kmh=settings.safety.reverse_max_speed_kmh,
            reverse_max_throttle=settings.safety.reverse_max_throttle_percent / 100,
            battery_factor=battery_factor,
            temperature_factor=temperature_factor,
        )
        output = self.drive.compute(driver_input, ctx, dt)

        support: BrakeSupport | None = None
        if coordinator is not None:
            if self.safety.armed:
                support = coordinator.apply(output.wheels, output.brake_level)
            else:
                support = self._safe_stop(speed)
        if self.build and self.build.physics is not None:
            self.build.physics.step(dt)

        self.brake_support = support
        self._update_brake_state(driver_input, output, support, speed, now)
        if self.safety.armed:
            self._trip_s += dt
            self._total_s += dt
        self.last_output = output
        self.last_input = driver_input
        self._rt_heartbeat = time.monotonic()
        if self._rt_heartbeat - self._last_watchdog_notify > 1.0:
            self._last_watchdog_notify = self._rt_heartbeat
            self.notifier.watchdog()

    def _safe_stop(self, speed: Measurement) -> BrakeSupport | None:
        """Nicht freigegeben: Antrieb aus; bei verifizierter Bremse und Bewegung zusätzlich bremsen."""
        coordinator = self.build.coordinator if self.build else None
        if coordinator is None:
            return None
        moving = not speed.usable or abs(speed.value or 0.0) > self.settings.safety.standstill_speed_kmh
        if coordinator.capabilities().brake and moving:
            zero = {Axle.FRONT: WheelCommand.zero(), Axle.REAR: WheelCommand.zero()}
            return coordinator.apply(zero, SAFE_STOP_BRAKE_LEVEL)
        coordinator.neutral()
        return None

    def _emergency_neutral(self) -> None:
        self.drive.reset()
        if self.build and self.build.coordinator:
            self.build.coordinator.emergency_stop_all()

    def _on_loop_stall(self, age_s: float) -> None:
        # Läuft im Supervisor-Thread: nur thread-sichere Aufrufe!
        log.error("Regelschleife reagiert seit %.0f ms nicht – Nullbefehl an alle Controller", age_s * 1000)
        if self.build and self.build.coordinator:
            self.build.coordinator.emergency_stop_all()

    # ================================================================== Überwachung
    def _speed(self, now: float, stale_s: float) -> Measurement:
        diameter = self.build.wheel_diameter_m if self.build else self.settings.hardware.wheel_diameter_m
        return self.telemetry.speed_kmh(now, stale_s, diameter)

    def _evaluate_controllers(self, now: float) -> None:
        if not self.build or self.build.coordinator is None:
            return
        coordinator = self.build.coordinator
        timeout = self.settings.safety.controller_timeout_ms / 1000
        in_grace = coordinator.connected_at is not None and now - coordinator.connected_at < STARTUP_GRACE_S
        offline: list[str] = []
        for axle, status in coordinator.statuses().items():
            name = "vorne" if axle == Axle.FRONT else "hinten"
            last = status.last_feedback_at
            is_offline = last is None or now - last > timeout
            if is_offline and not (in_grace and last is None):
                age = "nie" if last is None else f"{(now - last) * 1000:.0f} ms"
                offline.append(f"Controller {status.controller_id} ({name}), letzte Rückmeldung: {age}")
            history = self._bad_frames[axle]
            history.append((now, status.frames_bad + status.write_errors))
            while history and now - history[0][0] > CHECKSUM_WINDOW_S:
                history.popleft()
            errors = history[-1][1] - history[0][1] if len(history) > 1 else 0
            self.safety.set_condition(
                FaultCode.COMMUNICATION_ERROR,
                f"controller_{axle.value}",
                errors > CHECKSUM_ERRORS_LIMIT,
                f"Controller {status.controller_id} ({name}): {errors} fehlerhafte Pakete in {CHECKSUM_WINDOW_S:.0f} s",
            )
            reason = self.telemetry.invalid_reason.get(axle)
            self.safety.set_condition(
                FaultCode.INVALID_TELEMETRY, f"controller_{axle.value}", reason is not None, reason or ""
            )
        self.safety.set_condition(FaultCode.NO_CONTROLLER, "antrieb", len(offline) == 2, "; ".join(offline))
        self.safety.set_condition(FaultCode.SINGLE_CONTROLLER, "antrieb", len(offline) == 1, "; ".join(offline))

    def _evaluate_battery(self, now: float, stale_s: float) -> float:
        voltage = self.telemetry.battery_voltage(now, stale_s)
        battery = self.settings.battery
        limits = pack_limits(battery)
        if not voltage.usable or voltage.value is None:
            return 1.0
        v = voltage.value
        # Kritisch (mit Haltezeit gegen kurze Lastspitzen und Hysterese beim Zurücksetzen)
        if v < limits["critical_v"]:
            self._battery_low_since = self._battery_low_since or now
            if now - self._battery_low_since >= BATTERY_PERSIST_S:
                self.safety.set_condition(
                    FaultCode.LOW_BATTERY, "akku", True, f"{v:.1f} V < {limits['critical_v']:.1f} V"
                )
        else:
            self._battery_low_since = None
            if v > limits["critical_v"] + HYSTERESIS_V:
                self.safety.set_condition(FaultCode.LOW_BATTERY, "akku", False)
        if v < limits["warning_v"]:
            self._battery_warn_since = self._battery_warn_since or now
            if now - self._battery_warn_since >= BATTERY_PERSIST_S:
                self.safety.set_condition(
                    FaultCode.BATTERY_WARNING, "akku", True, f"{v:.1f} V < {limits['warning_v']:.1f} V"
                )
        else:
            self._battery_warn_since = None
            if v > limits["warning_v"] + HYSTERESIS_V:
                self.safety.set_condition(FaultCode.BATTERY_WARNING, "akku", False)
        if battery.protection_enabled and v < limits["warning_v"]:
            span = max(0.1, limits["warning_v"] - limits["critical_v"])
            return 0.5 + 0.5 * max(0.0, min(1.0, (v - limits["critical_v"]) / span))
        return 1.0

    def _evaluate_temperature(self, now: float, stale_s: float) -> float:
        temps = self.settings.temperature
        factor = 1.0
        critical_detail: list[str] = []
        warning_detail: list[str] = []
        clear_critical = True
        clear_warning = True
        for label, measurement, warn, crit in (
            ("Controller", self.telemetry.controller_temp(now, stale_s), temps.controller_warning_c, temps.controller_critical_c),
            ("Motor", self.telemetry.motor_temp(now, stale_s), temps.motor_warning_c, temps.motor_critical_c),
        ):
            if not measurement.usable or measurement.value is None:
                continue
            t = measurement.value
            if t >= crit:
                critical_detail.append(f"{label} {t:.0f} °C ≥ {crit:.0f} °C")
            if t > crit - TEMP_HYSTERESIS_C:
                clear_critical = False
            if t >= warn:
                warning_detail.append(f"{label} {t:.0f} °C ≥ {warn:.0f} °C")
                factor = min(factor, 1.0 - 0.5 * max(0.0, min(1.0, (t - warn) / max(1.0, crit - warn))))
            if t > warn - TEMP_HYSTERESIS_C:
                clear_warning = False
        if critical_detail:
            self.safety.set_condition(FaultCode.OVER_TEMPERATURE, "temperatur", True, "; ".join(critical_detail))
        elif clear_critical:
            self.safety.set_condition(FaultCode.OVER_TEMPERATURE, "temperatur", False)
        if warning_detail:
            self.safety.set_condition(FaultCode.TEMPERATURE_WARNING, "temperatur", True, "; ".join(warning_detail))
        elif clear_warning:
            self.safety.set_condition(FaultCode.TEMPERATURE_WARNING, "temperatur", False)
        return factor

    def _evaluate_owner_connection(self, now: float) -> None:
        owner = self.sessions.owner()
        if owner is None:
            return
        timeout = self.settings.safety.connection_timeout_ms / 1000
        if now - owner.last_message_at > timeout:
            if self._owner_timeout_reported != owner.id:
                self._owner_timeout_reported = owner.id
                owner.reset_input()
                if self.safety.armed:
                    self.safety.raise_fault(
                        FaultCode.CONNECTION_LOST, "steuergeraet",
                        f"Keine Nachricht seit {(now - owner.last_message_at) * 1000:.0f} ms",
                    )
                    self.safety.disarm("Verbindung zum Steuergerät verloren")
        elif self._owner_timeout_reported == owner.id:
            self._owner_timeout_reported = None

    def _current_input(self, now: float) -> DriverInput:
        owner = self.sessions.owner()
        if not self.safety.armed:
            # Gesperrt: eine alte Veraltet-Warnung ist gegenstandslos (Neutral gilt ohnehin).
            self.safety.set_condition(FaultCode.COMMAND_STALE, "fahranforderung", False)
            return DriverInput.neutral()
        if owner is None or owner.input_received_at is None:
            return DriverInput.neutral()
        age = now - owner.input_received_at
        if age > self.settings.safety.command_timeout_ms / 1000:
            if not self.safety.neutral_required:
                self.safety.neutral_required = True
                self.safety.set_condition(
                    FaultCode.COMMAND_STALE, "fahranforderung", True, f"Letzter Befehl vor {age * 1000:.0f} ms"
                )
            owner.reset_input()
            owner.input_received_at = None
            return DriverInput.neutral()
        inp = owner.input
        if self.safety.neutral_required:
            if inp.is_neutral:
                self.safety.neutral_required = False
                self.safety.set_condition(FaultCode.COMMAND_STALE, "fahranforderung", False)
            else:
                return DriverInput(0.0, inp.brake, inp.steer)
        return inp

    def _update_brake_state(
        self, inp: DriverInput, output: DriveOutput, support: BrakeSupport | None, speed: Measurement, now: float
    ) -> None:
        standstill = self.settings.safety.standstill_speed_kmh
        speed_ok = speed.usable and speed.value is not None
        moving = speed_ok and abs(speed.value or 0.0) > standstill
        if not self.safety.armed:
            self.brake_state = BrakeState.INACTIVE
            return
        if inp.brake > 0:
            if support == BrakeSupport.DRIVE_OFF_ONLY:
                self.brake_state = BrakeState.UNSUPPORTED
            elif speed_ok and (not moving or self._measured_deceleration(now) >= 1.0):
                self.brake_state = BrakeState.CONFIRMED
            else:
                self.brake_state = BrakeState.REQUESTED
        elif output.target_throttle <= 0 and moving:
            self.brake_state = BrakeState.COASTING
        else:
            self.brake_state = BrakeState.INACTIVE

    def _measured_deceleration(self, now: float) -> float:
        """Gemessene Verzögerung in km/h pro s über die letzten ≈0,3 s (positiv = langsamer)."""
        samples = [(t, abs(v)) for t, v in self._speed_history if now - t <= 0.35]
        if len(samples) < 2:
            return 0.0
        (t0, v0), (t1, v1) = samples[0], samples[-1]
        if t1 - t0 < 0.1:
            return 0.0
        return (v0 - v1) / (t1 - t0)

    # ================================================================== Ableitungen
    def effective_profile(self, name: DriveProfileName | None = None) -> EffectiveProfile:
        profile = self.settings.profiles.get(name or self.profile)
        commissioning = bool(self.build and self.build.commissioning)
        return effective_profile(profile, self.settings.safety, commissioning=commissioning)

    def _weights(self) -> tuple[float, float]:
        available, _ = axle_distribution_available(self.mode, self._build_hardware)
        return axle_weights(self.drive_mode, self.settings.power_split, available)

    def controllers_fresh(self, now: float) -> list[str]:
        problems = []
        if not self.build or self.build.coordinator is None:
            return ["Kein Antrieb initialisiert"]
        timeout = self.settings.safety.controller_timeout_ms / 1000
        for axle, status in self.build.coordinator.statuses().items():
            if status.last_feedback_at is None or now - status.last_feedback_at > timeout:
                problems.append(f"Controller {status.controller_id} ohne aktuelle Rückmeldung")
        return problems

    def arm_preconditions(self, session: Session) -> list[str]:
        now = self.clock.monotonic()
        failed = self.controllers_fresh(now)
        if session.input.throttle > 0:
            failed.append("Gas muss losgelassen sein")
        speed = self._speed(now, self.settings.safety.telemetry_stale_ms / 1000)
        if not speed.usable:
            failed.append("Geschwindigkeit nicht messbar")
        elif abs(speed.value or 0.0) > self.settings.safety.standstill_speed_kmh:
            failed.append("Fahrzeug muss stehen")
        if not drive_mode_availability(self.mode, self._build_hardware)[self.drive_mode].available:
            failed.append("Gewählter Antriebsmodus nicht verfügbar")
        return failed

    def is_standing(self) -> bool:
        speed = self._speed(self.clock.monotonic(), self.settings.safety.telemetry_stale_ms / 1000)
        return speed.usable and abs(speed.value or 0.0) <= self.settings.safety.standstill_speed_kmh

    # ================================================================== Sitzungen
    def open_session(self, client_id: str, role: Role, device: str, remote: str | None) -> Session:
        session = self.sessions.open(client_id, role, device, remote)
        reclaimed = False
        if self.sessions.can_auto_reclaim(session):
            self.sessions.claim(session)
            reclaimed = True
        self.events.info(
            "SESSION_OPEN", "verbindung", f"Gerät verbunden ({device})",
            {"sitzung": session.id, "rolle": role.value, "steuerung": reclaimed},
        )
        self._broadcast_now.set()
        return session

    def close_session(self, session: Session) -> None:
        was_owner = self.sessions.close(session.id)
        if was_owner:
            if self.safety.armed:
                self.safety.raise_fault(FaultCode.CONNECTION_LOST, "steuergeraet", "Verbindung des steuernden Geräts getrennt")
                self.safety.disarm("Steuernde Verbindung getrennt")
            self.events.warning("SESSION_CLOSE", "verbindung", f"Steuerndes Gerät getrennt ({session.device})", {"sitzung": session.id})
        else:
            self.events.info("SESSION_CLOSE", "verbindung", f"Gerät getrennt ({session.device})", {"sitzung": session.id})
        self._broadcast_now.set()

    def welcome(self, session: Session) -> dict[str, Any]:
        return {
            "type": "welcome",
            "protocol": PROTOCOL_VERSION,
            "version": __version__,
            "session_id": session.id,
            "role": session.role.value,
            "mode": self.mode.value,
            "server_time": self.clock.wall_ms(),
            "settings": self.settings.model_dump(mode="json"),
            "settings_version": self.store.version,
            "capabilities": self.capabilities(),
            "fault_catalog": [d.to_dict() for d in FAULT_CATALOG.values()],
            "events": self.events.recent(50),
        }

    def capabilities(self) -> dict[str, Any]:
        coordinator = self.build.coordinator if self.build else None
        caps = coordinator.capabilities() if coordinator else None
        dist_ok, dist_reason = axle_distribution_available(self.mode, self._build_hardware)
        if caps and caps.brake:
            brake_note = "Simulierte Bremse" if caps.simulated else f"Verifizierte Bremsmethode: {caps.brake_method}"
        else:
            brake_note = "Keine verifizierte Bremsfunktion – Bremse schaltet nur den Antrieb ab. Kein garantiertes Bremsen."
        return {
            "mode": self.mode.value,
            "drive_modes": {m.value: a.to_dict() for m, a in drive_mode_availability(self.mode, self._build_hardware).items()},
            "axle_distribution": {"available": dist_ok, "reason": dist_reason},
            "brake": {"available": bool(caps and caps.brake), "method": caps.brake_method if caps else "none", "note": brake_note},
            "measurements": {
                "speed": bool(caps and caps.speed_feedback),
                "voltage": bool(caps and caps.voltage_feedback),
                "controller_temperature": bool(caps and caps.controller_temperature),
                "motor_temperature": bool(caps and caps.motor_temperature),
                "electrical_power": bool(caps and caps.electrical_power),
            },
            "commissioning": bool(self.build and self.build.commissioning),
            "hardware_init_error": self.build.init_error if self.build else None,
            "readiness": [item.to_dict() for item in (self.build.readiness if self.build else [])],
            "restart_required": self.restart_required,
            "simulation_faults": SIMULATION_FAULTS if self.mode == OperatingMode.SIMULATION else {},
            "battery_limits": pack_limits(self.settings.battery),
            "effective_profiles": {p.value: self.effective_profile(p).to_dict() for p in DriveProfileName},
            "wheel_diameter_m": self.build.wheel_diameter_m if self.build else None,
        }

    # ================================================================== Nachrichten
    async def handle_message(self, session: Session, msg: Any) -> None:
        now = self.clock.monotonic()
        session.last_message_at = now
        kind = msg.type
        if kind == "ping":
            session.rtt_ms = msg.rtt_ms
            session.send({"type": "pong", "ts": msg.ts, "server_ts": self.clock.wall_ms()})
            return
        if kind == "hello":
            self._reject(session, kind, None, "PROTOCOL", "Hello wurde bereits verarbeitet")
            return
        safety = self.settings.safety
        try:
            session.gate.check(msg.seq, msg.ts, max_age_ms=safety.max_command_age_ms, max_rate_hz=safety.max_command_rate_hz)
        except CommandRejected as exc:
            self._reject(session, kind, msg.seq, exc.code, exc.message)
            return

        if kind == "estop":
            self.trigger_emergency_stop(f"Gerät {session.device}", msg.reason)
            self._ack(session, msg)
            return
        if kind == "claim_control":
            ok, reason = self.sessions.claim(session)
            if ok:
                self.events.info("CONTROL", "verbindung", f"Steuerung durch {session.device} übernommen", {"sitzung": session.id})
            self._ack(session, msg, ok, None if ok else "CONTROL_BUSY", reason)
            self._broadcast_now.set()
            return
        if kind == "release_control":
            if self.sessions.is_owner(session):
                self.safety.disarm("Steuerung abgegeben")
                self.sessions.release(session)
                self.events.info("CONTROL", "verbindung", f"Steuerung von {session.device} abgegeben")
            self._ack(session, msg)
            self._broadcast_now.set()
            return
        if kind == "takeover_control":
            self._takeover(session, msg)
            return

        if kind in OWNER_ONLY and not self.sessions.is_owner(session):
            self._reject(session, kind, msg.seq, "NOT_OWNER", "Nur das steuernde Gerät darf diesen Befehl senden")
            return

        handler: Callable[[Session, Any], Any] | None = getattr(self, f"_on_{kind}", None)
        if handler is None:  # pragma: no cover - durch das Nachrichtenmodell ausgeschlossen
            self._reject(session, kind, msg.seq, "UNKNOWN", "Unbekannter Nachrichtentyp")
            return
        result = handler(session, msg)
        if asyncio.iscoroutine(result):
            await result

    def _on_drive(self, session: Session, msg: Any) -> None:
        now = self.clock.monotonic()
        if msg.throttle > 0 and msg.brake > 0:
            # Widersprüchlich: verwerfen, sicher interpretieren (kein Gas, Bremse bleibt).
            session.input = DriverInput(0.0, msg.brake, msg.steer)
            session.input_received_at = now
            self._reject(session, "drive", msg.seq, "CONTRADICTORY", "Gas und Bremse gleichzeitig – Gas verworfen")
            return
        if msg.profile != self.profile:
            self._reject(session, "drive", msg.seq, "PROFILE_MISMATCH",
                         f"Befehl für Profil {msg.profile.value}, aktiv ist {self.profile.value}", log_event=False)
            return
        session.input = DriverInput(msg.throttle, msg.brake, msg.steer)
        session.input_source = msg.source
        session.input_received_at = now

    def _on_set_profile(self, session: Session, msg: Any) -> None:
        if msg.profile != self.profile:
            self.events.info("PROFILE", "fahrmodus", f"Fahrprofil: {msg.profile.value}", {"vorher": self.profile.value})
            self.profile = msg.profile
        self._ack(session, msg)
        self._broadcast_now.set()

    def _on_set_drive_mode(self, session: Session, msg: Any) -> None:
        availability = drive_mode_availability(self.mode, self._build_hardware)[msg.mode]
        if not availability.available:
            self._ack(session, msg, False, "UNAVAILABLE", availability.reason)
            return
        if msg.mode != self.drive_mode:
            self.events.info("DRIVE_MODE", "antrieb", f"Antriebsmodus: {msg.mode.value}", {"vorher": self.drive_mode.value})
            self.drive_mode = msg.mode
        self._ack(session, msg)
        self._broadcast_now.set()

    async def _on_set_power_split(self, session: Session, msg: Any) -> None:
        available, reason = axle_distribution_available(self.mode, self._build_hardware)
        if not available:
            self._ack(session, msg, False, "UNAVAILABLE", reason)
            return
        key = "awd_front_percent" if msg.target == "awd" else "custom_front_percent"
        await self._save_patch(session, msg, {"power_split": {key: round(msg.front_percent, 1)}})

    def _on_set_direction(self, session: Session, msg: Any) -> None:
        if msg.direction == self.direction:
            self._ack(session, msg)
            return
        if not self.is_standing() or session.input.throttle > 0:
            self._ack(session, msg, False, "NOT_STANDING", "Fahrtrichtung nur im Stillstand und ohne Gas umschaltbar")
            return
        self.direction = msg.direction
        self.drive.reset()
        self.events.info("DIRECTION", "fahrmodus", "Fahrtrichtung: " + ("vorwärts" if msg.direction == Direction.FORWARD else "rückwärts"))
        self._ack(session, msg)
        self._broadcast_now.set()

    async def _on_update_settings(self, session: Session, msg: Any) -> None:
        await self._save_patch(session, msg, msg.patch, expected_version=msg.expected_version)

    async def _on_reset_profiles(self, session: Session, msg: Any) -> None:
        await self._save_patch(session, msg, {"profiles": ProfilesSettings().model_dump(mode="json")})

    def _on_arm(self, session: Session, msg: Any) -> None:
        ok, reason = self.safety.arm(self.arm_preconditions(session))
        if ok:
            self.drive.reset()
            self.events.info("ARM", "sicherheit", f"Motoren freigegeben durch {session.device}")
        self._ack(session, msg, ok, None if ok else "ARM_REFUSED", reason)
        self._broadcast_now.set()

    def _on_disarm(self, session: Session, msg: Any) -> None:
        self.safety.disarm("Motoren durch Fahrer gesperrt")
        self._ack(session, msg)
        self._broadcast_now.set()

    def _on_estop_reset(self, session: Session, msg: Any) -> None:
        if session.input.throttle > 0:
            self._ack(session, msg, False, "NOT_NEUTRAL", "Gas muss losgelassen sein")
            return
        ok = self.safety.reset_emergency_stop()
        self._ack(session, msg, ok, None if ok else "NOT_ACTIVE", None if ok else "Not-Aus ist nicht aktiv")
        self._broadcast_now.set()

    def _on_ack_faults(self, session: Session, msg: Any) -> None:
        removed, remaining = self.safety.acknowledge()
        if remaining:
            titles = ", ".join(sorted({f"{f.code.value} {FAULT_CATALOG[f.code].title}" for f in remaining}))
            self._ack(session, msg, False, "FAULTS_ACTIVE", f"Noch aktiv: {titles}")
        else:
            self._ack(session, msg, True, None, f"{removed} Fehler quittiert")
        self._broadcast_now.set()

    def _on_reset_trip(self, session: Session, msg: Any) -> None:
        self._trip_s = 0.0
        self._ack(session, msg)

    def _on_sim_inject(self, session: Session, msg: Any) -> None:
        if self.mode != OperatingMode.SIMULATION or not self.build or self.build.sim_faults is None:
            self._ack(session, msg, False, "NOT_SIMULATION", "Fehlerinjektion nur im Simulationsmodus")
            return
        try:
            self.build.sim_faults.set(msg.fault, msg.active)
        except KeyError:
            self._ack(session, msg, False, "UNKNOWN_FAULT", "Unbekannter Simulationsfehler")
            return
        physics = self.build.physics
        faults = self.build.sim_faults
        limits = pack_limits(self.settings.battery)
        if physics is not None:
            if faults.battery_critical:
                physics.forced_voltage = limits["critical_v"] - 0.6
            elif faults.battery_warning:
                physics.forced_voltage = limits["warning_v"] - 0.4
            else:
                physics.forced_voltage = None
            physics.forced_controller_temp = self.settings.temperature.controller_critical_c + 6 if faults.overtemperature else None
        self.wifi.weak_override = faults.wifi_weak
        self.events.warning(
            "SIM_FAULT", "simulation",
            f"Simulationsfehler {'aktiviert' if msg.active else 'deaktiviert'}: {SIMULATION_FAULTS[msg.fault]}",
        )
        self._ack(session, msg)
        self._broadcast_now.set()

    def _takeover(self, session: Session, msg: Any) -> None:
        current = self.sessions.owner()
        if current is not None and current.id == session.id:
            self._ack(session, msg)
            return
        owner_stale = current is not None and (
            self.clock.monotonic() - current.last_message_at > self.settings.safety.connection_timeout_ms / 1000
        )
        if self.safety.armed and not owner_stale and not self.is_standing():
            self._ack(session, msg, False, "VEHICLE_MOVING", "Übernahme nur im Stillstand möglich")
            return
        if self.safety.armed:
            self.safety.disarm("Steuerung von anderem Gerät übernommen")
        previous = self.sessions.takeover(session)
        if previous is not None:
            previous.reset_input()
            previous.send({
                "type": "connection",
                "event": "control_lost",
                "message": f"Die Steuerung wurde von {session.device} übernommen. Motoren gesperrt.",
            })
            self.events.record(
                FAULT_CATALOG[FaultCode.CONTROL_TAKEN_OVER].severity,
                FaultCode.CONTROL_TAKEN_OVER.value,
                "verbindung",
                f"Steuerung von {previous.device} an {session.device} übergeben",
            )
        else:
            self.events.info("CONTROL", "verbindung", f"Steuerung durch {session.device} übernommen")
        self._ack(session, msg)
        self._broadcast_now.set()

    async def _save_patch(self, session: Session, msg: Any, patch: dict[str, Any], expected_version: int | None = None) -> None:
        try:
            new_settings = apply_settings_patch(self.settings, patch, allow_admin=session.role == Role.ADMIN)
            version = await self.store.save(new_settings, f"websocket:{session.device}", expected_version)
        except SettingsPatchError as exc:
            self._ack(session, msg, False, "INVALID_SETTINGS", str(exc), details=exc.details)
            self.events.warning("CONFIG_REJECTED", "konfiguration", f"Änderung abgelehnt: {exc}", {"details": exc.details[:5]})
            return
        except VersionConflict as exc:
            self._ack(session, msg, False, "VERSION_CONFLICT", str(exc))
            return
        self._ack(session, msg, True, None, None, version=version)

    def trigger_emergency_stop(self, source: str, reason: str = "") -> None:
        self.safety.emergency_stop(source, reason)
        self._emergency_neutral()
        for s in self.sessions.sessions.values():
            s.reset_input()
        self._broadcast_now.set()

    def _ack(
        self, session: Session, msg: Any, ok: bool = True, code: str | None = None, message: str | None = None, **extra: Any
    ) -> None:
        payload: dict[str, Any] = {"type": "ack", "ref_type": msg.type, "ref_seq": msg.seq, "ok": ok}
        if code:
            payload["code"] = code
        if message:
            payload["message"] = message
        payload.update(extra)
        session.send(payload)

    def _reject(
        self, session: Session, kind: str, seq: int | None, code: str, message: str, *, log_event: bool = True
    ) -> None:
        session.send({"type": "ack", "ref_type": kind, "ref_seq": seq, "ok": False, "code": code, "message": message})
        if log_event:
            self.events.warning(
                FaultCode.INVALID_COMMAND.value, "befehl", f"Befehl abgelehnt ({code}): {message}",
                {"typ": kind, "sitzung": session.id}, throttle_key=f"reject:{session.id}:{code}",
            )
        self.register_invalid(session)

    def register_invalid(self, session: Session) -> None:
        now = self.clock.monotonic()
        if now - session.invalid_window_start > INVALID_WINDOW_S:
            session.invalid_window_start = now
            session.invalid_messages = 0
        session.invalid_messages += 1
        if session.invalid_messages > INVALID_MESSAGES_LIMIT:
            raise ProtocolViolation("Zu viele ungültige Nachrichten")

    # ================================================================== Telemetrie
    def snapshot(self) -> dict[str, Any]:
        now = self.clock.monotonic()
        settings = self.settings
        stale_s = settings.safety.telemetry_stale_ms / 1000
        t = self.telemetry
        voltage = t.battery_voltage(now, stale_s)
        speed = self._speed(now, stale_s)
        wifi = self.wifi.measurement(now)
        self._telemetry_seq += 1
        controllers = []
        coordinator = self.build.coordinator if self.build else None
        if coordinator is not None:
            for axle, controller in coordinator.controllers.items():
                rpm_l, rpm_r = t.wheel_measurements(axle, now, stale_s)
                controllers.append({
                    **controller.get_status().to_dict(now),
                    "capabilities": controller.capabilities.to_dict(),
                    "rpm_left": rpm_l.to_dict(1),
                    "rpm_right": rpm_r.to_dict(1),
                    "voltage": t.axles[axle].voltage.measurement(now, stale_s).to_dict(),
                    "controller_temp_c": t.controller_temp(now, stale_s, axle).to_dict(1),
                    "motor_temp_c": t.motor_temp(now, stale_s, axle).to_dict(1),
                    "electrical_power_w": t.electrical_power(now, stale_s, axle).to_dict(0),
                })
        out = self.last_output
        dist_ok, _ = axle_distribution_available(self.mode, self._build_hardware)
        weights = self._weights()
        scales = axle_scales(*weights)
        periods = list(self._loop_periods)
        loop_hz = (len(periods) / sum(periods)) if periods and sum(periods) > 0 else None
        speed_display = speed
        if speed.value is not None:
            speed_display = Measurement(abs(speed.value), speed.status, speed.age_ms, speed.unit)
        return {
            "type": "telemetry",
            "seq": self._telemetry_seq,
            "ts": self.clock.wall_ms(),
            "mode": self.mode.value,
            "vehicle": {
                "state": self.safety.state.value,
                "armed": self.safety.armed,
                "neutral_required": self.safety.neutral_required,
                "estop": self.safety.emergency_stop_active,
                "direction": self.direction.value,
                "profile": self.profile.value,
                "drive_mode": self.drive_mode.value,
                "brake_state": self.brake_state.value,
                "brake_support": self.brake_support.value if self.brake_support else None,
                "trip_s": int(self._trip_s),
                "total_drive_s": int(self._total_s),
                "restart_required": self.restart_required,
                "commissioning": bool(self.build and self.build.commissioning),
                "sim_faults": self.build.sim_faults.active() if self.build and self.build.sim_faults else [],
            },
            "measurements": {
                "speed_kmh": speed_display.to_dict(1),
                "motor_rpm": t.motor_rpm(now, stale_s).to_dict(0),
                "battery_voltage": voltage.to_dict(2),
                "battery_percent": t.battery_percent(voltage, settings.battery).to_dict(0),
                "controller_temp_c": t.controller_temp(now, stale_s).to_dict(1),
                "motor_temp_c": t.motor_temp(now, stale_s).to_dict(1),
                "electrical_power_w": t.electrical_power(now, stale_s).to_dict(0),
                "wifi_signal_dbm": wifi.to_dict(0),
                "wifi_quality": signal_quality(wifi.value if wifi.usable else None),
            },
            "control": {
                "input": {
                    "throttle": round(self.last_input.throttle, 3),
                    "brake": round(self.last_input.brake, 3),
                    "steer": round(self.last_input.steer, 3),
                },
                "output": out.to_dict(),
                "split": {
                    "front_weight": round(weights[0], 1),
                    "rear_weight": round(weights[1], 1),
                    "front_scale": round(scales[0], 3),
                    "rear_scale": round(scales[1], 3),
                    "distribution_available": dist_ok,
                },
                "effective_profile": self.effective_profile().to_dict(),
            },
            "controllers": controllers,
            "faults": [f.to_dict() for f in self.safety.faults()],
            "system": {
                "loop_hz": round(loop_hz, 1) if loop_hz else None,
                "loop_max_ms": round(max(periods) * 1000, 1) if periods else None,
                "uptime_s": int(now - self._started_at),
                **self._system_cache,
            },
        }

    def session_info(self, session: Session) -> dict[str, Any]:
        owner = self.sessions.owner()
        is_owner = owner is not None and owner.id == session.id
        can_takeover = not is_owner and (owner is None or not self.safety.armed or self.is_standing())
        return {
            "id": session.id,
            "role": session.role.value,
            "is_owner": is_owner,
            "owner_present": owner is not None,
            "owner_device": owner.device if owner else None,
            "count": len(self.sessions.sessions),
            "can_takeover": can_takeover,
        }

    async def _broadcast_loop(self) -> None:
        while True:
            period = 1.0 / self.settings.telemetry.broadcast_hz
            try:
                await asyncio.wait_for(self._broadcast_now.wait(), timeout=period)
            except asyncio.TimeoutError:
                pass
            self._broadcast_now.clear()
            self.broadcast_telemetry()

    def broadcast_telemetry(self) -> None:
        if not self.sessions.sessions:
            return
        base = self.snapshot()
        for session in list(self.sessions.sessions.values()):
            payload = dict(base)
            payload["session"] = self.session_info(session)
            session.push_telemetry(json.dumps(payload, separators=(",", ":"), ensure_ascii=False))

    async def _monitor_loop(self) -> None:
        counter = 0
        while True:
            owner = self.sessions.owner()
            remote = owner.remote if owner else next((s.remote for s in self.sessions.sessions.values()), None)
            try:
                await self.wifi.refresh(remote)
                if counter % 3 == 0:
                    self._system_cache = await asyncio.to_thread(self._system_summary)
                if counter % 30 == 0:
                    await asyncio.to_thread(self._persist_total)
            except Exception:  # pragma: no cover - Überwachung darf nicht abbrechen
                log.exception("Monitor-Schleife")
            counter += 1
            await asyncio.sleep(2.0)

    def _system_summary(self) -> dict[str, Any]:
        snap = self.system_monitor.snapshot()
        return {
            "cpu_temp_c": snap["cpu_temp_c"],
            "load_1m": snap["load_avg"][0],
            "mem_available_mb": snap["mem_available_mb"],
            "process_rss_mb": snap["process_rss_mb"],
            "throttled": snap["throttled"],
        }

    def _persist_total(self, force: bool = False) -> None:
        if self.db is None:
            return
        try:
            self.db.set_kv("total_drive_s", f"{self._total_s:.1f}")
        except Exception:  # pragma: no cover - Speicherfehler nicht fatal
            log.exception("Betriebsstunden konnten nicht gespeichert werden")

    # ================================================================== Rückmeldungen
    def _on_event(self, event: Event) -> None:
        self.sessions.broadcast({"type": "event", "event": event.to_dict()})

    def _on_state_change(self, old: VehicleState, new: VehicleState, reason: str) -> None:
        if new != VehicleState.ARMED:
            # Sofort neutral – nicht erst im nächsten Regelzyklus.
            self.drive.reset()
            self.last_output = DriveOutput(weights=self.last_output.weights, scales=self.last_output.scales)
            self.last_input = DriverInput.neutral()
            for session in self.sessions.sessions.values():
                session.reset_input()
            if old == VehicleState.ARMED and self.build and self.build.coordinator:
                self.build.coordinator.neutral()
        self._broadcast_now.set()

    def _on_settings_changed(self, settings: VehicleSettings, version: int, source: str) -> None:
        self.sessions.max_sessions = settings.safety.max_sessions
        self._supervisor.stall_after_s = settings.safety.loop_stall_ms / 1000
        hardware_changed = settings.hardware.model_dump() != self._build_hardware.model_dump()
        if hardware_changed and not self.restart_required:
            self.restart_required = True
            self.events.warning("RESTART_REQUIRED", "konfiguration",
                                "Hardware-Einstellungen geändert – wirksam erst nach Neustart des Dienstes")
        elif not hardware_changed:
            self.restart_required = False
        self.events.info("CONFIG", "konfiguration", f"Einstellungen gespeichert (Version {version})", {"quelle": source})
        self.sessions.broadcast({
            "type": "settings",
            "version": version,
            "settings": settings.model_dump(mode="json"),
            "capabilities": self.capabilities(),
        })
        self._broadcast_now.set()
