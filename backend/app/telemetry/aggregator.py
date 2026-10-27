"""Zusammenführung und Plausibilisierung der Rückmeldungen beider Controller."""

from __future__ import annotations

import math
from dataclasses import dataclass

from ..controllers.base import ControllerTelemetry
from ..models.common import Axle, MeasurementStatus
from ..models.settings import BatterySettings
from .battery import estimate_percent
from .measurement import Measurement, TrackedValue

# Plausibilitätsgrenzen – Werte außerhalb gelten als ungültige Messdaten (Fehler E004).
PLAUSIBLE_RPM = 2500.0
PLAUSIBLE_VOLTAGE = (5.0, 100.0)
PLAUSIBLE_TEMP = (-30.0, 150.0)
PLAUSIBLE_POWER = (-5000.0, 10000.0)


def validate_telemetry(t: ControllerTelemetry) -> str | None:
    for name, rpm in (("links", t.wheel_rpm_left), ("rechts", t.wheel_rpm_right)):
        if rpm is not None and (not math.isfinite(rpm) or abs(rpm) > PLAUSIBLE_RPM):
            return f"Drehzahl {name} unplausibel ({rpm:.0f} U/min)"
    if t.battery_voltage is not None and not (PLAUSIBLE_VOLTAGE[0] <= t.battery_voltage <= PLAUSIBLE_VOLTAGE[1]):
        return f"Akkuspannung unplausibel ({t.battery_voltage:.2f} V)"
    for name, temp in (("Controller", t.controller_temp_c), ("Motor", t.motor_temp_c)):
        if temp is not None and not (PLAUSIBLE_TEMP[0] <= temp <= PLAUSIBLE_TEMP[1]):
            return f"{name}-Temperatur unplausibel ({temp:.1f} °C)"
    if t.electrical_power_w is not None and not (PLAUSIBLE_POWER[0] <= t.electrical_power_w <= PLAUSIBLE_POWER[1]):
        return "Leistungswert unplausibel"
    return None


@dataclass
class _AxleValues:
    rpm_left: TrackedValue
    rpm_right: TrackedValue
    voltage: TrackedValue
    controller_temp: TrackedValue
    motor_temp: TrackedValue
    power: TrackedValue


def _worst_status(measurements: list[Measurement]) -> MeasurementStatus:
    statuses = {m.status for m in measurements}
    if not statuses or statuses == {MeasurementStatus.UNAVAILABLE}:
        return MeasurementStatus.UNAVAILABLE
    if MeasurementStatus.STALE in statuses:
        return MeasurementStatus.STALE
    if MeasurementStatus.SIMULATED in statuses:
        return MeasurementStatus.SIMULATED
    return MeasurementStatus.VALID


