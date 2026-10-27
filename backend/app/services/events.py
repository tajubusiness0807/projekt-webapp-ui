"""Ereignisprotokoll (Diagnose).

Ereignisse landen in einem Ringpuffer (für die Live-Anzeige), in SQLite (dauerhaft) und werden an
verbundene Clients verteilt. Gleichartige Ereignisse werden zusammengefasst, damit z. B. eine Flut
ungültiger Nachrichten weder Speicher noch SD-Karte belastet.
"""

from __future__ import annotations

import itertools
import logging
from collections import deque
from dataclasses import dataclass, field
from typing import Any, Callable

from ..models.common import Severity
from ..storage.database import Database
from ..utils.clock import Clock

log = logging.getLogger("awc.events")

EventListener = Callable[["Event"], None]


@dataclass
class Event:
    id: int
    ts: int
    level: Severity
    code: str
    category: str
    message: str
    details: dict[str, Any] | None = field(default=None)

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "ts": self.ts,
            "level": self.level.value,
            "code": self.code,
            "category": self.category,
            "message": self.message,
            "details": self.details,
        }


class EventLog:
    def __init__(self, clock: Clock, db: Database | None = None, capacity: int = 300) -> None:
        self._clock = clock
        self._db = db
        self._buffer: deque[Event] = deque(maxlen=capacity)
        self._ids = itertools.count(1)
        self._listeners: list[EventListener] = []
        self._throttle: dict[str, tuple[float, int]] = {}

    def add_listener(self, listener: EventListener) -> None:
        self._listeners.append(listener)

    def remove_listener(self, listener: EventListener) -> None:
        if listener in self._listeners:
            self._listeners.remove(listener)

    def record(
        self,
        level: Severity,
        code: str,
        category: str,
        message: str,
        details: dict[str, Any] | None = None,
        *,
        throttle_key: str | None = None,
        throttle_s: float = 5.0,
    ) -> Event | None:
        """Protokolliert ein Ereignis.

        Mit ``throttle_key`` wird höchstens ein Ereignis pro ``throttle_s`` gespeichert; unterdrückte
        Wiederholungen werden gezählt und beim nächsten Eintrag als ``suppressed`` mitgegeben.
        """
        now = self._clock.monotonic()
        if throttle_key is not None:
            last, suppressed = self._throttle.get(throttle_key, (-1e9, 0))
            if now - last < throttle_s:
                self._throttle[throttle_key] = (last, suppressed + 1)
                return None
            self._throttle[throttle_key] = (now, 0)
            if suppressed:
                details = dict(details or {})
                details["suppressed"] = suppressed
        event = Event(next(self._ids), self._clock.wall_ms(), level, code, category, message, details)
        self._buffer.append(event)
        log_level = {Severity.INFO: logging.INFO, Severity.WARNING: logging.WARNING, Severity.CRITICAL: logging.ERROR}[level]
        log.log(log_level, "[%s] %s: %s %s", code, category, message, details or "")
        if self._db is not None:
            self._db.enqueue_event(event.ts, level.value, code, category, message, details)
        for listener in list(self._listeners):
            try:
                listener(event)
            except Exception:  # pragma: no cover - Listener dürfen das Protokoll nicht stören
                log.exception("Ereignis-Listener fehlgeschlagen")
        return event

    def info(self, code: str, category: str, message: str, details: dict[str, Any] | None = None, **kw: Any) -> Event | None:
        return self.record(Severity.INFO, code, category, message, details, **kw)

    def warning(self, code: str, category: str, message: str, details: dict[str, Any] | None = None, **kw: Any) -> Event | None:
        return self.record(Severity.WARNING, code, category, message, details, **kw)

    def critical(self, code: str, category: str, message: str, details: dict[str, Any] | None = None, **kw: Any) -> Event | None:
        return self.record(Severity.CRITICAL, code, category, message, details, **kw)

    def recent(self, limit: int = 100) -> list[dict[str, Any]]:
        items = list(self._buffer)[-limit:]
        return [e.to_dict() for e in reversed(items)]
