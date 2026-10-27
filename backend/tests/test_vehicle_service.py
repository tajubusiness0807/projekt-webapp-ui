"""Fahrzeugdienst mit simulierten Controllern und manueller Uhr (nur Simulation)."""

from __future__ import annotations

import pytest

from app.models.common import Axle, BrakeState, DriveProfileName, MeasurementStatus, OperatingMode, Role, VehicleState
from app.models.faults import FaultCode

from .conftest import Harness


async def armed(h: Harness, client: str = "fahrer"):
    session = h.open(client)
    ack = await h.send(session, "claim_control")
    assert ack and ack["ok"], ack
    h.send_sync(session, "drive")
    ack = await h.send(session, "arm")
    assert ack and ack["ok"], ack
    return session


def speed(h: Harness) -> float:
    m = h.service.snapshot()["measurements"]["speed_kmh"]
    return m["value"] or 0.0


async def test_startup_is_simulation_and_locked(harness: Harness) -> None:
    snap = harness.service.snapshot()
    assert snap["mode"] == "simulation"
    assert snap["vehicle"]["state"] == "locked"
    assert snap["vehicle"]["armed"] is False
    harness.tick(steps=5)
    assert snap["measurements"]["battery_voltage"]["status"] in ("simulated", "unavailable")
    assert harness.service.snapshot()["measurements"]["battery_voltage"]["status"] == "simulated"


async def test_arm_requires_ownership_and_neutral(harness: Harness) -> None:
    s = harness.open()
    ack = await harness.send(s, "arm")
    assert ack and ack["code"] == "NOT_OWNER"
    await harness.send(s, "claim_control")
    harness.send_sync(s, "drive", throttle=0.5)
    ack = await harness.send(s, "arm")
    assert ack and not ack["ok"] and "Gas" in ack["message"]
    harness.send_sync(s, "drive", throttle=0.0)
    ack = await harness.send(s, "arm")
    assert ack and ack["ok"]


async def test_throttle_accelerates_and_release_zeroes_request(harness: Harness) -> None:
    s = await armed(harness)
    harness.run(2.0, session=s, throttle=1.0)
    assert speed(harness) > 2.0
    assert harness.service.last_output.drive_level > 0
    harness.send_sync(s, "drive", throttle=0.0)
    harness.tick()
    assert harness.service.last_output.drive_level == 0.0
    assert harness.service.brake_state == BrakeState.COASTING


async def test_brake_states_in_simulation(harness: Harness) -> None:
    s = await armed(harness)
    harness.run(2.0, session=s, throttle=1.0)
    harness.run(0.4, session=s, brake=1.0)
    assert harness.service.brake_state in (BrakeState.REQUESTED, BrakeState.CONFIRMED)
    harness.run(1.0, session=s, brake=1.0)
    assert harness.service.brake_state == BrakeState.CONFIRMED
    assert speed(harness) < 3.0


async def test_dead_man_command_timeout_sets_neutral_latch(harness: Harness) -> None:
    s = await armed(harness)
    harness.run(1.0, session=s, throttle=1.0)
    level_before = harness.service.last_output.drive_level
    assert level_before > 0
    harness.tick(0.04, steps=10)  # 400 ms keine Befehle (> 300 ms)
    assert harness.service.last_output.drive_level == 0.0
    assert FaultCode.COMMAND_STALE.value in harness.fault_codes()
    assert harness.service.safety.neutral_required
    # Befehle kommen wieder, aber Gas ist noch gedrückt → bleibt gesperrt
    harness.run(0.5, session=s, throttle=1.0)
    assert harness.service.last_output.drive_level == 0.0
    # Erst nach Loslassen wieder Gas möglich
    harness.run(0.08, session=s, throttle=0.0)
    harness.run(0.5, session=s, throttle=1.0)
    assert harness.service.last_output.drive_level > 0
    assert FaultCode.COMMAND_STALE.value not in harness.fault_codes()


