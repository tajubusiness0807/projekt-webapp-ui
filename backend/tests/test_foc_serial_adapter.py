"""Serieller FOC-Adapter mit simulierter Schnittstelle (keine echte Hardware)."""

from __future__ import annotations

import pytest

from app.controllers.base import BrakeSupport, WheelCommand
from app.controllers.foc_protocol import FocFeedback
from app.controllers.foc_serial import HoverboardFocSerialController, brake_is_usable
from app.models.common import ControllerLinkState
from app.utils.clock import FakeClock

from .conftest import FakeSerialFactory, hardware_settings


def _adapter(**hw_overrides: object) -> tuple[HoverboardFocSerialController, FakeSerialFactory]:
    settings = hardware_settings(**hw_overrides)
    factory = FakeSerialFactory()
    cfg = settings.hardware.controllers[0]
    return HoverboardFocSerialController(cfg, settings.hardware, FakeClock(), factory), factory


async def test_connect_sends_zero_and_waits_for_feedback() -> None:
    adapter, factory = _adapter()
    await adapter.connect()
    port = factory.ports["/dev/fake-front"]
    assert port.last_command() == (0, 0)
    assert adapter.get_status().link == ControllerLinkState.CONNECTING
    port.feed(FocFeedback(0, 0, 0, 0, 3800, 300, 0))
    telemetry = adapter.read_telemetry()
    assert telemetry is not None
    assert adapter.get_status().link == ControllerLinkState.CONNECTED
    assert telemetry.battery_voltage == pytest.approx(38.0)
    assert telemetry.controller_temp_c is None  # Temperatur nicht kalibriert → nicht verfügbar
    assert telemetry.simulated is False


async def test_drive_request_uses_mixer_inversion_and_limit() -> None:
    adapter, factory = _adapter()
    await adapter.connect()
    adapter.set_drive_request(WheelCommand(1.0, 1.0))
    steer, speed = factory.ports["/dev/fake-front"].last_command()
    assert (steer, speed) == (0, 300)  # max_command Standard 300


async def test_inverted_and_swapped_sides() -> None:
    settings = hardware_settings()
    cfg = settings.hardware.controllers[0].model_copy(update={"invert_right_command": True, "swap_sides": True})
    factory = FakeSerialFactory()
    adapter = HoverboardFocSerialController(cfg, settings.hardware, FakeClock(), factory)
    await adapter.connect()
    adapter.set_drive_request(WheelCommand(1.0, 0.0))
    steer, speed = factory.ports["/dev/fake-front"].last_command()
    # links=1, rechts=0 → rechts invertiert (0) → getauscht: L=0, R=1 → speed=150, steer=-150
    assert (steer, speed) == (-150, 150)


async def test_feedback_inversion_applies_to_rpm() -> None:
    settings = hardware_settings()
    cfg = settings.hardware.controllers[0].model_copy(update={"invert_right_feedback": True})
    factory = FakeSerialFactory()
    adapter = HoverboardFocSerialController(cfg, settings.hardware, FakeClock(), factory)
    await adapter.connect()
    factory.ports["/dev/fake-front"].feed(FocFeedback(0, 0, -120, 118, 3800, 300, 0))
    t = adapter.read_telemetry()
    assert t is not None and t.wheel_rpm_left == 118 and t.wheel_rpm_right == 120


async def test_brake_without_verification_only_switches_drive_off() -> None:
    adapter, factory = _adapter(brake_method="counter_torque", brake_verified=False)
    await adapter.connect()
    assert adapter.capabilities.brake is False
    assert adapter.request_brake(1.0) == BrakeSupport.DRIVE_OFF_ONLY
    assert factory.ports["/dev/fake-front"].last_command() == (0, 0)


async def test_counter_torque_brake_opposes_rotation_and_stops_at_standstill() -> None:
    adapter, factory = _adapter(brake_method="counter_torque", brake_verified=True, firmware_control_mode="torque")
    await adapter.connect()
    port = factory.ports["/dev/fake-front"]
    port.feed(FocFeedback(0, 0, 200, 200, 3800, 300, 0))
    adapter.read_telemetry()
    assert adapter.request_brake(1.0) == BrakeSupport.APPLIED
    steer, speed = port.last_command()
    assert speed < 0 and steer == 0
    port.feed(FocFeedback(0, 0, 0, 0, 3800, 300, 0))
    adapter.read_telemetry()
    adapter.request_brake(1.0)
    assert port.last_command() == (0, 0)  # kein Rückwärtsanfahren im Stillstand


def test_brake_method_requires_matching_control_mode() -> None:
    hw = hardware_settings(brake_method="counter_torque", brake_verified=True, firmware_control_mode="voltage").hardware
    assert brake_is_usable(hw) is False
    hw = hardware_settings(brake_method="voltage_mode_zero", brake_verified=True, firmware_control_mode="voltage").hardware
    assert brake_is_usable(hw) is True


async def test_emergency_stop_sends_zero_frame() -> None:
    adapter, factory = _adapter()
    await adapter.connect()
    adapter.set_drive_request(WheelCommand(0.5, 0.5))
    adapter.emergency_stop()
    assert factory.ports["/dev/fake-front"].last_command() == (0, 0)
    assert adapter.get_status().emergency_stopped


async def test_unavailable_port_sets_error_state() -> None:
    settings = hardware_settings()

    def failing(cfg: object) -> object:
        raise OSError("No such file or directory")

    adapter = HoverboardFocSerialController(settings.hardware.controllers[0], settings.hardware, FakeClock(), failing)
    await adapter.connect()
    assert adapter.get_status().link == ControllerLinkState.ERROR
    adapter.set_drive_request(WheelCommand(1, 1))  # darf nicht abstürzen
    assert adapter.read_telemetry() is None
