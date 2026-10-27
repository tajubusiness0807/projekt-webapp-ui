"""WLAN-Signalstärke.

* Client-Modus (Pi in einem vorhandenen WLAN): Pegel aus ``/proc/net/wireless``.
* Access-Point-Modus: Signal des steuernden Geräts über ``iw dev <if> station get <MAC>``;
  die MAC wird über ``/proc/net/arp`` aus der IP der Steuersitzung ermittelt. Die MAC wird nicht gespeichert.

Ist kein Messwert verfügbar, wird im Simulationsmodus ein deutlich gekennzeichneter simulierter Wert
geliefert, im Hardwaremodus „nicht verfügbar".
"""

from __future__ import annotations

import asyncio
import logging
import random
import re
import shutil
from pathlib import Path

from ..models.common import MeasurementStatus
from ..utils.clock import Clock
from .measurement import Measurement

log = logging.getLogger(__name__)

_SIGNAL_RE = re.compile(r"signal:\s*(-?\d+)")


def signal_quality(dbm: float | None) -> str:
    if dbm is None:
        return "unbekannt"
    if dbm >= -55:
        return "stark"
    if dbm >= -67:
        return "gut"
    if dbm >= -75:
        return "mittel"
    return "schwach"


def parse_proc_wireless(text: str, interface: str) -> float | None:
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith(f"{interface}:"):
            continue
        parts = line.split()
        if len(parts) < 4:
            return None
        try:
            level = float(parts[3].rstrip("."))
        except ValueError:
            return None
        if -120 < level < 0:
            return level
    return None


def mac_for_ip(arp_text: str, ip: str) -> str | None:
    for line in arp_text.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 4 and parts[0] == ip and parts[3] != "00:00:00:00:00:00":
            return parts[3]
    return None


def parse_iw_station(text: str) -> float | None:
    match = _SIGNAL_RE.search(text)
    if not match:
        return None
    value = float(match.group(1))
    return value if -120 < value < 0 else None


class WifiMonitor:
    def __init__(self, interface: str, clock: Clock, *, simulated_fallback: bool) -> None:
        self._interface = interface
        self._clock = clock
        self._simulated_fallback = simulated_fallback
        self._value: float | None = None
        self._timestamp: float | None = None
        self._simulated = False
        self._iw = shutil.which("iw")
        self._rng = random.Random(3)
        self.weak_override = False

    async def refresh(self, client_ip: str | None) -> None:
        value = await asyncio.to_thread(self._read_station_mode)
        if value is None and client_ip and self._iw:
            value = await self._read_ap_mode(client_ip)
        now = self._clock.monotonic()
        if value is not None:
            self._value, self._timestamp, self._simulated = value, now, False
        elif self._simulated_fallback:
            base = -82.0 if self.weak_override else -48.0
            self._value, self._timestamp, self._simulated = base + self._rng.uniform(-3, 3), now, True

    def measurement(self, now: float, stale_s: float = 6.0) -> Measurement:
        if self._value is None or self._timestamp is None:
            return Measurement.unavailable("dBm")
        age = now - self._timestamp
        if age > stale_s:
            status = MeasurementStatus.STALE
        else:
            status = MeasurementStatus.SIMULATED if self._simulated else MeasurementStatus.VALID
        return Measurement(round(self._value), status, int(age * 1000), "dBm")

    def _read_station_mode(self) -> float | None:
        try:
            return parse_proc_wireless(Path("/proc/net/wireless").read_text(), self._interface)
        except OSError:
            return None

    async def _read_ap_mode(self, client_ip: str) -> float | None:
        try:
            arp = await asyncio.to_thread(Path("/proc/net/arp").read_text)
        except OSError:
            return None
        mac = mac_for_ip(arp, client_ip)
        if not mac or not self._iw:
            return None
        try:
            proc = await asyncio.create_subprocess_exec(
                self._iw, "dev", self._interface, "station", "get", mac,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            )
            out, _ = await asyncio.wait_for(proc.communicate(), timeout=1.5)
        except (OSError, asyncio.TimeoutError):
            return None
        return parse_iw_station(out.decode("utf-8", "replace"))
