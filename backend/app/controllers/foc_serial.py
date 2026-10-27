"""Hardwareadapter für **einen** Hoverboard-Controller mit FOC-Firmware über UART.

Aktivierung nur, wenn ``app.controllers.factory.hardware_readiness`` vollständig erfüllt ist. Der
Adapter selbst sendet ausschließlich bereits geprüfte, begrenzte Befehle aus der Regelschleife.

Bremsen
-------
Das USART-Protokoll kennt keinen eigenen Bremsbefehl. Je nach Firmware-Regelmodus:

* ``voltage_mode_zero`` – im VLT_MODE erzeugt der Nullbefehl elektrisch eine Verzögerung.
* ``counter_torque`` – im TRQ_MODE wird ein der Drehrichtung entgegengesetztes Moment angefordert,
  das unterhalb einer Mindestdrehzahl auf 0 geht (kein Rückwärtsanfahren).

Beide Methoden gelten nur als Bremse, wenn ``brake_verified`` gesetzt ist **und** der konfigurierte
Regelmodus passt. Andernfalls wird nur der Antrieb abgeschaltet und dies ehrlich gemeldet.
"""

from __future__ import annotations

import asyncio
import logging
import threading
from typing import Any, Callable

from ..models.common import ControllerLinkState
from ..models.settings import ControllerSettings, HardwareSettings
from ..utils.clock import Clock
from .base import (
    BrakeSupport,
    ControllerCapabilities,
    ControllerStatus,
    ControllerTelemetry,
    MotorControllerInterface,
    WheelCommand,
)
from .foc_protocol import FeedbackParser, encode_command, wheels_to_steer_speed

log = logging.getLogger(__name__)

SerialFactory = Callable[[ControllerSettings], Any]

COUNTER_TORQUE_MIN_RPM = 8.0
COUNTER_TORQUE_MAX_SHARE = 0.5  # max. Anteil von max_command beim Gegenmoment


def default_serial_factory(cfg: ControllerSettings) -> Any:
    import serial  # pyserial, erst bei Bedarf importiert

    return serial.Serial(
        port=cfg.port,
        baudrate=cfg.baudrate,
        bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=0,
        write_timeout=0,
    )


def brake_is_usable(hw: HardwareSettings) -> bool:
    if not hw.brake_verified:
        return False
    if hw.brake_method == "voltage_mode_zero":
        return hw.firmware_control_mode == "voltage"
    if hw.brake_method == "counter_torque":
        return hw.firmware_control_mode == "torque"
    return False


