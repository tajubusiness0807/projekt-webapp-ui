"""Codec für das serielle Protokoll der Firmware *hoverboard-firmware-hack-FOC* (EFeru).

Geprüft gegen die Originalquellen (Stand der Analyse, Branch ``main``):

* ``Arduino/hoverserial/hoverserial.ino`` – Referenzimplementierung der Gegenstelle
* ``Src/main.c`` – Aufbau und Versand der Rückmeldung (alle 10 ms)
* ``Src/util.c`` – ``usart_process_command`` (Prüfung von Startframe und Prüfsumme), ``mixerFcn``
* ``Inc/config.h`` – ``SERIAL_START_FRAME 0xABCD``, ``SERIAL_TIMEOUT 160`` (≈ 0,8 s), ±1000 Eingangsbereich

Befehl (8 Byte, Little Endian)::

    uint16 start = 0xABCD
    int16  steer
    int16  speed
    uint16 checksum = start ^ steer ^ speed

Rückmeldung (18 Byte, mit ``ENABLE_ODOMETRY`` 22 Byte)::

    uint16 start, int16 cmd1, int16 cmd2, int16 speedR_meas, int16 speedL_meas,
    [int16 wheelR_cnt, int16 wheelL_cnt,] int16 batVoltage, int16 boardTemp,
    uint16 cmdLed, uint16 checksum   (XOR aller vorherigen Felder)

Einheiten: Drehzahl U/min, ``batVoltage`` V·100, ``boardTemp`` °C·10 (nur nach Kalibrierung gültig).

Wichtig: Die Kompatibilität eines konkreten Mainboards mit dieser Firmware ist damit nicht belegt.
Der Adapter wird nur nach expliziter Konfiguration und abgeschlossener Checkliste aktiviert.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

START_FRAME = 0xABCD
INPUT_LIMIT = 1000

COMMAND_STRUCT = struct.Struct("<HhhH")
FEEDBACK_STRUCT = struct.Struct("<HhhhhhhHH")
FEEDBACK_ODOMETRY_STRUCT = struct.Struct("<HhhhhhhhhHH")
_START_BYTES = struct.pack("<H", START_FRAME)


def _u16(value: int) -> int:
    return value & 0xFFFF


def encode_command(steer: int, speed: int) -> bytes:
    """Erzeugt einen Befehlsrahmen. Werte außerhalb ±1000 werden abgelehnt (nicht stillschweigend begrenzt)."""
    if not (-INPUT_LIMIT <= steer <= INPUT_LIMIT and -INPUT_LIMIT <= speed <= INPUT_LIMIT):
        raise ValueError(f"Befehl außerhalb ±{INPUT_LIMIT}: steer={steer}, speed={speed}")
    checksum = _u16(START_FRAME ^ _u16(steer) ^ _u16(speed))
    return COMMAND_STRUCT.pack(START_FRAME, steer, speed, checksum)


def decode_command(frame: bytes) -> tuple[int, int]:
    """Dekodiert einen Befehlsrahmen (für Tests und Diagnose)."""
    start, steer, speed, checksum = COMMAND_STRUCT.unpack(frame)
    if start != START_FRAME or checksum != _u16(start ^ _u16(steer) ^ _u16(speed)):
        raise ValueError("Ungültiger Befehlsrahmen")
    return steer, speed


@dataclass(frozen=True)
class FocFeedback:
    cmd1: int
    cmd2: int
    speed_right_rpm: int
    speed_left_rpm: int
    battery_voltage_centi: int
    board_temp_deci: int
    cmd_led: int
    wheel_right_count: int | None = None
    wheel_left_count: int | None = None

    @property
    def battery_voltage(self) -> float:
        return self.battery_voltage_centi / 100.0

    @property
    def board_temp_c(self) -> float:
        return self.board_temp_deci / 10.0


def encode_feedback(fb: FocFeedback, *, with_odometry: bool = False) -> bytes:
    """Erzeugt einen Rückmelderahmen wie die Firmware (für Tests)."""
    if with_odometry:
        fields = [
            START_FRAME, fb.cmd1, fb.cmd2, fb.speed_right_rpm, fb.speed_left_rpm,
            fb.wheel_right_count or 0, fb.wheel_left_count or 0,
            fb.battery_voltage_centi, fb.board_temp_deci, fb.cmd_led,
        ]
        checksum = 0
        for value in fields:
            checksum ^= _u16(value)
        return FEEDBACK_ODOMETRY_STRUCT.pack(*fields, checksum)
    fields = [
        START_FRAME, fb.cmd1, fb.cmd2, fb.speed_right_rpm, fb.speed_left_rpm,
        fb.battery_voltage_centi, fb.board_temp_deci, fb.cmd_led,
    ]
    checksum = 0
    for value in fields:
        checksum ^= _u16(value)
    return FEEDBACK_STRUCT.pack(*fields, checksum)


class FeedbackParser:
    """Robuster Stream-Parser mit Resynchronisation auf das Startframe."""

    MAX_BUFFER = 512

    def __init__(self, *, with_odometry: bool = False) -> None:
        self._struct = FEEDBACK_ODOMETRY_STRUCT if with_odometry else FEEDBACK_STRUCT
        self._with_odometry = with_odometry
        self._buffer = bytearray()
        self.frames_ok = 0
        self.frames_bad = 0

    @property
    def frame_size(self) -> int:
        return self._struct.size

    def feed(self, data: bytes) -> list[FocFeedback]:
        self._buffer.extend(data)
        if len(self._buffer) > self.MAX_BUFFER:
            del self._buffer[: len(self._buffer) - self.MAX_BUFFER]
        frames: list[FocFeedback] = []
        size = self._struct.size
        while True:
            idx = self._buffer.find(_START_BYTES)
            if idx < 0:
                # Letztes Byte behalten – es könnte die erste Hälfte des Startframes sein.
                del self._buffer[:-1]
                break
            if idx > 0:
                del self._buffer[:idx]
            if len(self._buffer) < size:
                break
            values = self._struct.unpack_from(self._buffer, 0)
            checksum = 0
            for value in values[:-1]:
                checksum ^= _u16(value)
            if checksum != values[-1]:
                self.frames_bad += 1
                del self._buffer[:1]
                continue
            del self._buffer[:size]
            self.frames_ok += 1
            frames.append(self._to_feedback(values))
        return frames

    def _to_feedback(self, v: tuple[int, ...]) -> FocFeedback:
        if self._with_odometry:
            return FocFeedback(
                cmd1=v[1], cmd2=v[2], speed_right_rpm=v[3], speed_left_rpm=v[4],
                wheel_right_count=v[5], wheel_left_count=v[6],
                battery_voltage_centi=v[7], board_temp_deci=v[8], cmd_led=v[9],
            )
        return FocFeedback(
            cmd1=v[1], cmd2=v[2], speed_right_rpm=v[3], speed_left_rpm=v[4],
            battery_voltage_centi=v[5], board_temp_deci=v[6], cmd_led=v[7],
        )


def wheels_to_steer_speed(
    left: float, right: float, *, speed_coefficient: float, steer_coefficient: float, max_command: int
) -> tuple[int, int]:
    """Rechnet normierte Radanforderungen in ``(steer, speed)`` für den Firmware-Mischer um.

    Firmware: ``R = speed·Ks − steer·Kt`` und ``L = speed·Ks + steer·Kt``.
    Daraus: ``speed = (L + R) / (2·Ks)`` und ``steer = (L − R) / (2·Kt)``.
    Ist ``Kt = 0`` (Lenkung in der Firmware deaktiviert), kann keine Seitendifferenz erzeugt werden.
    """
    limit = max(0, min(INPUT_LIMIT, int(max_command)))
    left_raw = max(-1.0, min(1.0, left)) * limit
    right_raw = max(-1.0, min(1.0, right)) * limit
    speed = (left_raw + right_raw) / (2.0 * speed_coefficient)
    steer = 0.0 if steer_coefficient <= 0 else (left_raw - right_raw) / (2.0 * steer_coefficient)
    speed_i = int(round(max(-INPUT_LIMIT, min(INPUT_LIMIT, speed))))
    steer_i = int(round(max(-INPUT_LIMIT, min(INPUT_LIMIT, steer))))
    return steer_i, speed_i
