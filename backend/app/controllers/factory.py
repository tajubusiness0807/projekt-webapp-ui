"""Aufbau des Antriebs: Simulation (Standard) oder Hardware (nur nach expliziter Freigabe).

Der Hardwaremodus wird **nur beim Start** und nur dann aktiviert, wenn alle Punkte der
Freigabe-Checkliste erfüllt sind. Ist der Hardwaremodus angefordert, aber unvollständig konfiguriert,
startet das Backend ohne Antrieb im Fehlerzustand E009 – es fällt bewusst **nicht** still in die
Simulation zurück, damit Simulation und Hardware nicht verwechselt werden.
"""

from __future__ import annotations

import importlib.util
from dataclasses import dataclass, field

from ..config.env import EnvSettings
from ..models.common import Axle, OperatingMode
from ..models.settings import VehicleSettings
from ..simulation.fault_injection import SimulationFaults
from ..simulation.vehicle_model import VehicleParameters, VehiclePhysics
from ..utils.clock import Clock
from .coordinator import DrivetrainCoordinator
from .foc_serial import HoverboardFocSerialController, SerialFactory
from .simulated import SimulatedMotorController


@dataclass(frozen=True)
class ReadinessItem:
    key: str
    ok: bool
    label: str
    detail: str = ""

    def to_dict(self) -> dict[str, object]:
        return {"key": self.key, "ok": self.ok, "label": self.label, "detail": self.detail}


def hardware_readiness(settings: VehicleSettings, env: EnvSettings) -> list[ReadinessItem]:
    hw = settings.hardware
    ports = [c.port for c in hw.controllers]
    items = [
        ReadinessItem("env", env.hardware_enabled, "Hardware per Umgebungsvariable freigegeben",
                      "AWC_HARDWARE_ENABLED=1 in der Dienstkonfiguration"),
        ReadinessItem("mode", hw.mode == OperatingMode.HARDWARE, "Betriebsart „Hardware“ gewählt"),
        ReadinessItem("model", bool(hw.controller_model.strip()), "Mainboard-Typ eingetragen"),
        ReadinessItem("firmware", hw.firmware == "hoverboard-firmware-hack-foc",
                      "Firmware identifiziert (hoverboard-firmware-hack-FOC)",
                      "Andere Firmware benötigt einen eigenen Adapter"),
        ReadinessItem("firmware_version", bool(hw.firmware_version.strip()), "Firmware-Version/Commit eingetragen"),
        ReadinessItem("variant", hw.firmware_variant_usart, "Firmware mit USART-Steuerung und -Feedback gebaut"),
        ReadinessItem("control_mode", hw.firmware_control_mode != "unknown", "Regelmodus der Firmware bekannt"),
        ReadinessItem("protocol", hw.protocol_verified, "Protokoll am Controller geprüft (Feedback empfangen)"),
        ReadinessItem("levels", hw.signal_levels_verified, "Signalpegel 3,3 V geprüft, 15-V-Leitung nicht angeschlossen"),
        ReadinessItem("wiring", hw.wiring_verified, "Verkabelung, Sicherungen und Hardware-Not-Aus geprüft"),
        ReadinessItem("ports", all(ports) and len(set(ports)) == 2, "Serielle Schnittstellen beider Controller gesetzt"),
        ReadinessItem("wheel", hw.wheel_diameter_verified, "Raddurchmesser nachgemessen"),
        ReadinessItem("pyserial", importlib.util.find_spec("serial") is not None, "Python-Paket pyserial installiert"),
    ]
    return items


@dataclass
class DrivetrainBuild:
    mode: OperatingMode
    coordinator: DrivetrainCoordinator | None
    readiness: list[ReadinessItem] = field(default_factory=list)
    physics: VehiclePhysics | None = None
    sim_faults: SimulationFaults | None = None
    init_error: str | None = None
    wheel_diameter_m: float = 0.165
    commissioning: bool = False


def build_drivetrain(
    settings: VehicleSettings,
    env: EnvSettings,
    clock: Clock,
    serial_factory: SerialFactory | None = None,
) -> DrivetrainBuild:
    readiness = hardware_readiness(settings, env)
    hw = settings.hardware
    if hw.mode == OperatingMode.SIMULATION:
        params = VehicleParameters(
            cells_series=settings.battery.cells_series,
            cell_full_v=settings.battery.cell_full_v,
            cell_empty_v=settings.battery.cell_empty_v,
        )
        physics = VehiclePhysics(params)
        faults = SimulationFaults()
        controllers = [
            SimulatedMotorController(c.id, c.axle, physics, faults, clock) for c in hw.controllers
        ]
        return DrivetrainBuild(
            mode=OperatingMode.SIMULATION,
            coordinator=DrivetrainCoordinator(controllers),
            readiness=readiness,
            physics=physics,
            sim_faults=faults,
            wheel_diameter_m=params.wheel_diameter_m,
        )

    missing = [item.label for item in readiness if not item.ok]
    if missing:
        return DrivetrainBuild(
            mode=OperatingMode.HARDWARE,
            coordinator=None,
            readiness=readiness,
            init_error="Hardware-Checkliste unvollständig: " + "; ".join(missing),
            wheel_diameter_m=hw.wheel_diameter_m,
        )
    controllers = [
        HoverboardFocSerialController(hw.controller_for(axle), hw, clock, serial_factory) for axle in Axle
    ]
    return DrivetrainBuild(
        mode=OperatingMode.HARDWARE,
        coordinator=DrivetrainCoordinator(list(controllers)),
        readiness=readiness,
        wheel_diameter_m=hw.wheel_diameter_m,
        commissioning=not hw.wheels_lifted_test_passed,
    )
