"""Fahrlogik: Totzone, Grenzen, Rampen, Bremse, Geschwindigkeitsbegrenzung, Lenkung, Verteilung."""

from __future__ import annotations

import pytest

from app.models.common import Axle, Direction, DriveMode, MeasurementStatus
from app.models.settings import DriveProfileSettings, PowerSplitSettings, SafetySettings
from app.safety.limits import axle_scales, axle_weights, effective_profile
from app.services.drive_logic import DriveComputer, DriveContext, DriverInput
from app.telemetry.measurement import Measurement


def profile(**kw: float):
    base = dict(
        max_throttle_percent=100, accel_ramp_percent_per_s=400, brake_strength_percent=80,
        steering_sensitivity_percent=100, deadzone_percent=0, max_speed_kmh=20,
    )
    base.update(kw)
    return effective_profile(DriveProfileSettings(**base), SafetySettings(absolute_max_accel_ramp_percent_per_s=400))


def ctx(prof=None, *, speed: float | None = 0.0, armed: bool = True, weights=(50.0, 50.0), direction=Direction.FORWARD, **kw):
    m = Measurement(speed, MeasurementStatus.SIMULATED, 10, "km/h") if speed is not None else Measurement.unavailable("km/h")
    return DriveContext(
        armed=armed, direction=direction, profile=prof or profile(), weights=weights, speed=m,
        reverse_max_speed_kmh=4, reverse_max_throttle=0.35, **kw,
    )


def run(dc: DriveComputer, inp: DriverInput, c: DriveContext, seconds: float, dt: float = 0.04):
    out = None
    for _ in range(int(round(seconds / dt))):
        out = dc.compute(inp, c, dt)
    return out


def test_not_armed_outputs_zero() -> None:
    out = DriveComputer().compute(DriverInput(1, 0, 0), ctx(armed=False), 0.04)
    assert out.drive_level == 0 and out.brake_level == 0


def test_ramp_limits_rise_and_release_is_immediate() -> None:
    dc = DriveComputer()
    c = ctx(profile(accel_ramp_percent_per_s=50))
    out = dc.compute(DriverInput(1, 0, 0), c, 0.1)
    assert out.wheels[Axle.FRONT].left == pytest.approx(0.05)
    out = run(dc, DriverInput(1, 0, 0), c, 1.0, dt=0.1)
    assert out.wheels[Axle.FRONT].left == pytest.approx(0.55)
    out = dc.compute(DriverInput(0, 0, 0), c, 0.04)  # Loslassen
    assert out.drive_level == 0.0


def test_deadzone_and_max_throttle() -> None:
    dc = DriveComputer()
    c = ctx(profile(deadzone_percent=10, max_throttle_percent=50))
    assert dc.compute(DriverInput(0.08, 0, 0), c, 1.0).drive_level == 0.0
    out = run(dc, DriverInput(1.0, 0, 0), c, 1.0)
    assert out.drive_level == pytest.approx(0.5)
    assert "profil" in out.limited_by


def test_brake_has_priority_and_resets_drive() -> None:
    dc = DriveComputer()
    c = ctx(profile(brake_strength_percent=60))
    run(dc, DriverInput(1, 0, 0), c, 1.0)
    out = dc.compute(DriverInput(1, 1, 0), c, 0.04)
    assert out.drive_level == 0.0
    assert out.brake_level == pytest.approx(0.6)
    assert out.target_throttle == 0.0


def test_speed_limit_reduces_throttle_near_limit() -> None:
    dc = DriveComputer()
    out = run(dc, DriverInput(1, 0, 0), ctx(profile(max_speed_kmh=10), speed=9.5), 1.0)
    assert 0 < out.effective_throttle < 0.5
    assert "geschwindigkeit" in out.limited_by
    out = run(dc, DriverInput(1, 0, 0), ctx(profile(max_speed_kmh=10), speed=10.5), 0.2)
    assert out.effective_throttle == 0.0


def test_no_speed_measurement_blocks_throttle() -> None:
    out = run(DriveComputer(), DriverInput(1, 0, 0), ctx(speed=None), 0.5)
    assert out.drive_level == 0.0
    assert "keine_geschwindigkeit" in out.limited_by


def test_reverse_is_limited_and_negative() -> None:
    out = run(DriveComputer(), DriverInput(1, 0, 0), ctx(direction=Direction.REVERSE), 1.0)
    assert out.wheels[Axle.FRONT].left == pytest.approx(-0.35)
    assert out.speed_limit_kmh == 4


def test_steering_slows_inner_side_without_pivot() -> None:
    dc = DriveComputer()
    out = run(dc, DriverInput(0.5, 0, 1.0), ctx(profile(steering_sensitivity_percent=50)), 1.0)
    front = out.wheels[Axle.FRONT]
    assert front.left == pytest.approx(0.5)  # kurvenaußen
    assert front.right == pytest.approx(0.25)  # kurveninnen
    # Ohne Gas keine Drehung auf der Stelle
    out = dc.compute(DriverInput(0, 0, 1.0), ctx(), 0.04)
    assert out.drive_level == 0.0


def test_battery_and_temperature_factors() -> None:
    out = run(DriveComputer(), DriverInput(1, 0, 0), ctx(battery_factor=0.5, temperature_factor=0.8), 1.0)
    assert out.drive_level == pytest.approx(0.4)
    assert {"akku", "temperatur"} <= set(out.limited_by)


@pytest.mark.parametrize(
    "mode,expected",
    [(DriveMode.FWD, (100.0, 0.0)), (DriveMode.RWD, (0.0, 100.0)), (DriveMode.AWD, (50.0, 50.0)), (DriveMode.CUSTOM, (60.0, 40.0))],
)
def test_axle_weights_per_drive_mode(mode: DriveMode, expected: tuple[float, float]) -> None:
    assert axle_weights(mode, PowerSplitSettings(), True) == expected


def test_axle_weights_forced_equal_without_distribution_capability() -> None:
    assert axle_weights(DriveMode.FWD, PowerSplitSettings(), False) == (50.0, 50.0)


def test_axle_scale_definition() -> None:
    assert axle_scales(60, 40) == pytest.approx((1.0, 2 / 3))
    assert axle_scales(100, 0) == (1.0, 0.0)
    assert axle_scales(50, 50) == (1.0, 1.0)


def test_fwd_gives_rear_no_positive_request() -> None:
    out = run(DriveComputer(), DriverInput(1, 0, 0), ctx(weights=(100.0, 0.0)), 1.0)
    assert out.wheels[Axle.REAR].is_zero
    assert out.wheels[Axle.FRONT].left > 0


def test_split_60_40_in_outputs_and_side_limits() -> None:
    p = effective_profile(
        DriveProfileSettings(
            max_throttle_percent=100, accel_ramp_percent_per_s=400, brake_strength_percent=80,
            steering_sensitivity_percent=100, deadzone_percent=0, max_speed_kmh=20, right_limit_percent=80,
        ),
        SafetySettings(absolute_max_accel_ramp_percent_per_s=400),
    )
    out = run(DriveComputer(), DriverInput(1, 0, 0), ctx(p, weights=(60.0, 40.0)), 1.0)
    assert out.wheels[Axle.FRONT].left == pytest.approx(1.0)
    assert out.wheels[Axle.REAR].left == pytest.approx(2 / 3, rel=1e-3)
    assert out.wheels[Axle.FRONT].right == pytest.approx(0.8)
