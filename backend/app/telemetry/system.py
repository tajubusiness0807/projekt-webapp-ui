"""Zustand des Raspberry Pi: CPU-Temperatur, Last, Speicher, Unterspannung.

Die Unterspannungs-Flags (``get_throttled``) sind beim Pi 3B mit DC/DC-Wandler besonders wichtig:
Spannungseinbrüche führen zu Hängern oder Neustarts der Steuerung.
"""

from __future__ import annotations

import os
import platform
import sys
import time
from pathlib import Path
from typing import Any

THROTTLED_PATHS = (
    Path("/sys/devices/platform/soc/soc:firmware/get_throttled"),
    Path("/sys/devices/platform/soc/soc:firmware/raspberrypi-hwmon/hwmon/hwmon0/in0_lcrit_alarm"),
)

_THROTTLE_BITS = {
    0: "Unterspannung aktiv",
    1: "Taktfrequenz begrenzt",
    2: "Gedrosselt",
    3: "Temperaturgrenze aktiv",
    16: "Unterspannung seit Start aufgetreten",
    17: "Taktbegrenzung seit Start aufgetreten",
    18: "Drosselung seit Start aufgetreten",
    19: "Temperaturgrenze seit Start aufgetreten",
}


def _read(path: Path) -> str | None:
    try:
        return path.read_text().strip()
    except OSError:
        return None


def decode_throttled(value: int) -> list[str]:
    return [text for bit, text in _THROTTLE_BITS.items() if value & (1 << bit)]


class SystemMonitor:
    def __init__(self) -> None:
        self._started = time.monotonic()
        self._model = _read(Path("/proc/device-tree/model"))
        if self._model:
            self._model = self._model.rstrip("\x00")

    def snapshot(self) -> dict[str, Any]:
        cpu_temp = None
        raw = _read(Path("/sys/class/thermal/thermal_zone0/temp"))
        if raw and raw.lstrip("-").isdigit():
            cpu_temp = int(raw) / 1000.0
        try:
            load = os.getloadavg()
        except OSError:
            load = (0.0, 0.0, 0.0)
        mem_total = mem_avail = None
        meminfo = _read(Path("/proc/meminfo"))
        if meminfo:
            for line in meminfo.splitlines():
                if line.startswith("MemTotal:"):
                    mem_total = int(line.split()[1]) // 1024
                elif line.startswith("MemAvailable:"):
                    mem_avail = int(line.split()[1]) // 1024
        rss = None
        status = _read(Path("/proc/self/status"))
        if status:
            for line in status.splitlines():
                if line.startswith("VmRSS:"):
                    rss = int(line.split()[1]) // 1024
        throttled_flags: list[str] | None = None
        throttled_raw = _read(THROTTLED_PATHS[0])
        if throttled_raw:
            try:
                throttled_flags = decode_throttled(int(throttled_raw, 16))
            except ValueError:
                throttled_flags = None
        return {
            "model": self._model or platform.machine(),
            "platform": f"{platform.system()} {platform.release()}",
            "python": sys.version.split()[0],
            "cpu_count": os.cpu_count(),
            "cpu_temp_c": cpu_temp,
            "load_avg": [round(x, 2) for x in load],
            "mem_total_mb": mem_total,
            "mem_available_mb": mem_avail,
            "process_rss_mb": rss,
            "throttled": throttled_flags,
            "uptime_s": int(time.monotonic() - self._started),
        }
