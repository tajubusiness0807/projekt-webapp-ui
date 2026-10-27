"""Gemeinsame Aufzählungen für Backend, Protokoll und Frontend.

Die Zeichenkettenwerte sind Teil des dokumentierten WebSocket-Protokolls
(siehe ``docs/communication-protocol.md``) und dürfen nicht ohne Protokollversionierung geändert werden.
"""

from __future__ import annotations

from enum import StrEnum


class DriveProfileName(StrEnum):
    ECO = "eco"
    NORMAL = "normal"
    SPORT = "sport"
    CUSTOM = "custom"


class DriveMode(StrEnum):
    AWD = "awd"
    FWD = "fwd"
    RWD = "rwd"
    CUSTOM = "custom"


class Direction(StrEnum):
    FORWARD = "forward"
    REVERSE = "reverse"


class Axle(StrEnum):
    FRONT = "front"
    REAR = "rear"


class OperatingMode(StrEnum):
    SIMULATION = "simulation"
    HARDWARE = "hardware"


class MeasurementStatus(StrEnum):
    VALID = "valid"
    STALE = "stale"
    UNAVAILABLE = "unavailable"
    SIMULATED = "simulated"


class VehicleState(StrEnum):
    INITIALIZING = "initializing"
    LOCKED = "locked"
    ARMED = "armed"
    FAULT = "fault"
    EMERGENCY_STOP = "emergency_stop"


class BrakeState(StrEnum):
    INACTIVE = "inactive"  # Kein Gas, keine Bremse, Stillstand
    COASTING = "coasting"  # Gas losgelassen: Antrieb aus, keine Bremsanforderung
    REQUESTED = "requested"  # Verzögerung angefordert, Wirkung noch nicht gemessen
    CONFIRMED = "confirmed"  # Verzögerung bzw. Stillstand gemessen
    UNSUPPORTED = "unsupported"  # Bremse gedrückt, aber keine verifizierte Bremsfunktion


class Severity(StrEnum):
    INFO = "info"
    WARNING = "warning"
    CRITICAL = "critical"


class Role(StrEnum):
    DRIVER = "driver"
    ADMIN = "admin"


class ControllerLinkState(StrEnum):
    DISCONNECTED = "disconnected"
    CONNECTING = "connecting"
    CONNECTED = "connected"
    ERROR = "error"
    DISABLED = "disabled"
