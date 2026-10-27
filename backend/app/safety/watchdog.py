"""Unabhängige Überwachung der Regelschleife in einem eigenen Thread.

Die zyklischen Überwachungen (Befehle, Verbindung, Controller, Messdaten) laufen in der Regelschleife
selbst (``VehicleService._evaluate_*``). Hängt jedoch die asyncio-Schleife (z. B. blockierender Aufruf,
Speicherdruck), würden diese Prüfungen nicht mehr laufen. Der ``LoopSupervisor`` läuft deshalb in
einem separaten Thread, prüft das Lebenszeichen der Regelschleife und sendet bei Ausbleiben direkt
Nullbefehle an alle Controller. Sobald die Schleife wieder läuft, meldet sie den Fehler E008.

Weitere, vom Backend unabhängige Ebenen: Firmware-Timeout des Controllers und systemd-Watchdog.
"""

from __future__ import annotations

import logging
import threading
import time
from typing import Callable

log = logging.getLogger(__name__)


class LoopSupervisor:
    def __init__(
        self,
        heartbeat: Callable[[], float],
        on_stall: Callable[[float], None],
        stall_after_s: float,
        interval_s: float = 0.1,
    ) -> None:
        self._heartbeat = heartbeat
        self._on_stall = on_stall
        self.stall_after_s = stall_after_s
        self._interval = interval_s
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self.tripped = threading.Event()
        self.trip_count = 0

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._run, name="awc-loop-supervisor", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=1.0)
            self._thread = None

    def check_once(self) -> bool:
        """Eine Prüfung (für Tests). Gibt ``True`` zurück, wenn ein Stillstand erkannt wurde."""
        age = time.monotonic() - self._heartbeat()
        if age > self.stall_after_s:
            if not self.tripped.is_set():
                self.tripped.set()
                self.trip_count += 1
                try:
                    self._on_stall(age)
                except Exception:  # pragma: no cover - Supervisor darf nicht abbrechen
                    log.exception("Not-Aus durch Loop-Supervisor fehlgeschlagen")
            return True
        return False

    def _run(self) -> None:
        while not self._stop.wait(self._interval):
            self.check_once()
