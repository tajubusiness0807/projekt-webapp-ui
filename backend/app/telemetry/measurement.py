"""Messwerte mit Zustand.

Jeder angezeigte Wert trägt einen Zustand: gültig, veraltet, nicht verfügbar oder simuliert.
Veraltete oder fehlende Werte dürfen im Frontend nicht wie aktuelle Messungen aussehen.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from ..models.common import MeasurementStatus


@dataclass(frozen=True)
class Measurement:
    value: float | None
    status: MeasurementStatus
    age_ms: int | None = None
    unit: str = ""

    @property
    def usable(self) -> bool:
        """True, wenn der Wert aktuell ist (gemessen oder simuliert)."""
        return self.value is not None and self.status in (
            MeasurementStatus.VALID,
            MeasurementStatus.SIMULATED,
        )

    def to_dict(self, digits: int = 2) -> dict[str, object]:
        value = None if self.value is None else round(self.value, digits)
        return {"value": value, "status": self.status.value, "age_ms": self.age_ms, "unit": self.unit}

    @staticmethod
    def unavailable(unit: str = "") -> "Measurement":
        return Measurement(None, MeasurementStatus.UNAVAILABLE, None, unit)


class TrackedValue:
    """Hält den letzten Wert einer Quelle samt Zeitstempel und erzeugt daraus einen ``Measurement``."""

    __slots__ = ("unit", "_value", "_timestamp", "_simulated")

    def __init__(self, unit: str = "") -> None:
        self.unit = unit
        self._value: float | None = None
        self._timestamp: float | None = None
        self._simulated = False

    def update(self, value: float | None, timestamp: float, *, simulated: bool) -> None:
        if value is None or not math.isfinite(value):
            self._value = None
            self._timestamp = None
            return
        self._value = float(value)
        self._timestamp = timestamp
        self._simulated = simulated

    def clear(self) -> None:
        self._value = None
        self._timestamp = None

    def measurement(self, now: float, stale_after_s: float) -> Measurement:
        if self._value is None or self._timestamp is None:
            return Measurement.unavailable(self.unit)
        age = max(0.0, now - self._timestamp)
        age_ms = int(age * 1000)
        if age > stale_after_s:
            return Measurement(self._value, MeasurementStatus.STALE, age_ms, self.unit)
        status = MeasurementStatus.SIMULATED if self._simulated else MeasurementStatus.VALID
        return Measurement(self._value, status, age_ms, self.unit)
