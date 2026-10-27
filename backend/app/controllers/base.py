"""Gemeinsame Schnittstelle aller Motorcontroller-Adapter.

Architektur
-----------
Ein Adapter steuert **einen** Hoverboard-Controller (= eine Achse mit linkem und rechtem Motor).
Der ``DrivetrainCoordinator`` hält zwei Adapter (vorne/hinten), verteilt die Befehle und überwacht
beide unabhängig. Die Regelschleife ruft pro Zyklus:

1. ``read_telemetry()`` – nicht blockierend, liefert die zuletzt dekodierte Rückmeldung.
2. ``set_drive_request()`` bzw. ``request_brake()`` – nicht blockierend, sendet sofort.

Konventionen
------------
* Befehle sind normiert: ``-1.0 … +1.0`` je Rad, positiv = vorwärts. Die Umrechnung in Rohwerte,
  Vorzeichen und Seitenvertauschung ist Sache des Adapters (konfigurierbar, bei Inbetriebnahme zu prüfen).
* Rückmeldungen werden in physikalische Einheiten umgerechnet (U/min, V, °C). Nicht gemessene Größen
  sind ``None`` – sie werden niemals geschätzt oder erfunden.
* ``emergency_stop()`` muss thread-sicher sein, weil der Loop-Supervisor-Thread sie aufrufen kann,
  wenn die asyncio-Schleife hängt.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from enum import StrEnum

from ..models.common import Axle, ControllerLinkState


@dataclass(frozen=True)
class WheelCommand:
    """Normierte Anforderung je Rad einer Achse (-1 … +1, positiv = vorwärts)."""

    left: float = 0.0
    right: float = 0.0

    @staticmethod
    def zero() -> "WheelCommand":
        return WheelCommand(0.0, 0.0)

    def clamped(self) -> "WheelCommand":
        return WheelCommand(max(-1.0, min(1.0, self.left)), max(-1.0, min(1.0, self.right)))

    @property
    def is_zero(self) -> bool:
        return abs(self.left) < 1e-6 and abs(self.right) < 1e-6


class BrakeSupport(StrEnum):
    """Wie eine Bremsanforderung tatsächlich umgesetzt wurde."""

    APPLIED = "applied"  # Verifizierte Bremsfunktion angesteuert
    DRIVE_OFF_ONLY = "drive_off_only"  # Keine verifizierte Bremse: nur Antrieb aus


@dataclass(frozen=True)
class ControllerCapabilities:
    brake: bool = False  # Verifizierte Bremsfunktion vorhanden
    brake_method: str = "none"
    speed_feedback: bool = False
    voltage_feedback: bool = False
    controller_temperature: bool = False
    motor_temperature: bool = False
    electrical_power: bool = False
    internal_speed_limit: bool = False  # Controller begrenzt Geschwindigkeit selbst
    simulated: bool = False

    def to_dict(self) -> dict[str, object]:
        return dict(self.__dict__)


@dataclass(frozen=True)
class ControllerTelemetry:
    """Dekodierte Rückmeldung eines Controllers (``None`` = nicht gemessen)."""

    timestamp: float  # monotone Zeit des Empfangs
    wheel_rpm_left: float | None = None
    wheel_rpm_right: float | None = None
    battery_voltage: float | None = None
    controller_temp_c: float | None = None
    motor_temp_c: float | None = None
    electrical_power_w: float | None = None
    simulated: bool = False
    raw: dict[str, int] = field(default_factory=dict)


@dataclass
class ControllerStatus:
    controller_id: str
    axle: Axle
    adapter: str
    link: ControllerLinkState = ControllerLinkState.DISCONNECTED
    last_feedback_at: float | None = None
    frames_ok: int = 0
    frames_bad: int = 0
    commands_sent: int = 0
    write_errors: int = 0
    last_error: str | None = None
    emergency_stopped: bool = False
    port: str | None = None

    def to_dict(self, now: float) -> dict[str, object]:
        age = None if self.last_feedback_at is None else int(max(0.0, now - self.last_feedback_at) * 1000)
        return {
            "id": self.controller_id,
            "axle": self.axle.value,
            "adapter": self.adapter,
            "link": self.link.value,
            "feedback_age_ms": age,
            "frames_ok": self.frames_ok,
            "frames_bad": self.frames_bad,
            "commands_sent": self.commands_sent,
            "write_errors": self.write_errors,
            "last_error": self.last_error,
            "emergency_stopped": self.emergency_stopped,
            "port": self.port,
        }


class MotorControllerInterface(ABC):
    """Abstrakte Basis für Simulations- und Hardwareadapter."""

    controller_id: str
    axle: Axle

    @property
    @abstractmethod
    def capabilities(self) -> ControllerCapabilities:
        """Statische Fähigkeiten dieses Adapters (aus Konfiguration abgeleitet, nicht geraten)."""

    @abstractmethod
    async def connect(self) -> None:
        """Öffnet die Verbindung. Darf keine Motorbewegung auslösen."""

    @abstractmethod
    async def disconnect(self) -> None:
        """Sendet einen Nullbefehl (best effort) und trennt die Verbindung."""

    @abstractmethod
    def set_drive_request(self, command: WheelCommand) -> None:
        """Sendet eine bereits geprüfte und begrenzte Fahranforderung je Rad."""

    @abstractmethod
    def set_speed_limit(self, limit_kmh: float | None) -> bool:
        """Übermittelt eine Geschwindigkeitsgrenze. ``False``, wenn der Controller dies nicht kann
        (dann begrenzt ausschließlich das Backend)."""

    @abstractmethod
    def request_brake(self, level: float) -> BrakeSupport:
        """Fordert Verzögerung 0…1 an. Ohne verifizierte Bremse wird nur der Antrieb abgeschaltet."""

    @abstractmethod
    def read_telemetry(self) -> ControllerTelemetry | None:
        """Liefert die neueste gültige Rückmeldung (nicht blockierend) oder ``None``."""

    @abstractmethod
    def get_status(self) -> ControllerStatus:
        """Verbindungs- und Kommunikationsstatus."""

    @abstractmethod
    def emergency_stop(self) -> None:
        """Thread-sicherer Nullbefehl. Idempotent, darf nicht blockieren."""

    @abstractmethod
    async def close(self) -> None:
        """Gibt alle Ressourcen frei."""
