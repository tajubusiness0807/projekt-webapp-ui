"""Zeitquellen.

Alle zeitabhängigen Komponenten (Watchdog, Rampen, Simulation) erhalten eine ``Clock``.
So lassen sich Zeitüberschreitungen in Tests deterministisch prüfen, ohne zu warten.
"""

from __future__ import annotations

import time
from typing import Protocol


class Clock(Protocol):
    def monotonic(self) -> float:
        """Monotone Zeit in Sekunden (für Abstände und Zeitüberschreitungen)."""

    def wall_ms(self) -> int:
        """Wanduhrzeit in Millisekunden seit Epoch (für Protokoll und Anzeige)."""


class SystemClock:
    def monotonic(self) -> float:
        return time.monotonic()

    def wall_ms(self) -> int:
        return int(time.time() * 1000)


class FakeClock:
    """Manuell fortschaltbare Uhr für Tests und reproduzierbare Simulationen."""

    def __init__(self, start: float = 1000.0, wall_start_ms: int = 1_700_000_000_000) -> None:
        self._mono = start
        self._wall_offset_ms = wall_start_ms - int(start * 1000)

    def monotonic(self) -> float:
        return self._mono

    def wall_ms(self) -> int:
        return int(self._mono * 1000) + self._wall_offset_ms

    def advance(self, seconds: float) -> None:
        if seconds < 0:
            raise ValueError("Die Zeit kann nicht zurückgestellt werden")
        self._mono += seconds
