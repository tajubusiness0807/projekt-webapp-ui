"""Vereinfachtes Fahrzeugmodell für den Simulationsmodus.

Das Modell ist bewusst klein (Raspberry Pi 3B), aber physikalisch nachvollziehbar:

* Zwei Fahrzeugseiten (links/rechts) als gekoppelte Massen → Differenzial-(Skid-)Lenkung.
* Pro Rad ein Antriebskraftmodell ähnlich dem FOC-Drehmomentmodus: Kraft ∝ Befehl, abnehmend mit
  der Drehzahl (Gegen-EMK); Befehl 0 = Freilauf.
* Rollwiderstand, Luftwiderstand, Bremskraft mit Haltefunktion im Stillstand.
* Akku: Leerlaufspannung aus Ladezustand, Innenwiderstand, Ladungsentnahme.
* Temperaturen: Erwärmung durch Verlustleistung, Abkühlung zur Umgebung.

Die Werte werden im Frontend als „SIMULIERT" gekennzeichnet und nie als Messung ausgegeben.
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass, field

from ..controllers.base import WheelCommand
from ..models.common import Axle

G = 9.81
AIR_DENSITY = 1.2

# Ladezustand → relative Zellspannung (Umkehrung der Kurve in telemetry.battery)
_SOC_TO_REL: tuple[tuple[float, float], ...] = (
    (0.00, 0.00),
    (0.05, 0.12),
    (0.15, 0.30),
    (0.30, 0.45),
    (0.45, 0.55),
    (0.60, 0.65),
    (0.75, 0.78),
    (0.90, 0.90),
    (1.00, 1.00),
)


@dataclass
class VehicleParameters:
    mass_kg: float = 110.0
    wheel_diameter_m: float = 0.165
    track_width_m: float = 0.62
    max_wheel_force_n: float = 95.0
    no_load_rpm_per_volt: float = 23.5  # Leerlaufdrehzahl je Volt Akkuspannung
    rolling_coeff: float = 0.025
    drag_area_m2: float = 0.55
    scrub_coupling_ns_per_m: float = 18.0
    brake_force_per_wheel_n: float = 140.0
    efficiency: float = 0.82
    copper_loss_per_n2: float = 0.0025
    idle_power_w: float = 7.0
    battery_capacity_ah: float = 4.4
    battery_internal_ohm: float = 0.18
    cells_series: int = 10
    cell_full_v: float = 4.15
    cell_empty_v: float = 3.30
    ambient_c: float = 22.0
    controller_heat_capacity: float = 900.0
    motor_heat_capacity: float = 1600.0
    controller_cooling: float = 1.6
    motor_cooling: float = 2.4


@dataclass
class _AxleState:
    command: WheelCommand = field(default_factory=WheelCommand.zero)
    brake: float = 0.0
    force_left: float = 0.0
    force_right: float = 0.0
    electrical_power_w: float = 0.0
    controller_temp_c: float = 25.0
    motor_temp_c: float = 25.0


class VehiclePhysics:
    def __init__(self, params: VehicleParameters | None = None, *, initial_soc: float = 0.78, seed: int | None = 7) -> None:
        self.p = params or VehicleParameters()
        self._rng = random.Random(seed)
        self.v_left = 0.0  # m/s
        self.v_right = 0.0
        self.soc = initial_soc
        self.pack_voltage = self._open_circuit_voltage()
        self.current_a = 0.0
        self.distance_m = 0.0
        self.heading_rad = 0.0
        self.axles: dict[Axle, _AxleState] = {
            Axle.FRONT: _AxleState(controller_temp_c=self.p.ambient_c + 3, motor_temp_c=self.p.ambient_c + 1),
            Axle.REAR: _AxleState(controller_temp_c=self.p.ambient_c + 4, motor_temp_c=self.p.ambient_c + 1),
        }
        # Überschreibungen durch Fehlerinjektion
        self.forced_voltage: float | None = None
        self.forced_controller_temp: float | None = None

    # ------------------------------------------------------------------ Eingaben
    def set_command(self, axle: Axle, command: WheelCommand) -> None:
        self.axles[axle].command = command.clamped()

    def set_brake(self, axle: Axle, level: float) -> None:
        self.axles[axle].brake = max(0.0, min(1.0, level))

    def stop_all(self) -> None:
        for state in self.axles.values():
            state.command = WheelCommand.zero()

    # ------------------------------------------------------------------ Ausgaben
    @property
    def speed_ms(self) -> float:
        return (self.v_left + self.v_right) / 2.0

    @property
    def speed_kmh(self) -> float:
        return self.speed_ms * 3.6

    @property
    def yaw_rate(self) -> float:
        return (self.v_left - self.v_right) / self.p.track_width_m

    def wheel_rpm(self, side: str) -> float:
        v = self.v_left if side == "left" else self.v_right
        return v / (math.pi * self.p.wheel_diameter_m) * 60.0

    def measured_voltage(self) -> float:
        if self.forced_voltage is not None:
            return self.forced_voltage
        return self.pack_voltage + self._rng.uniform(-0.03, 0.03)

    def controller_temp(self, axle: Axle) -> float:
        if self.forced_controller_temp is not None:
            return self.forced_controller_temp
        return self.axles[axle].controller_temp_c

    # ------------------------------------------------------------------ Simulation
    def step(self, dt: float) -> None:
        if dt <= 0:
            return
        dt = min(dt, 0.2)
        p = self.p
        rpm_max = max(1.0, p.no_load_rpm_per_volt * self.pack_voltage)
        total_power = p.idle_power_w

        force_left = force_right = 0.0
        brake_total = 0.0
        for state in self.axles.values():
            fl = self._wheel_force(state.command.left, self.wheel_rpm("left"), rpm_max)
            fr = self._wheel_force(state.command.right, self.wheel_rpm("right"), rpm_max)
            state.force_left, state.force_right = fl, fr
            force_left += fl
            force_right += fr
            brake_total += state.brake * p.brake_force_per_wheel_n * 2
            power = self._electrical_power(fl, self.v_left) + self._electrical_power(fr, self.v_right)
            state.electrical_power_w = power
            total_power += max(power, -50.0)

        half_mass = p.mass_kg / 2
        v = self.speed_ms
        resist = 0.0
        if abs(v) > 0.02:
            resist = math.copysign(p.rolling_coeff * p.mass_kg * G + 0.5 * AIR_DENSITY * p.drag_area_m2 * v * v, v)
        coupling = p.scrub_coupling_ns_per_m * (self.v_left - self.v_right)

        def integrate(v_side: float, drive: float) -> float:
            brake = 0.0
            if brake_total > 0 and abs(v_side) > 0.0:
                brake = math.copysign(brake_total / 2, v_side)
            acc = (drive - resist / 2 - brake) / half_mass
            new_v = v_side + acc * dt
            if brake_total > 0 and v_side != 0 and math.copysign(1, new_v) != math.copysign(1, v_side):
                new_v = 0.0  # Bremse kehrt die Richtung nicht um
            return new_v

        new_left = integrate(self.v_left, force_left - coupling)
        new_right = integrate(self.v_right, force_right + coupling)

        # Haftreibung: aus dem Stand nur anfahren, wenn die Antriebskraft den Rollwiderstand übersteigt.
        static_limit = p.rolling_coeff * p.mass_kg * G / 2
        if abs(self.v_left) < 0.02 and abs(force_left) < static_limit and brake_total == 0:
            new_left = 0.0 if abs(self.v_right) < 0.02 else new_left
        if abs(self.v_right) < 0.02 and abs(force_right) < static_limit and brake_total == 0:
            new_right = 0.0 if abs(self.v_left) < 0.02 else new_right
        if brake_total > 0 and abs(new_left) < 0.03 and abs(new_right) < 0.03:
            new_left = new_right = 0.0

        self.v_left, self.v_right = new_left, new_right
        self.distance_m += abs(self.speed_ms) * dt
        self.heading_rad = (self.heading_rad + self.yaw_rate * dt) % (2 * math.pi)

        # Akku
        self.current_a = total_power / max(self.pack_voltage, 1.0)
        self.soc = max(0.0, min(1.0, self.soc - self.current_a * dt / 3600.0 / p.battery_capacity_ah))
        self.pack_voltage = max(0.0, self._open_circuit_voltage() - self.current_a * p.battery_internal_ohm)

        # Temperaturen
        for state in self.axles.values():
            loss = abs(state.electrical_power_w) * 0.06 + p.copper_loss_per_n2 * (state.force_left**2 + state.force_right**2)
            state.controller_temp_c += (
                (loss * 0.5 - (state.controller_temp_c - p.ambient_c) * p.controller_cooling) / p.controller_heat_capacity * dt
            )
            state.motor_temp_c += (
                (loss * 0.8 - (state.motor_temp_c - p.ambient_c) * p.motor_cooling) / p.motor_heat_capacity * dt
            )

    def _wheel_force(self, command: float, rpm: float, rpm_max: float) -> float:
        if abs(command) < 1e-4:
            return 0.0
        direction = math.copysign(1.0, command)
        ratio = (rpm * direction) / rpm_max
        available = max(0.0, min(1.0, 1.0 - ratio))
        return command * self.p.max_wheel_force_n * available

    def _electrical_power(self, force: float, v_side: float) -> float:
        mech = force * v_side / 2  # zwei Räder je Seite teilen sich die Seitengeschwindigkeit
        copper = self.p.copper_loss_per_n2 * force * force
        if mech >= 0:
            return mech / self.p.efficiency + copper
        return mech * self.p.efficiency + copper

    def _open_circuit_voltage(self) -> float:
        rel = 0.0
        for (s0, r0), (s1, r1) in zip(_SOC_TO_REL, _SOC_TO_REL[1:]):
            if s0 <= self.soc <= s1:
                rel = r0 + (self.soc - s0) / (s1 - s0) * (r1 - r0)
                break
        cell = self.p.cell_empty_v + rel * (self.p.cell_full_v - self.p.cell_empty_v)
        return cell * self.p.cells_series