async def test_connection_loss_disarms_and_requires_acknowledge(harness: Harness) -> None:
    s = await armed(harness)
    harness.run(1.0, session=s, throttle=1.0)
    harness.service.close_session(s)
    harness.tick()
    assert harness.service.safety.state == VehicleState.FAULT
    assert FaultCode.CONNECTION_LOST.value in harness.fault_codes()
    assert harness.service.last_output.drive_level == 0.0
    # Wiederverbindung desselben Geräts: Besitz zurück, aber gesperrt und neutral
    s2 = harness.open("fahrer")
    assert harness.service.sessions.is_owner(s2)
    assert not harness.service.safety.armed
    harness.run(2.0)  # Fahrzeug rollt aus / bremst
    ack = await harness.send(s2, "ack_faults")
    assert ack and ack["ok"]
    assert harness.service.safety.state == VehicleState.LOCKED


async def test_silent_owner_triggers_connection_lost(harness: Harness) -> None:
    await armed(harness)
    harness.tick(0.1, steps=12)  # 1,2 s ohne Nachricht (> 1000 ms)
    assert FaultCode.CONNECTION_LOST.value in harness.fault_codes()
    assert not harness.service.safety.armed


async def test_single_controller_failure_stops_vehicle(harness: Harness) -> None:
    s = await armed(harness)
    harness.run(1.5, session=s, throttle=1.0)
    await harness.send(s, "sim_inject", fault="front_offline", active=True)
    harness.run(0.8, session=s, throttle=1.0)
    assert FaultCode.SINGLE_CONTROLLER.value in harness.fault_codes()
    assert harness.service.safety.state == VehicleState.FAULT
    assert harness.service.last_output.drive_level == 0.0
    await harness.send(s, "sim_inject", fault="front_offline", active=False)
    harness.run(0.5, session=s)
    ack = await harness.send(s, "ack_faults")
    assert ack and ack["ok"], ack
    assert harness.service.safety.state == VehicleState.LOCKED


async def test_both_controllers_offline_is_e001(harness: Harness) -> None:
    s = harness.open()
    await harness.send(s, "claim_control")
    await harness.send(s, "sim_inject", fault="front_offline", active=True)
    await harness.send(s, "sim_inject", fault="rear_offline", active=True)
    harness.tick(0.1, steps=8)
    assert FaultCode.NO_CONTROLLER.value in harness.fault_codes()


async def test_invalid_telemetry_and_comm_errors(harness: Harness) -> None:
    s = harness.open()
    await harness.send(s, "claim_control")
    await harness.send(s, "sim_inject", fault="front_invalid_data", active=True)
    await harness.send(s, "sim_inject", fault="rear_comm_errors", active=True)
    harness.tick(0.04, steps=40)
    codes = harness.fault_codes()
    assert FaultCode.INVALID_TELEMETRY.value in codes
    assert FaultCode.COMMUNICATION_ERROR.value in codes
    assert harness.service.safety.state == VehicleState.FAULT


async def test_overtemperature_and_low_battery(harness: Harness) -> None:
    s = harness.open()
    await harness.send(s, "claim_control")
    await harness.send(s, "sim_inject", fault="overtemperature", active=True)
    await harness.send(s, "sim_inject", fault="battery_critical", active=True)
    harness.tick(0.1, steps=25)
    codes = harness.fault_codes()
    assert FaultCode.OVER_TEMPERATURE.value in codes
    assert FaultCode.LOW_BATTERY.value in codes


async def test_battery_warning_reduces_power(harness: Harness) -> None:
    s = await armed(harness)
    await harness.send(s, "sim_inject", fault="battery_warning", active=True)
    harness.run(3.0, session=s, throttle=1.0)
    assert FaultCode.BATTERY_WARNING.value in harness.fault_codes()
    assert "akku" in harness.service.last_output.limited_by
    assert harness.service.safety.armed  # Warnung blockiert nicht


