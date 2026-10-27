"""Fehlerinjektion für den Simulationsmodus.

Damit lassen sich Sicherheitsreaktionen und Fehleranzeigen gefahrlos testen. Im Hardwaremodus ist
die Fehlerinjektion deaktiviert.
"""

from __future__ import annotations

from dataclasses import dataclass, fields

from ..models.common import Axle

SIMULATION_FAULTS: dict[str, str] = {
    "front_offline": "Controller vorne ohne Rückmeldung",
    "rear_offline": "Controller hinten ohne Rückmeldung",
    "front_invalid_data": "Controller vorne liefert ungültige Messwerte",
    "rear_comm_errors": "Controller hinten mit Prüfsummenfehlern",
    "overtemperature": "Übertemperatur Controller",
    "battery_warning": "Akkuspannung niedrig",
    "battery_critical": "Akkuspannung kritisch",
    "wifi_weak": "Schwaches WLAN-Signal",
}


@dataclass
class SimulationFaults:
    front_offline: bool = False
    rear_offline: bool = False
    front_invalid_data: bool = False
    rear_comm_errors: bool = False
    overtemperature: bool = False
    battery_warning: bool = False
    battery_critical: bool = False
    wifi_weak: bool = False

    def set(self, name: str, active: bool) -> None:
        if name not in SIMULATION_FAULTS:
            raise KeyError(name)
        setattr(self, name, bool(active))

    def offline(self, axle: Axle) -> bool:
        return self.front_offline if axle == Axle.FRONT else self.rear_offline

    def invalid_data(self, axle: Axle) -> bool:
        return self.front_invalid_data and axle == Axle.FRONT

    def comm_errors(self, axle: Axle) -> bool:
        return self.rear_comm_errors and axle == Axle.REAR

    def active(self) -> list[str]:
        return [f.name for f in fields(self) if getattr(self, f.name)]

    def clear(self) -> None:
        for f in fields(self):
            setattr(self, f.name, False)
