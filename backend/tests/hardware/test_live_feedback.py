"""Hardwaretest – NUR mit sicher aufgebauter Hardware und aufgebockten Rädern.

Ausführung: ``AWC_HARDWARE_TESTS=1 AWC_TEST_PORT=/dev/ttyUSB0 pytest tests/hardware -m hardware``

Dieser Test sendet ausschließlich **Nullbefehle** und prüft, ob gültige Rückmeldungen eintreffen.
Er bewegt keine Motoren. Tests mit Motorbewegung sind bewusst nicht automatisiert, sondern als
manuelle Inbetriebnahme-Schritte in ``docs/hardware.md`` beschrieben.
"""

from __future__ import annotations

import os
import time

import pytest

from app.controllers.foc_protocol import FeedbackParser, encode_command

pytestmark = pytest.mark.hardware


def test_controller_answers_zero_commands() -> None:
    serial = pytest.importorskip("serial")
    port = os.environ.get("AWC_TEST_PORT")
    if not port:
        pytest.skip("AWC_TEST_PORT nicht gesetzt")
    parser = FeedbackParser(with_odometry=os.environ.get("AWC_TEST_ODOMETRY") == "1")
    with serial.Serial(port, 115200, timeout=0) as ser:
        end = time.monotonic() + 2.0
        frames = []
        while time.monotonic() < end:
            ser.write(encode_command(0, 0))
            time.sleep(0.05)
            frames.extend(parser.feed(ser.read(ser.in_waiting or 1)))
        ser.write(encode_command(0, 0))
    assert frames, "Keine gültigen Rückmeldungen – Verkabelung, Baudrate und Firmware-Variante prüfen"
    fb = frames[-1]
    assert abs(fb.speed_left_rpm) < 5 and abs(fb.speed_right_rpm) < 5, "Räder drehen trotz Nullbefehl!"
    assert 10 < fb.battery_voltage < 70
