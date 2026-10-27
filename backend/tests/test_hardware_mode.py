"""Hardwaremodus mit simulierter serieller Schnittstelle – es wird nie ein echtes Gerät geöffnet."""

from __future__ import annotations

from dataclasses import replace

from app.controllers.foc_protocol import FocFeedback
from app.models.common import Axle, OperatingMode, VehicleState
from app.models.faults import FaultCode

from .conftest import FakeSerialFactory, Harness, hardware_settings


async def test_hardware_requested_without_env_flag_is_blocked(env) -> None:  # type: ignore[no-untyped-def]
    h = Harness(env, settings=hardware_settings())
    await h.start()
    assert h.service.mode == OperatingMode.HARDWARE
    assert h.service.build is not None and h.service.build.coordinator is None
    assert FaultCode.HARDWARE_NOT_INITIALIZED.value in h.fault_codes()
    assert h.service.safety.state == VehicleState.FAULT
    assert "AWC_HARDWARE_ENABLED" in " ".join(i.detail for i in h.service.build.readiness if not i.ok)
    await h.close()


async def test_incomplete_checklist_blocks_hardware(hw_env) -> None:  # type: ignore[no-untyped-def]
    h = Harness(hw_env, settings=hardware_settings(signal_levels_verified=False))
    await h.start()
    assert h.service.build is not None and h.service.build.coordinator is None
    assert "Signalpegel" in (h.service.build.init_error or "")
    await h.close()


async def test_full_checklist_builds_serial_controllers_and_monitors_both(hw_env) -> None:  # type: ignore[no-untyped-def]
    factory = FakeSerialFactory()
    h = Harness(hw_env, settings=hardware_settings(), serial_factory=factory)
    await h.start()
    assert set(factory.ports) == {"/dev/fake-front", "/dev/fake-rear"}
    # Keine Rückmeldung → nach Anlaufzeit E001
    h.tick(0.1, steps=30)
    assert FaultCode.NO_CONTROLLER.value in h.fault_codes()
    # Nur vorne liefert Daten → E002
    for _ in range(10):
        factory.ports["/dev/fake-front"].feed(FocFeedback(0, 0, 0, 0, 3900, 300, 0))
        h.tick(0.05)
    codes = h.fault_codes()
    assert FaultCode.SINGLE_CONTROLLER.value in codes
    # Ohne Freigabe werden nur Nullbefehle gesendet
    for port in factory.ports.values():
        assert all(cmd == port.written[0] for cmd in port.written)
        assert port.last_command() == (0, 0)
    await h.close()


async def test_hardware_measurements_valid_and_temperature_unavailable(hw_env) -> None:  # type: ignore[no-untyped-def]
    factory = FakeSerialFactory()
    h = Harness(hw_env, settings=hardware_settings(), serial_factory=factory)
    await h.start()
    for _ in range(5):
        for port in factory.ports.values():
            port.feed(FocFeedback(0, 0, 0, 0, 3900, 300, 0))
        h.tick(0.05)
    m = h.service.snapshot()["measurements"]
    assert m["battery_voltage"]["status"] == "valid"
    assert m["battery_voltage"]["value"] == 39.0
    assert m["controller_temp_c"]["status"] == "unavailable"  # nicht kalibriert
    assert m["motor_temp_c"]["status"] == "unavailable"
    assert m["electrical_power_w"]["status"] == "unavailable"
    caps = h.service.capabilities()
    assert caps["brake"]["available"] is False
    assert "Kein garantiertes Bremsen" in caps["brake"]["note"]
    await h.close()


async def test_commissioning_mode_limits_until_lifted_test(hw_env) -> None:  # type: ignore[no-untyped-def]
    factory = FakeSerialFactory()
    h = Harness(hw_env, settings=hardware_settings(wheels_lifted_test_passed=False), serial_factory=factory)
    await h.start()
    assert FaultCode.COMMISSIONING.value in h.fault_codes()
    profile = h.service.effective_profile()
    assert profile.max_throttle <= 0.15 and profile.max_speed_kmh <= 3
    await h.close()


async def test_hardware_brake_unsupported_reported_honestly(hw_env) -> None:  # type: ignore[no-untyped-def]
    factory = FakeSerialFactory()
    h = Harness(hw_env, settings=hardware_settings(), serial_factory=factory)
    await h.start()

    def feed() -> None:
        for port in factory.ports.values():
            port.feed(FocFeedback(0, 0, 0, 0, 3900, 300, 0))

    for _ in range(5):
        feed()
        h.tick(0.05)
    s = h.open()
    await h.send(s, "claim_control")
    h.send_sync(s, "drive")
    ack = await h.send(s, "arm")
    assert ack and ack["ok"], ack
    feed()
    h.send_sync(s, "drive", brake=1.0)
    h.tick(0.04)
    assert h.service.brake_state.value == "unsupported"
    # Gas wird als Rohbefehl an beide Controller gesendet (begrenzt durch max_command)
    for _ in range(25):
        feed()
        h.send_sync(s, "drive", throttle=0.5)
        h.tick(0.04)
    steer, speed = factory.ports["/dev/fake-front"].last_command()
    assert 0 < speed <= 300 and steer == 0
    await h.close()


async def test_axle_assignment_swaps_ports(hw_env) -> None:  # type: ignore[no-untyped-def]
    settings = hardware_settings()
    data = settings.model_dump(mode="json")
    data["hardware"]["controllers"][0]["axle"] = "rear"
    data["hardware"]["controllers"][1]["axle"] = "front"
    from app.models.settings import VehicleSettings

    factory = FakeSerialFactory()
    h = Harness(replace(hw_env), settings=VehicleSettings.model_validate(data), serial_factory=factory)
    await h.start()
    coordinator = h.service.build.coordinator  # type: ignore[union-attr]
    assert coordinator is not None
    assert coordinator.controllers[Axle.FRONT].controller_id == "B"
    assert coordinator.controllers[Axle.REAR].controller_id == "A"
    await h.close()
