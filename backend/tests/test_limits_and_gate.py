"""Sicherheitsgrenzen, Antriebsmodus-Verfügbarkeit und Befehlsprüfung (Sequenz, Alter, Rate)."""

from __future__ import annotations

import pytest

from app.models.common import DriveMode, OperatingMode
from app.models.settings import DriveProfileSettings, SafetySettings
from app.safety.command_gate import CommandGate, CommandRejected
from app.safety.limits import apply_deadzone, drive_mode_availability, effective_profile
from app.utils.clock import FakeClock

from .conftest import hardware_settings


def test_sport_cannot_exceed_safety_limits() -> None:
    sport = DriveProfileSettings(
        max_throttle_percent=100, accel_ramp_percent_per_s=400, brake_strength_percent=100,
        steering_sensitivity_percent=80, deadzone_percent=3, max_speed_kmh=60,
    )
    eff = effective_profile(sport, SafetySettings(absolute_max_speed_kmh=15, absolute_max_throttle_percent=70))
    assert eff.max_speed_kmh == 15
    assert eff.max_throttle == pytest.approx(0.7)
    assert eff.accel_ramp_per_s == pytest.approx(1.5)
    assert set(eff.limited) == {"max_speed_kmh", "max_throttle_percent", "accel_ramp_percent_per_s"}


def test_commissioning_caps_power_and_speed() -> None:
    p = DriveProfileSettings(
        max_throttle_percent=100, accel_ramp_percent_per_s=100, brake_strength_percent=100,
        steering_sensitivity_percent=80, deadzone_percent=3, max_speed_kmh=18,
    )
    eff = effective_profile(p, SafetySettings(), commissioning=True)
    assert eff.max_throttle == pytest.approx(0.15)
    assert eff.max_speed_kmh == 3.0


def test_drive_modes_unavailable_without_independent_torque_control() -> None:
    hw = hardware_settings(firmware_control_mode="voltage").hardware
    availability = drive_mode_availability(OperatingMode.HARDWARE, hw)
    assert availability[DriveMode.AWD].available
    for mode in (DriveMode.FWD, DriveMode.RWD, DriveMode.CUSTOM):
        assert not availability[mode].available
        assert "TRQ_MODE" in (availability[mode].reason or "")
    hw = hardware_settings(independent_axle_control=False).hardware
    assert not drive_mode_availability(OperatingMode.HARDWARE, hw)[DriveMode.FWD].available
    assert all(a.available for a in drive_mode_availability(OperatingMode.SIMULATION, hw).values())


def test_deadzone_is_continuous() -> None:
    assert apply_deadzone(0.05, 0.1) == 0.0
    assert apply_deadzone(0.1, 0.1) == 0.0
    assert apply_deadzone(1.0, 0.1) == pytest.approx(1.0)
    assert apply_deadzone(-0.55, 0.1) == pytest.approx(-0.5)


def test_gate_rejects_out_of_order_and_duplicate_sequence() -> None:
    clock = FakeClock()
    gate = CommandGate(clock)
    gate.check(5, clock.wall_ms(), max_age_ms=400, max_rate_hz=40)
    clock.advance(0.05)
    with pytest.raises(CommandRejected) as exc:
        gate.check(5, clock.wall_ms(), max_age_ms=400, max_rate_hz=40)
    assert exc.value.code == "SEQ_ORDER"
    with pytest.raises(CommandRejected):
        gate.check(4, clock.wall_ms(), max_age_ms=400, max_rate_hz=40)


def test_gate_rejects_delayed_messages_despite_clock_offset() -> None:
    clock = FakeClock()
    gate = CommandGate(clock)
    offset = -123_456  # Client-Uhr geht deutlich anders
    for seq in range(1, 6):
        gate.check(seq, clock.wall_ms() + offset, max_age_ms=400, max_rate_hz=40)
        clock.advance(0.05)
    # Nachricht, die 800 ms unterwegs war (z. B. von TCP nach Funkloch nachgeliefert)
    sent_at = clock.wall_ms() + offset - 800
    with pytest.raises(CommandRejected) as exc:
        gate.check(6, sent_at, max_age_ms=400, max_rate_hz=40)
    assert exc.value.code == "STALE"
    # Aktuelle Nachricht danach wird wieder angenommen
    gate.check(7, clock.wall_ms() + offset, max_age_ms=400, max_rate_hz=40)


def test_gate_rate_limit() -> None:
    clock = FakeClock()
    gate = CommandGate(clock)
    for seq in range(1, 11):
        gate.check(seq, clock.wall_ms(), max_age_ms=400, max_rate_hz=10)
    with pytest.raises(CommandRejected) as exc:
        gate.check(11, clock.wall_ms(), max_age_ms=400, max_rate_hz=10)
    assert exc.value.code == "RATE_LIMIT"
    clock.advance(0.5)
    gate.check(12, clock.wall_ms(), max_age_ms=400, max_rate_hz=10)
