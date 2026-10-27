"""Koordination beider Motorcontroller (Vorder- und Hinterachse).

* Verteilt Rad- bzw. Bremsanforderungen an den jeweils zugeordneten Controller.
* Liest beide Controller unabhängig aus; die Überwachung (Zeitüberschreitung je Controller)
  übernimmt der Watchdog im Fahrzeugdienst. Fällt einer aus, geht das gesamte Fahrzeug in den
  sicheren Zustand.
* ``emergency_stop_all`` ist thread-sicher und wird auch vom Loop-Supervisor-Thread verwendet.
"""

from __future__ import annotations

import asyncio
import logging

from ..models.common import Axle
from .base import (
    BrakeSupport,
    ControllerCapabilities,
    ControllerStatus,
    ControllerTelemetry,
    MotorControllerInterface,
    WheelCommand,
)

log = logging.getLogger(__name__)


class DrivetrainCoordinator:
    def __init__(self, controllers: list[MotorControllerInterface]) -> None:
        by_axle: dict[Axle, MotorControllerInterface] = {}
        for controller in controllers:
            if controller.axle in by_axle:
                raise ValueError(f"Achse {controller.axle.value} ist doppelt zugeordnet")
            by_axle[controller.axle] = controller
        if set(by_axle) != {Axle.FRONT, Axle.REAR}:
            raise ValueError("Es wird je ein Controller für Vorder- und Hinterachse benötigt")
        self._controllers = by_axle
        self.connected_at: float | None = None

    @property
    def controllers(self) -> dict[Axle, MotorControllerInterface]:
        return self._controllers

    def capabilities(self) -> ControllerCapabilities:
        """Fähigkeiten des Gesamtantriebs: eine Funktion gilt nur, wenn **beide** Controller sie bieten."""
        caps = [c.capabilities for c in self._controllers.values()]
        return ControllerCapabilities(
            brake=all(c.brake for c in caps),
            brake_method=caps[0].brake_method if all(c.brake for c in caps) else "none",
            speed_feedback=all(c.speed_feedback for c in caps),
            voltage_feedback=any(c.voltage_feedback for c in caps),
            controller_temperature=all(c.controller_temperature for c in caps),
            motor_temperature=all(c.motor_temperature for c in caps),
            electrical_power=all(c.electrical_power for c in caps),
            internal_speed_limit=all(c.internal_speed_limit for c in caps),
            simulated=all(c.simulated for c in caps),
        )

    async def connect_all(self, now: float) -> None:
        await asyncio.gather(*(c.connect() for c in self._controllers.values()))
        self.connected_at = now
        for controller in self._controllers.values():
            controller.set_drive_request(WheelCommand.zero())

    async def close_all(self) -> None:
        self.emergency_stop_all()
        for controller in self._controllers.values():
            try:
                await controller.close()
            except Exception:  # pragma: no cover - best effort beim Beenden
                log.exception("Controller %s ließ sich nicht schließen", controller.controller_id)

    def poll(self) -> dict[Axle, ControllerTelemetry | None]:
        result: dict[Axle, ControllerTelemetry | None] = {}
        for axle, controller in self._controllers.items():
            try:
                result[axle] = controller.read_telemetry()
            except Exception as exc:  # Adapterfehler dürfen die Regelschleife nicht beenden
                log.exception("Lesefehler Controller %s", controller.controller_id)
                controller.get_status().last_error = str(exc)
                result[axle] = None
        return result

    def apply(self, wheels: dict[Axle, WheelCommand], brake_level: float) -> BrakeSupport | None:
        """Sendet Fahr- oder Bremsanforderungen. Gibt die Bremsumsetzung zurück (None = keine Bremse)."""
        support: BrakeSupport | None = None
        for axle, controller in self._controllers.items():
            try:
                if brake_level > 0:
                    result = controller.request_brake(brake_level)
                    if support is None or result == BrakeSupport.DRIVE_OFF_ONLY:
                        support = result
                else:
                    controller.set_drive_request(wheels.get(axle, WheelCommand.zero()))
            except Exception:
                log.exception("Sendefehler Controller %s – Not-Aus für alle", controller.controller_id)
                self.emergency_stop_all()
                return BrakeSupport.DRIVE_OFF_ONLY
        return support

    def neutral(self) -> None:
        for controller in self._controllers.values():
            try:
                controller.set_drive_request(WheelCommand.zero())
            except Exception:
                log.exception("Nullbefehl an %s fehlgeschlagen", controller.controller_id)

    def emergency_stop_all(self) -> None:
        for controller in self._controllers.values():
            try:
                controller.emergency_stop()
            except Exception:  # pragma: no cover - best effort
                log.exception("Not-Aus an %s fehlgeschlagen", controller.controller_id)

    def statuses(self) -> dict[Axle, ControllerStatus]:
        return {axle: c.get_status() for axle, c in self._controllers.items()}
