"""Simulationsadapter: verhält sich wie ein Controller, sendet aber niemals reale Motorbefehle."""

from __future__ import annotations

import threading

from ..models.common import Axle, ControllerLinkState
from ..simulation.fault_injection import SimulationFaults
from ..simulation.vehicle_model import VehiclePhysics
from ..utils.clock import Clock
from .base import (
    BrakeSupport,
    ControllerCapabilities,
    ControllerStatus,
    ControllerTelemetry,
    MotorControllerInterface,
    WheelCommand,
)

_SIM_CAPABILITIES = ControllerCapabilities(
    brake=True,
    brake_method="simulated",
    speed_feedback=True,
    voltage_feedback=True,
    controller_temperature=True,
    motor_temperature=True,
    electrical_power=True,
    internal_speed_limit=False,
    simulated=True,
)


class SimulatedMotorController(MotorControllerInterface):
    def __init__(self, controller_id: str, axle: Axle, physics: VehiclePhysics, faults: SimulationFaults, clock: Clock) -> None:
        self.controller_id = controller_id
        self.axle = axle
        self._physics = physics
        self._faults = faults
        self._clock = clock
        self._lock = threading.Lock()
        self._status = ControllerStatus(controller_id, axle, "simulation", port="simulation")
        self._connected = False
        self._error_toggle = 0

    @property
    def capabilities(self) -> ControllerCapabilities:
        return _SIM_CAPABILITIES

    async def connect(self) -> None:
        self._connected = True
        self._status.link = ControllerLinkState.CONNECTED
        self._status.emergency_stopped = False

    async def disconnect(self) -> None:
        self.emergency_stop()
        self._connected = False
        self._status.link = ControllerLinkState.DISCONNECTED

    def set_drive_request(self, command: WheelCommand) -> None:
        if not self._connected:
            return
        with self._lock:
            self._physics.set_brake(self.axle, 0.0)
            self._physics.set_command(self.axle, command)
            self._status.commands_sent += 1
            if not command.is_zero:
                self._status.emergency_stopped = False

    def set_speed_limit(self, limit_kmh: float | None) -> bool:
        return False  # Begrenzung erfolgt im Backend

    def request_brake(self, level: float) -> BrakeSupport:
        if not self._connected:
            return BrakeSupport.DRIVE_OFF_ONLY
        with self._lock:
            self._physics.set_command(self.axle, WheelCommand.zero())
            self._physics.set_brake(self.axle, level)
            self._status.commands_sent += 1
        return BrakeSupport.APPLIED

    def read_telemetry(self) -> ControllerTelemetry | None:
        if not self._connected or self._faults.offline(self.axle):
            if self._connected:
                self._status.link = ControllerLinkState.ERROR
                self._status.last_error = "Keine Rückmeldung (simuliert)"
            return None
        if self._faults.comm_errors(self.axle):
            self._error_toggle += 1
            if self._error_toggle % 3 != 0:
                self._status.frames_bad += 1
                self._status.last_error = "Prüfsummenfehler (simuliert)"
                return None
        now = self._clock.monotonic()
        self._status.link = ControllerLinkState.CONNECTED
        self._status.frames_ok += 1
        self._status.last_feedback_at = now
        p = self._physics
        state = p.axles[self.axle]
        rpm_left = p.wheel_rpm("left")
        rpm_right = p.wheel_rpm("right")
        if self._faults.invalid_data(self.axle):
            rpm_left = 32000.0  # außerhalb jedes plausiblen Bereichs
        return ControllerTelemetry(
            timestamp=now,
            wheel_rpm_left=rpm_left,
            wheel_rpm_right=rpm_right,
            battery_voltage=p.measured_voltage(),
            controller_temp_c=p.controller_temp(self.axle),
            motor_temp_c=state.motor_temp_c,
            electrical_power_w=state.electrical_power_w,
            simulated=True,
        )

    def get_status(self) -> ControllerStatus:
        return self._status

    def emergency_stop(self) -> None:
        with self._lock:
            self._physics.set_command(self.axle, WheelCommand.zero())
            self._physics.set_brake(self.axle, 1.0)
            self._status.emergency_stopped = True

    async def close(self) -> None:
        await self.disconnect()
