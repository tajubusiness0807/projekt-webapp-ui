"""Zustandsautomat: Freigabe, Fehlerverriegelung, Quittierung, Not-Aus."""

from __future__ import annotations

from app.models.common import VehicleState
from app.models.faults import FaultCode
from app.safety.state_machine import SafetyManager
from app.safety.watchdog import LoopSupervisor
from app.services.events import EventLog
from app.utils.clock import FakeClock


def manager() -> SafetyManager:
    clock = FakeClock()
    m = SafetyManager(clock, EventLog(clock))
    m.finish_initialization()
    return m


def test_starts_locked_and_never_arms_automatically() -> None:
    m = manager()
    assert m.state == VehicleState.LOCKED
    assert not m.armed
    assert m.neutral_required


def test_arm_requires_preconditions() -> None:
    m = manager()
    ok, reason = m.arm(["Gas muss losgelassen sein"])
    assert not ok and "Gas" in (reason or "")
    ok, _ = m.arm([])
    assert ok and m.state == VehicleState.ARMED


def test_blocking_fault_disarms_and_latches_until_acknowledged() -> None:
    m = manager()
    m.arm([])
    m.set_condition(FaultCode.SINGLE_CONTROLLER, "antrieb", True, "vorne")
    assert m.state == VehicleState.FAULT and not m.armed
    # Ursache noch aktiv → Quittieren entfernt nichts
    removed, remaining = m.acknowledge()
    assert removed == 0 and remaining
    m.set_condition(FaultCode.SINGLE_CONTROLLER, "antrieb", False)
    assert m.state == VehicleState.FAULT  # weiterhin gespeichert
    removed, remaining = m.acknowledge()
    assert removed == 1 and not remaining
    assert m.state == VehicleState.LOCKED  # nicht automatisch freigegeben


def test_warning_does_not_block_and_clears_itself() -> None:
    m = manager()
    m.arm([])
    m.set_condition(FaultCode.BATTERY_WARNING, "akku", True)
    assert m.armed
    m.set_condition(FaultCode.BATTERY_WARNING, "akku", False)
    assert not m.has_fault(FaultCode.BATTERY_WARNING)


def test_emergency_stop_requires_reset_and_rearm() -> None:
    m = manager()
    m.arm([])
    m.emergency_stop("Test")
    assert m.state == VehicleState.EMERGENCY_STOP
    ok, reason = m.arm([])
    assert not ok and "Not-Aus" in (reason or "")
    m.acknowledge()  # Quittieren hebt Not-Aus nicht auf
    assert m.state == VehicleState.EMERGENCY_STOP
    assert m.reset_emergency_stop()
    assert m.state == VehicleState.LOCKED and not m.armed


def test_event_fault_latches_immediately() -> None:
    m = manager()
    m.arm([])
    m.raise_fault(FaultCode.CONNECTION_LOST, "steuergeraet")
    assert m.state == VehicleState.FAULT
    removed, _ = m.acknowledge()
    assert removed == 1 and m.state == VehicleState.LOCKED


def test_loop_supervisor_trips_once_on_stale_heartbeat() -> None:
    calls: list[float] = []
    supervisor = LoopSupervisor(lambda: 0.0, calls.append, stall_after_s=0.2)
    assert supervisor.check_once()
    assert supervisor.check_once()
    assert len(calls) == 1 and supervisor.tripped.is_set()