class DrivetrainTelemetry:
    def __init__(self) -> None:
        self.axles: dict[Axle, _AxleValues] = {
            axle: _AxleValues(
                TrackedValue("U/min"), TrackedValue("U/min"), TrackedValue("V"),
                TrackedValue("°C"), TrackedValue("°C"), TrackedValue("W"),
            )
            for axle in Axle
        }
        self.invalid_reason: dict[Axle, str | None] = {axle: None for axle in Axle}

    def ingest(self, axle: Axle, telemetry: ControllerTelemetry | None) -> None:
        """Übernimmt eine Rückmeldung. Unplausible Pakete werden verworfen und gemeldet."""
        if telemetry is None:
            return
        reason = validate_telemetry(telemetry)
        self.invalid_reason[axle] = reason
        if reason is not None:
            return
        values = self.axles[axle]
        ts, sim = telemetry.timestamp, telemetry.simulated
        values.rpm_left.update(telemetry.wheel_rpm_left, ts, simulated=sim)
        values.rpm_right.update(telemetry.wheel_rpm_right, ts, simulated=sim)
        values.voltage.update(telemetry.battery_voltage, ts, simulated=sim)
        values.controller_temp.update(telemetry.controller_temp_c, ts, simulated=sim)
        values.motor_temp.update(telemetry.motor_temp_c, ts, simulated=sim)
        values.power.update(telemetry.electrical_power_w, ts, simulated=sim)

    def reset(self) -> None:
        self.__init__()

    # ------------------------------------------------------------------ abgeleitete Größen
    def wheel_measurements(self, axle: Axle, now: float, stale_s: float) -> tuple[Measurement, Measurement]:
        values = self.axles[axle]
        return values.rpm_left.measurement(now, stale_s), values.rpm_right.measurement(now, stale_s)

    def speed_kmh(self, now: float, stale_s: float, wheel_diameter_m: float) -> Measurement:
        """Fahrzeuggeschwindigkeit aus dem Mittel aller aktuellen Raddrehzahlen (vorzeichenbehaftet)."""
        rpm = self._mean_rpm(now, stale_s, absolute=False)
        if rpm.value is None:
            return Measurement(None, rpm.status, rpm.age_ms, "km/h")
        kmh = rpm.value * math.pi * wheel_diameter_m * 60.0 / 1000.0
        return Measurement(kmh, rpm.status, rpm.age_ms, "km/h")

    def motor_rpm(self, now: float, stale_s: float) -> Measurement:
        return self._mean_rpm(now, stale_s, absolute=True)

    def _mean_rpm(self, now: float, stale_s: float, *, absolute: bool) -> Measurement:
        all_values: list[Measurement] = []
        for axle in Axle:
            all_values.extend(self.wheel_measurements(axle, now, stale_s))
        usable = [m for m in all_values if m.usable and m.value is not None]
        if not usable:
            status = _worst_status(all_values)
            stale_values = [m for m in all_values if m.value is not None]
            if status == MeasurementStatus.STALE and stale_values:
                vals = [abs(m.value) if absolute else m.value for m in stale_values]  # type: ignore[arg-type]
                return Measurement(sum(vals) / len(vals), status, max(m.age_ms or 0 for m in stale_values), "U/min")
            return Measurement.unavailable("U/min")
        vals = [abs(m.value) if absolute else m.value for m in usable]  # type: ignore[arg-type]
        status = MeasurementStatus.SIMULATED if any(m.status == MeasurementStatus.SIMULATED for m in usable) else MeasurementStatus.VALID
        return Measurement(sum(vals) / len(vals), status, max(m.age_ms or 0 for m in usable), "U/min")

    def battery_voltage(self, now: float, stale_s: float) -> Measurement:
        return self._combine([self.axles[a].voltage.measurement(now, stale_s) for a in Axle], "V", "mean")

    def battery_percent(self, voltage: Measurement, battery: BatterySettings) -> Measurement:
        if voltage.value is None:
            return Measurement(None, voltage.status, voltage.age_ms, "%")
        return Measurement(estimate_percent(voltage.value, battery), voltage.status, voltage.age_ms, "%")

    def controller_temp(self, now: float, stale_s: float, axle: Axle | None = None) -> Measurement:
        axles = [axle] if axle else list(Axle)
        return self._combine([self.axles[a].controller_temp.measurement(now, stale_s) for a in axles], "°C", "max")

    def motor_temp(self, now: float, stale_s: float, axle: Axle | None = None) -> Measurement:
        axles = [axle] if axle else list(Axle)
        return self._combine([self.axles[a].motor_temp.measurement(now, stale_s) for a in axles], "°C", "max")

    def electrical_power(self, now: float, stale_s: float, axle: Axle | None = None) -> Measurement:
        axles = [axle] if axle else list(Axle)
        return self._combine([self.axles[a].power.measurement(now, stale_s) for a in axles], "W", "sum")

    @staticmethod
    def _combine(items: list[Measurement], unit: str, how: str) -> Measurement:
        usable = [m for m in items if m.usable and m.value is not None]
        source = usable
        if not usable:
            source = [m for m in items if m.value is not None]
            if not source:
                return Measurement.unavailable(unit)
        values = [m.value for m in source if m.value is not None]
        if how == "max":
            value = max(values)
        elif how == "sum":
            value = sum(values)
        else:
            value = sum(values) / len(values)
        status = _worst_status(source)
        if how == "sum" and len(usable) != len(items) and usable:
            # Eine Achse fehlt: Summe wäre unvollständig → als veraltet kennzeichnen.
            status = MeasurementStatus.STALE
        age = max(m.age_ms or 0 for m in source)
        return Measurement(value, status, age, unit)
