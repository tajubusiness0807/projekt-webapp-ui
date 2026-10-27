"""Sicherheitszustand des Fahrzeugs.

Zustände::

    INITIALIZING ──▶ LOCKED ◀──────── quittieren ──── FAULT
                       │  ▲                              ▲
              Freigabe │  │ Sperre / Sitzung weg         │ kritischer Fehler
                       ▼  │                              │
                      ARMED ─────────────────────────────┘
    beliebig ── Not-Aus ──▶ EMERGENCY_STOP ── Rücksetzen ──▶ LOCKED (bzw. FAULT)

* Nur in ``ARMED`` werden Fahranforderungen an die Controller weitergegeben.
* Die Freigabe erfolgt nie automatisch – nicht beim Start, nicht nach Wiederverbindung,
  nicht nach dem Quittieren.
* Kritische Fehler bleiben nach Wegfall der Ursache gespeichert, bis sie quittiert werden.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

from ..models.common import Severity, VehicleState
from ..models.faults import FAULT_CATALOG, FaultCode
from ..services.events import EventLog
from ..utils.clock import Clock


@dataclass
class ActiveFault:
    code: FaultCode
    source: str
    detail: str
    since_ms: int
    active: bool = True
    count: int = 1

    @property
    def key(self) -> str:
        return f"{self.code.value}:{self.source}"

    @property
    def blocking(self) -> bool:
        return FAULT_CATALOG[self.code].blocking

    def to_dict(self) -> dict[str, object]:
        definition = FAULT_CATALOG[self.code]
        return {
            "code": self.code.value,
            "source": self.source,
            "detail": self.detail,
            "since": self.since_ms,
            "active": self.active,
            "blocking": definition.blocking,
            "severity": definition.severity.value,
            "title": definition.title,
            "count": self.count,
        }


StateListener = Callable[[VehicleState, VehicleState, str], None]


class SafetyManager:
    def __init__(self, clock: Clock, events: EventLog) -> None:
        self._clock = clock
        self._events = events
        self.state = VehicleState.INITIALIZING
        self.neutral_required = True
        self._estop = False
        self._faults: dict[str, ActiveFault] = {}
        self._listeners: list[StateListener] = []

    # ------------------------------------------------------------------ Abfragen
    @property
    def armed(self) -> bool:
        return self.state == VehicleState.ARMED

    @property
    def emergency_stop_active(self) -> bool:
        return self._estop

    def faults(self) -> list[ActiveFault]:
        order = {Severity.CRITICAL: 0, Severity.WARNING: 1, Severity.INFO: 2}
        return sorted(
            self._faults.values(), key=lambda f: (order[FAULT_CATALOG[f.code].severity], f.since_ms)
        )

    def has_fault(self, code: FaultCode, source: str | None = None) -> bool:
        if source is not None:
            return f"{code.value}:{source}" in self._faults
        return any(f.code == code for f in self._faults.values())

    def blocking_faults(self) -> list[ActiveFault]:
        return [f for f in self._faults.values() if f.blocking]

    def add_listener(self, listener: StateListener) -> None:
        self._listeners.append(listener)

    # ------------------------------------------------------------------ Fehler
    def set_condition(self, code: FaultCode, source: str, active: bool, detail: str = "") -> None:
        """Meldet den aktuellen Zustand einer überwachten Bedingung (zyklisch aufrufbar)."""
        key = f"{code.value}:{source}"
        fault = self._faults.get(key)
        definition = FAULT_CATALOG[code]
        if active:
            if fault is None:
                self._faults[key] = ActiveFault(code, source, detail, self._clock.wall_ms())
                self._log_fault(code, source, detail)
            elif not fault.active:
                fault.active = True
                fault.count += 1
                fault.detail = detail or fault.detail
                self._log_fault(code, source, detail)
            elif detail:
                fault.detail = detail
        elif fault is not None and fault.active:
            fault.active = False
            if not definition.blocking:
                del self._faults[key]
                self._events.info(code.value, "sicherheit", f"Behoben: {definition.title}", {"quelle": source})
        self._recompute(f"Fehler {code.value}")

    def raise_fault(self, code: FaultCode, source: str, detail: str = "") -> None:
        """Einmaliges Ereignis (z. B. Verbindungsverlust): sofort gespeichert, Quittierung nötig."""
        key = f"{code.value}:{source}"
        fault = self._faults.get(key)
        if fault is None:
            self._faults[key] = ActiveFault(code, source, detail, self._clock.wall_ms(), active=False)
        else:
            fault.count += 1
            fault.detail = detail or fault.detail
        self._log_fault(code, source, detail)
        self._recompute(f"Fehler {code.value}")

    def clear_condition_silently(self, code: FaultCode, source: str) -> None:
        self._faults.pop(f"{code.value}:{source}", None)
        self._recompute("Bereinigung")

    def acknowledge(self) -> tuple[int, list[ActiveFault]]:
        """Entfernt alle gespeicherten Fehler, deren Ursache nicht mehr besteht."""
        removable = [k for k, f in self._faults.items() if not f.active and f.code != FaultCode.EMERGENCY_STOP]
        for key in removable:
            del self._faults[key]
        remaining = [f for f in self._faults.values() if f.blocking]
        if removable:
            self._events.info("ACK", "sicherheit", f"{len(removable)} Fehler quittiert")
        self._recompute("Quittierung")
        return len(removable), remaining

    # ------------------------------------------------------------------ Freigabe
    def finish_initialization(self) -> None:
        if self.state == VehicleState.INITIALIZING:
            self._set_state(VehicleState.LOCKED, "Initialisierung abgeschlossen")
            self._recompute("Initialisierung")

    def arm(self, failed_preconditions: list[str]) -> tuple[bool, str | None]:
        if self.state == VehicleState.ARMED:
            return True, None
        if self._estop:
            return False, "Not-Aus ist aktiv"
        if self.state == VehicleState.FAULT or self.blocking_faults():
            return False, "Kritische Fehler müssen zuerst behoben und quittiert werden"
        if self.state != VehicleState.LOCKED:
            return False, "Freigabe in diesem Zustand nicht möglich"
        if failed_preconditions:
            return False, "; ".join(failed_preconditions)
        self.neutral_required = False
        self._set_state(VehicleState.ARMED, "Motorfreigabe durch Fahrer")
        return True, None

    def disarm(self, reason: str) -> None:
        if self.state == VehicleState.ARMED:
            self._set_state(VehicleState.LOCKED, reason)
        self.neutral_required = True

    # ------------------------------------------------------------------ Not-Aus
    def emergency_stop(self, source: str, reason: str = "") -> None:
        first = not self._estop
        self._estop = True
        self.neutral_required = True
        key = f"{FaultCode.EMERGENCY_STOP.value}:system"
        if key not in self._faults:
            self._faults[key] = ActiveFault(
                FaultCode.EMERGENCY_STOP, "system", reason or f"Ausgelöst durch {source}", self._clock.wall_ms()
            )
        if first:
            self._events.critical(
                FaultCode.EMERGENCY_STOP.value, "sicherheit", "Not-Aus ausgelöst", {"quelle": source, "grund": reason}
            )
        self._recompute("Not-Aus")

    def reset_emergency_stop(self) -> bool:
        if not self._estop:
            return False
        self._estop = False
        self._faults.pop(f"{FaultCode.EMERGENCY_STOP.value}:system", None)
        self._events.info("ESTOP_RESET", "sicherheit", "Not-Aus zurückgesetzt – Motoren bleiben gesperrt")
        self._recompute("Not-Aus zurückgesetzt")
        return True

    # ------------------------------------------------------------------ intern
    def _recompute(self, reason: str) -> None:
        if self.state == VehicleState.INITIALIZING:
            return
        if self._estop:
            target = VehicleState.EMERGENCY_STOP
        elif self.blocking_faults():
            target = VehicleState.FAULT
        elif self.state in (VehicleState.FAULT, VehicleState.EMERGENCY_STOP):
            target = VehicleState.LOCKED
        else:
            target = self.state
        if target != self.state:
            self._set_state(target, reason)

    def _set_state(self, new: VehicleState, reason: str) -> None:
        old = self.state
        if old == new:
            return
        self.state = new
        if new != VehicleState.ARMED:
            self.neutral_required = True
        level = Severity.WARNING if new in (VehicleState.FAULT, VehicleState.EMERGENCY_STOP) else Severity.INFO
        self._events.record(level, "STATE", "sicherheit", f"Zustand {old.value} → {new.value}", {"grund": reason})
        for listener in list(self._listeners):
            listener(old, new, reason)

    def _log_fault(self, code: FaultCode, source: str, detail: str) -> None:
        definition = FAULT_CATALOG[code]
        details = {"quelle": source}
        if detail:
            details["detail"] = detail
        self._events.record(
            definition.severity,
            code.value,
            "fehler",
            definition.title,
            details,
            throttle_key=f"fault:{code.value}:{source}",
            throttle_s=2.0,
        )