async def test_emergency_stop_by_observer_and_reset_by_owner(harness: Harness) -> None:
    owner = await armed(harness)
    observer = harness.open("beobachter")
    harness.run(1.0, session=owner, throttle=1.0)
    ack = await harness.send(observer, "estop", reason="Test")
    assert ack and ack["ok"]
    assert harness.service.safety.state == VehicleState.EMERGENCY_STOP
    harness.tick()
    assert harness.service.last_output.drive_level == 0.0
    ack = await harness.send(observer, "estop_reset")
    assert ack and ack["code"] == "NOT_OWNER"
    ack = await harness.send(owner, "estop_reset")
    assert ack and ack["ok"]
    assert harness.service.safety.state == VehicleState.LOCKED


async def test_profile_mismatch_and_contradictory_commands(harness: Harness) -> None:
    s = await armed(harness)
    harness.send_sync(s, "drive", throttle=1.0, profile="sport")
    assert harness.last_ack(s)["code"] == "PROFILE_MISMATCH"  # type: ignore[index]
    harness.send_sync(s, "drive", throttle=1.0, brake=1.0)
    assert harness.last_ack(s)["code"] == "CONTRADICTORY"  # type: ignore[index]
    harness.tick()
    assert harness.service.last_input.throttle == 0.0 and harness.service.last_input.brake == 1.0


async def test_non_owner_cannot_drive(harness: Harness) -> None:
    await armed(harness, "fahrer")
    other = harness.open("zweites")
    harness.send_sync(other, "drive", throttle=1.0)
    assert harness.last_ack(other)["code"] == "NOT_OWNER"  # type: ignore[index]
    ack = await harness.send(other, "claim_control")
    assert ack and not ack["ok"] and ack["code"] == "CONTROL_BUSY"


async def test_takeover_only_when_standing_and_disarms(harness: Harness) -> None:
    owner = await armed(harness, "fahrer")
    other = harness.open("zweites")
    harness.run(2.0, session=owner, throttle=1.0)
    ack = await harness.send(other, "takeover_control")
    assert ack and ack["code"] == "VEHICLE_MOVING"
    harness.run(3.0, session=owner, brake=1.0)
    ack = await harness.send(other, "takeover_control")
    assert ack and ack["ok"]
    assert harness.service.sessions.is_owner(other)
    assert not harness.service.safety.armed
    # Alter Besitzer kann nicht mehr fahren
    harness.send_sync(owner, "drive", throttle=1.0)
    assert harness.last_ack(owner)["code"] == "NOT_OWNER"  # type: ignore[index]


async def test_profiles_change_response(env) -> None:  # type: ignore[no-untyped-def]
    results = {}
    for profile in ("eco", "sport"):
        h = Harness(env)
        await h.start()
        s = await armed(h, f"p-{profile}")
        await h.send(s, "set_profile", profile=profile)
        h.run(2.0, session=s, throttle=1.0)
        results[profile] = speed(h)
        await h.close()
    assert results["sport"] > results["eco"] * 1.3


async def test_custom_split_changes_axle_outputs(harness: Harness) -> None:
    s = await armed(harness)
    await harness.send(s, "set_drive_mode", mode="custom")
    ack = await harness.send(s, "set_power_split", target="custom", front_percent=100)
    assert ack and ack["ok"]
    harness.run(1.0, session=s, throttle=0.6)
    out = harness.service.last_output
    assert out.wheels[Axle.REAR].is_zero and not out.wheels[Axle.FRONT].is_zero
    ack = await harness.send(s, "set_power_split", target="awd", front_percent=95)
    assert ack and not ack["ok"] and ack["code"] == "INVALID_SETTINGS"


