"""Fahrlogik: aus der geprüften Fahreranforderung werden begrenzte Radanforderungen.

Reihenfolge je Regelzyklus:

1. Totzone für Gas und Lenkung.
2. Bremse hat Vorrang: bei Bremsanforderung ist die Gasanforderung 0.
3. Profilgrenze (max. Gasstellung), Rückwärtsgrenze, Akku- und Temperaturreduzierung.
4. Geschwindigkeitsbegrenzung anhand der **gemessenen** Geschwindigkeit. Ohne gültige Messung
   ist Gas gesperrt (die Grenze wäre sonst nicht überwachbar).
5. Lenkmischung (Differenzial-/Skid-Lenkung): kurveninnere Seite = Basis · (1 − |Lenkung|).
   Ohne Fahrt keine Lenkbewegung (kein Drehen auf der Stelle).
6. Achsfaktoren aus der Leistungsgewichtung und Achs-/Seitenbegrenzungen des Profils.
7. Rampe je Rad: Anstieg höchstens mit der Beschleunigungsrampe, Absenkung sofort.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from ..controllers.base import WheelCommand
from ..models.common import Axle, Direction
from ..safety.limits import EffectiveProfile, apply_deadzone, axle_scales
from ..telemetry.measurement import Measurement


@dataclass(frozen=True)
class DriverInput:
    throttle: float = 0.0
    brake: float = 0.0
    steer: float = 0.0

    @staticmethod
    def neutral() -> "DriverInput":
        return DriverInput()

    @property
    def is_neutral(self) -> bool:
        return self.throttle <= 1e-6


@dataclass(frozen=True)
class DriveContext:
    armed: bool
    direction: Direction
    profile: EffectiveProfile
    weights: tuple[float, float]
    speed: Measurement
    reverse_max_speed_kmh: float
    reverse_max_throttle: float
    battery_factor: float = 1.0
    temperature_factor: float = 1.0


@dataclass
class DriveOutput:
    wheels: dict[Axle, WheelCommand] = field(
        default_factory=lambda: {Axle.FRONT: WheelCommand.zero(), Axle.REAR: WheelCommand.zero()}
    )
    brake_level: float = 0.0
    target_throttle: float = 0.0
    effective_throttle: float = 0.0
    steer: float = 0.0
    speed_limit_kmh: float = 0.0
    speed_factor: float = 1.0
    weights: tuple[float, float] = (50.0, 50.0)
    scales: tuple[float, float] = (1.0, 1.0)
    limited_by: list[str] = field(default_factory=list)

    @property
    def drive_level(self) -> float:
        return max((max(abs(w.left), abs(w.right)) for w in self.wheels.values()), default=0.0)

    def to_dict(self) -> dict[str, object]:
        def wheel(axle: Axle) -> dict[str, float]:
            w = self.wheels[axle]
            return {"left": round(w.left, 3), "right": round(w.right, 3)}

        return {
            "target_throttle": round(self.target_throttle, 3),
            "effective_throttle": round(self.effective_throttle, 3),
            "drive_level": round(self.drive_level, 3),
            "brake_level": round(self.brake_level, 3),
            "steer": round(self.steer, 3),
            "speed_limit_kmh": round(self.speed_limit_kmh, 1),
            "speed_factor": round(self.speed_factor, 3),
            "front": wheel(Axle.FRONT),
            "rear": wheel(Axle.REAR),
            "limited_by": self.limited_by,
        }


class DriveComputer:
    def __init__(self) -> None:
        self._wheels: dict[Axle, WheelCommand] = {Axle.FRONT: WheelCommand.zero(), Axle.REAR: WheelCommand.zero()}

    def reset(self) -> None:
        self._wheels = {Axle.FRONT: WheelCommand.zero(), Axle.REAR: WheelCommand.zero()}

    def compute(self, inp: DriverInput, ctx: DriveContext, dt: float) -> DriveOutput:
        out = DriveOutput(weights=ctx.weights)
        profile = ctx.profile
        out.scales = axle_scales(*ctx.weights)
        if not ctx.armed:
            self.reset()
            out.wheels = dict(self._wheels)
            return out

        throttle = apply_deadzone(max(0.0, min(1.0, inp.throttle)), profile.deadzone)
        steer = apply_deadzone(max(-1.0, min(1.0, inp.steer)), profile.deadzone)
        brake = max(0.0, min(1.0, inp.brake))
        reverse = ctx.direction == Direction.REVERSE

        if brake > 0:
            throttle = 0.0
        out.target_throttle = throttle

        max_throttle = profile.max_throttle
        speed_limit = profile.max_speed_kmh
        if reverse:
            if ctx.reverse_max_throttle < max_throttle:
                max_throttle = ctx.reverse_max_throttle
            speed_limit = min(speed_limit, ctx.reverse_max_speed_kmh)
            if throttle > 0:
                out.limited_by.append("rueckwaerts")
        effective = throttle * max_throttle
        if throttle > 0 and max_throttle < 1.0:
            out.limited_by.append("profil")

        if ctx.battery_factor < 1.0 and effective > 0:
            effective *= ctx.battery_factor
            out.limited_by.append("akku")
        if ctx.temperature_factor < 1.0 and effective > 0:
            effective *= ctx.temperature_factor
            out.limited_by.append("temperatur")

        out.speed_limit_kmh = speed_limit
        if ctx.speed.usable and ctx.speed.value is not None:
            speed = abs(ctx.speed.value)
            band = max(1.0, 0.15 * speed_limit)
            factor = max(0.0, min(1.0, (speed_limit - speed) / band))
            out.speed_factor = factor
            if factor < 1.0 and effective > 0:
                out.limited_by.append("geschwindigkeit")
            effective *= factor
        elif effective > 0:
            effective = 0.0
            out.speed_factor = 0.0
            out.limited_by.append("keine_geschwindigkeit")

        out.effective_throttle = effective
        base = -effective if reverse else effective

        differential = max(-1.0, min(1.0, steer * profile.steering_sensitivity))
        out.steer = differential
        inner = base * (1.0 - abs(differential))
        if differential >= 0:  # Lenkung rechts: rechte Seite ist kurveninnen
            left, right = base, inner
        else:
            left, right = inner, base

        scale_front, scale_rear = out.scales
        targets = {
            Axle.FRONT: WheelCommand(
                left * scale_front * profile.front_limit * profile.left_limit,
                right * scale_front * profile.front_limit * profile.right_limit,
            ).clamped(),
            Axle.REAR: WheelCommand(
                left * scale_rear * profile.rear_limit * profile.left_limit,
                right * scale_rear * profile.rear_limit * profile.right_limit,
            ).clamped(),
        }

        if brake > 0:
            self.reset()
            out.brake_level = brake * profile.brake_strength
        else:
            step = profile.accel_ramp_per_s * max(0.0, dt)
            for axle, target in targets.items():
                current = self._wheels[axle]
                self._wheels[axle] = WheelCommand(
                    _ramp(current.left, target.left, step), _ramp(current.right, target.right, step)
                )
        out.wheels = dict(self._wheels)
        return out


def _ramp(current: float, target: float, step: float) -> float:
    """Anstieg begrenzt, Absenkung des Betrags sofort; Vorzeichenwechsel nur über 0."""
    if target == 0.0:
        return 0.0
    same_sign = (current >= 0) == (target >= 0) or abs(current) < 1e-9
    if not same_sign:
        current = 0.0
    if abs(target) <= abs(current):
        return target
    sign = 1.0 if target > 0 else -1.0
    return sign * min(abs(target), abs(current) + step)
