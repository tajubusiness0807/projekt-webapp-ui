"""Prüfung eingehender Steuernachrichten je Sitzung: Reihenfolge, Alter und Rate.

Alter von Nachrichten
---------------------
Uhren von Handy und Raspberry Pi sind nicht synchron. Für jede Nachricht wird
``probe = Serverzeit − Clientzeitstempel`` gebildet. Das Minimum der letzten 10 s entspricht
„Uhrenversatz + schnellste Übertragung". Liegt eine Nachricht um mehr als ``max_command_age_ms``
über diesem Minimum, wurde sie unterwegs verzögert (z. B. von TCP nach einer WLAN-Störung gepuffert)
und wird verworfen. So können nach einem Funkloch keine alten Gasbefehle „nachgeliefert" werden.
"""

from __future__ import annotations

from collections import deque

from ..utils.clock import Clock

PROBE_WINDOW_S = 10.0


class CommandRejected(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class CommandGate:
    def __init__(self, clock: Clock) -> None:
        self._clock = clock
        self.last_seq = 0
        self._probes: deque[tuple[float, int]] = deque()
        self._tokens: float | None = None
        self._last_refill = clock.monotonic()
        self.rejected = 0

    def check(self, seq: int, ts_ms: int, *, max_age_ms: int, max_rate_hz: int) -> int:
        """Prüft eine Nachricht. Gibt die geschätzte Verzögerung in ms zurück oder wirft ``CommandRejected``."""
        self._check_rate(max_rate_hz)
        if seq <= self.last_seq:
            self.rejected += 1
            raise CommandRejected(
                "SEQ_ORDER", f"Sequenznummer {seq} nicht größer als zuletzt angenommene {self.last_seq}"
            )
        delay = self._check_age(ts_ms, max_age_ms)
        self.last_seq = seq
        return delay

    def _check_rate(self, max_rate_hz: int) -> None:
        now = self._clock.monotonic()
        capacity = float(max_rate_hz)
        if self._tokens is None:
            self._tokens = capacity
        self._tokens = min(capacity, self._tokens + (now - self._last_refill) * max_rate_hz)
        self._last_refill = now
        if self._tokens < 1.0:
            self.rejected += 1
            raise CommandRejected("RATE_LIMIT", f"Mehr als {max_rate_hz} Nachrichten pro Sekunde")
        self._tokens -= 1.0

    def _check_age(self, ts_ms: int, max_age_ms: int) -> int:
        now = self._clock.monotonic()
        probe = self._clock.wall_ms() - int(ts_ms)
        while self._probes and now - self._probes[0][0] > PROBE_WINDOW_S:
            self._probes.popleft()
        baseline = min((p for _, p in self._probes), default=probe)
        baseline = min(baseline, probe)
        self._probes.append((now, probe))
        delay = probe - baseline
        if delay > max_age_ms:
            self.rejected += 1
            raise CommandRejected("STALE", f"Nachricht um {delay} ms verzögert (Grenze {max_age_ms} ms)")
        return delay