async def test_direction_change_only_at_standstill(harness: Harness) -> None:
    s = await armed(harness)
    harness.run(1.5, session=s, throttle=1.0)
    ack = await harness.send(s, "set_direction", direction="reverse")
    assert ack and ack["code"] == "NOT_STANDING"
    harness.run(3.0, session=s, brake=1.0)
    ack = await harness.send(s, "set_direction", direction="reverse")
    assert ack and ack["ok"]
    harness.run(1.0, session=s, throttle=1.0)
    assert harness.service.snapshot()["measurements"]["speed_kmh"]["value"] > 0
    assert harness.service.telemetry.speed_kmh(harness.clock.monotonic(), 1.0, 0.165).value < 0  # rückwärts


async def test_loop_stall_raises_watchdog_fault(harness: Harness) -> None:
    await armed(harness)
    harness.tick(1.2)  # ein Zyklus dauerte 1,2 s
    assert FaultCode.WATCHDOG.value in harness.fault_codes()
    assert not harness.service.safety.armed


async def test_supervisor_trip_is_reported_by_loop(harness: Harness) -> None:
    harness.service._supervisor.tripped.set()
    harness.tick()
    assert FaultCode.WATCHDOG.value in harness.fault_codes()


async def test_driver_settings_validated_and_admin_sections_protected(harness: Harness) -> None:
    s = harness.open()
    await harness.send(s, "claim_control")
    ack = await harness.send(s, "update_settings", patch={"profiles": {"sport": {"max_speed_kmh": 15}}})
    assert ack and ack["ok"] and ack["version"] == 2
    ack = await harness.send(s, "update_settings", patch={"safety": {"absolute_max_speed_kmh": 40}})
    assert ack and not ack["ok"] and "Administratorrechte" in ack["message"]
    admin = harness.open("admin", Role.ADMIN)
    await harness.send(s, "release_control")
    await harness.send(admin, "claim_control")
    ack = await harness.send(admin, "update_settings", patch={"safety": {"absolute_max_speed_kmh": 10}})
    assert ack and ack["ok"]
    assert harness.service.effective_profile(DriveProfileName.SPORT).max_speed_kmh == 10


async def test_hardware_change_requires_restart(harness: Harness) -> None:
    admin = harness.open("admin", Role.ADMIN)
    await harness.send(admin, "claim_control")
    ack = await harness.send(admin, "update_settings", patch={"hardware": {"mode": "hardware"}})
    assert ack and ack["ok"]
    assert harness.service.restart_required
    assert harness.service.mode == OperatingMode.SIMULATION  # wirkt erst nach Neustart


async def test_measurements_are_flagged_simulated(harness: Harness) -> None:
    harness.tick(steps=3)
    m = harness.service.snapshot()["measurements"]
    for key in ("speed_kmh", "motor_rpm", "battery_voltage", "controller_temp_c", "motor_temp_c"):
        assert m[key]["status"] == MeasurementStatus.SIMULATED.value, key


async def test_stale_controller_values_are_marked_stale(harness: Harness) -> None:
    s = harness.open()
    await harness.send(s, "claim_control")
    harness.tick(steps=3)
    await harness.send(s, "sim_inject", fault="front_offline", active=True)
    await harness.send(s, "sim_inject", fault="rear_offline", active=True)
    harness.tick(0.1, steps=15)
    m = harness.service.snapshot()["measurements"]
    assert m["battery_voltage"]["status"] == "stale"
    assert m["speed_kmh"]["status"] == "stale"


async def test_sim_injection_rejected_for_unknown_fault(harness: Harness) -> None:
    s = harness.open()
    await harness.send(s, "claim_control")
    ack = await harness.send(s, "sim_inject", fault="nicht_vorhanden", active=True)
    assert ack and ack["code"] == "UNKNOWN_FAULT"


@pytest.mark.parametrize("mode", ["fwd", "rwd", "custom"])
async def test_all_drive_modes_selectable_in_simulation(harness: Harness, mode: str) -> None:
    s = harness.open()
    await harness.send(s, "claim_control")
    ack = await harness.send(s, "set_drive_mode", mode=mode)
    assert ack and ack["ok"]
    assert harness.service.drive_mode.value == mode