class HoverboardFocSerialController(MotorControllerInterface):
    def __init__(
        self,
        cfg: ControllerSettings,
        hw: HardwareSettings,
        clock: Clock,
        serial_factory: SerialFactory | None = None,
    ) -> None:
        self.controller_id = cfg.id
        self.axle = cfg.axle
        self._cfg = cfg
        self._hw = hw
        self._clock = clock
        self._serial_factory = serial_factory or default_serial_factory
        self._serial: Any = None
        self._io_lock = threading.Lock()
        self._parser = FeedbackParser(with_odometry=cfg.feedback_with_odometry)
        self._status = ControllerStatus(cfg.id, cfg.axle, "hoverboard_foc_usart", port=cfg.port)
        self._latest: ControllerTelemetry | None = None
        self._last_rpm: tuple[float, float] = (0.0, 0.0)
        brake_ok = brake_is_usable(hw)
        self._capabilities = ControllerCapabilities(
            brake=brake_ok,
            brake_method=hw.brake_method if brake_ok else "none",
            speed_feedback=True,
            voltage_feedback=True,
            controller_temperature=hw.temperature_calibrated,
            motor_temperature=False,  # Nicht im Feedback enthalten
            electrical_power=False,  # Kein Strom im Feedback enthalten
            internal_speed_limit=False,
            simulated=False,
        )

    @property
    def capabilities(self) -> ControllerCapabilities:
        return self._capabilities

    # ------------------------------------------------------------------ Verbindung
    async def connect(self) -> None:
        self._status.link = ControllerLinkState.CONNECTING
        try:
            self._serial = await asyncio.to_thread(self._serial_factory, self._cfg)
            await asyncio.to_thread(self._serial.reset_input_buffer)
        except Exception as exc:  # pyserial wirft SerialException/OSError
            self._serial = None
            self._status.link = ControllerLinkState.ERROR
            self._status.last_error = f"Schnittstelle {self._cfg.port} nicht verfügbar: {exc}"
            log.error("Controller %s: %s", self.controller_id, self._status.last_error)
            return
        # Erst ein gültiges Feedback setzt den Zustand auf CONNECTED.
        self._send_raw(0, 0)

    async def disconnect(self) -> None:
        self.emergency_stop()
        await asyncio.to_thread(self._close_port)
        self._status.link = ControllerLinkState.DISCONNECTED

    async def close(self) -> None:
        await self.disconnect()

    def _close_port(self) -> None:
        with self._io_lock:
            if self._serial is not None:
                try:
                    self._serial.close()
                except Exception:  # pragma: no cover - best effort
                    pass
                self._serial = None

    # ------------------------------------------------------------------ Befehle
    def set_drive_request(self, command: WheelCommand) -> None:
        left, right = self._map_command(command.clamped())
        steer, speed = wheels_to_steer_speed(
            left,
            right,
            speed_coefficient=self._cfg.speed_coefficient,
            steer_coefficient=self._cfg.steer_coefficient,
            max_command=self._cfg.max_command,
        )
        self._send_raw(steer, speed)
        if not command.is_zero:
            self._status.emergency_stopped = False

    def set_speed_limit(self, limit_kmh: float | None) -> bool:
        return False  # Das USART-Protokoll bietet keine Geschwindigkeitsgrenze; Backend begrenzt.

    def request_brake(self, level: float) -> BrakeSupport:
        level = max(0.0, min(1.0, level))
        if not self._capabilities.brake:
            self._send_raw(0, 0)
            return BrakeSupport.DRIVE_OFF_ONLY
        if self._hw.brake_method == "voltage_mode_zero":
            self._send_raw(0, 0)
            return BrakeSupport.APPLIED
        # counter_torque: Gegenmoment entgegen der gemessenen Drehrichtung, im Stillstand 0.
        rpm_left, rpm_right = self._last_rpm

        def counter(rpm: float) -> float:
            if abs(rpm) < COUNTER_TORQUE_MIN_RPM:
                return 0.0
            return -COUNTER_TORQUE_MAX_SHARE * level * (1.0 if rpm > 0 else -1.0)

        self.set_drive_request(WheelCommand(counter(rpm_left), counter(rpm_right)))
        return BrakeSupport.APPLIED

    def emergency_stop(self) -> None:
        self._send_raw(0, 0)
        self._status.emergency_stopped = True

    def _map_command(self, command: WheelCommand) -> tuple[float, float]:
        left, right = command.left, command.right
        if self._cfg.invert_left_command:
            left = -left
        if self._cfg.invert_right_command:
            right = -right
        if self._cfg.swap_sides:
            left, right = right, left
        return left, right

    def _send_raw(self, steer: int, speed: int) -> None:
        frame = encode_command(steer, speed)
        with self._io_lock:
            if self._serial is None:
                return
            try:
                self._serial.write(frame)
                self._status.commands_sent += 1
            except Exception as exc:
                self._status.write_errors += 1
                self._status.last_error = f"Schreibfehler: {exc}"

    # ------------------------------------------------------------------ Rückmeldung
    def read_telemetry(self) -> ControllerTelemetry | None:
        with self._io_lock:
            if self._serial is None:
                return self._latest
            try:
                waiting = self._serial.in_waiting
                data = self._serial.read(waiting) if waiting else b""
            except Exception as exc:
                self._status.link = ControllerLinkState.ERROR
                self._status.last_error = f"Lesefehler: {exc}"
                return self._latest
        frames = self._parser.feed(data) if data else []
        self._status.frames_ok = self._parser.frames_ok
        self._status.frames_bad = self._parser.frames_bad
        if frames:
            fb = frames[-1]
            now = self._clock.monotonic()
            left = float(fb.speed_left_rpm)
            right = float(fb.speed_right_rpm)
            if self._cfg.swap_sides:
                left, right = right, left
            if self._cfg.invert_left_feedback:
                left = -left
            if self._cfg.invert_right_feedback:
                right = -right
            self._last_rpm = (left, right)
            self._latest = ControllerTelemetry(
                timestamp=now,
                wheel_rpm_left=left,
                wheel_rpm_right=right,
                battery_voltage=fb.battery_voltage,
                controller_temp_c=fb.board_temp_c if self._hw.temperature_calibrated else None,
                motor_temp_c=None,
                electrical_power_w=None,
                simulated=False,
                raw={"cmd1": fb.cmd1, "cmd2": fb.cmd2, "cmd_led": fb.cmd_led},
            )
            self._status.last_feedback_at = now
            self._status.link = ControllerLinkState.CONNECTED
            self._status.last_error = None
        return self._latest

    def get_status(self) -> ControllerStatus:
        return self._status
