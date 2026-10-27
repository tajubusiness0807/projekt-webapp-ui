"""Sicherheitsgrenzen und deren Anwendung auf Fahrprofile, Antriebsmodi und Leistungsverteilung.

Grundsatz: Das Backend begrenzt **immer** zur Laufzeit. Selbst ein gültig gespeichertes Profil wird
auf die (vom Administrator gesetzten) absoluten Grenzen und – im Inbetriebnahme-Modus – auf
stark reduzierte Werte begrenzt.

Leistungsverteilung (Definition)
--------------------------------
Die Verteilung ist eine **relative Gewichtung** ``w_v + w_h = 100``. Umrechnung in Achsfaktoren::

    s_v = w_v / max(w_v, w_h)      s_h = w_h / max(w_v, w_h)

Die Achse mit der höheren Gewichtung erhält die volle (bereits begrenzte) Motoranforderung, die andere
den Anteil ``w_klein / w_groß``. Beispiel 60/40 → vorne 1,00, hinten 0,67. Das ist eine Anforderung an
die Controller, **keine** Aussage über die tatsächlich aufgenommene elektrische Leistung – diese hängt
von Drehzahl, Last, Akkuspannung und Controllerregelung ab und wird nur angezeigt, wenn gemessen.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from ..models.common import DriveMode, OperatingMode
from ..models.settings import DriveProfileSettings, HardwareSettings, PowerSplitSettings, SafetySettings

COMMISSIONING_MAX_THROTTLE = 0.15
COMMISSIONING_MAX_SPEED_KMH = 3.0


@dataclass(frozen=True)
class EffectiveProfile:
    max_throttle: float
    accel_ramp_per_s: float
    brake_strength: float
    steering_sensitivity: float
    deadzone: float
    max_speed_kmh: float
    front_limit: float
    rear_limit: float
    left_limit: float
    right_limit: float
    limited: dict[str, str] = field(default_factory=dict)

    def to_dict(self) -> dict[str, object]:
        return {
            "max_throttle_percent": round(self.max_throttle * 100, 1),
            "accel_ramp_percent_per_s": round(self.accel_ramp_per_s * 100, 1),
            "brake_strength_percent": round(self.brake_strength * 100, 1),
            "steering_sensitivity_percent": round(self.steering_sensitivity * 100, 1),
            "deadzone_percent": round(self.deadzone * 100, 1),
            "max_speed_kmh": round(self.max_speed_kmh, 1),
            "limited": self.limited,
        }


def effective_profile(
    profile: DriveProfileSettings, safety: SafetySettings, *, commissioning: bool = False
) -> EffectiveProfile:
    limited: dict[str, str] = {}

    max_throttle = profile.max_throttle_percent / 100
    if max_throttle > safety.absolute_max_throttle_percent / 100:
        max_throttle = safety.absolute_max_throttle_percent / 100
        limited["max_throttle_percent"] = "Sicherheitsgrenze"
    ramp = profile.accel_ramp_percent_per_s / 100
    if ramp > safety.absolute_max_accel_ramp_percent_per_s / 100:
        ramp = safety.absolute_max_accel_ramp_percent_per_s / 100
        limited["accel_ramp_percent_per_s"] = "Sicherheitsgrenze"
    max_speed = profile.max_speed_kmh
    if max_speed > safety.absolute_max_speed_kmh:
        max_speed = safety.absolute_max_speed_kmh
        limited["max_speed_kmh"] = "Sicherheitsgrenze"
    if commissioning:
        if max_throttle > COMMISSIONING_MAX_THROTTLE:
            max_throttle = COMMISSIONING_MAX_THROTTLE
            limited["max_throttle_percent"] = "Inbetriebnahme"
        if max_speed > COMMISSIONING_MAX_SPEED_KMH:
            max_speed = COMMISSIONING_MAX_SPEED_KMH
            limited["max_speed_kmh"] = "Inbetriebnahme"

    return EffectiveProfile(
        max_throttle=max_throttle,
        accel_ramp_per_s=ramp,
        brake_strength=profile.brake_strength_percent / 100,
        steering_sensitivity=profile.steering_sensitivity_percent / 100,
        deadzone=profile.deadzone_percent / 100,
        max_speed_kmh=max_speed,
        front_limit=profile.front_power_limit_percent / 100,
        rear_limit=profile.rear_power_limit_percent / 100,
        left_limit=profile.left_limit_percent / 100,
        right_limit=profile.right_limit_percent / 100,
        limited=limited,
    )


@dataclass(frozen=True)
class DriveModeAvailability:
    available: bool
    reason: str | None = None

    def to_dict(self) -> dict[str, object]:
        return {"available": self.available, "reason": self.reason}


def axle_distribution_available(mode: OperatingMode, hw: HardwareSettings) -> tuple[bool, str | None]:
    """Ob Achsen unterschiedlich angesteuert werden dürfen (FWD/RWD/Custom, Verteilung ≠ 50/50)."""
    if mode == OperatingMode.SIMULATION:
        return True, None
    if not hw.independent_axle_control:
        return False, "Unabhängige Ansteuerung beider Controller ist nicht bestätigt"
    if hw.firmware_control_mode != "torque":
        return False, (
            "Ungleiche Achsanforderungen erfordern den Drehmomentmodus (TRQ_MODE). "
            "Im Spannungs-/Drehzahlmodus würden sich die Achsen gegenseitig bremsen."
        )
    return True, None


def drive_mode_availability(mode: OperatingMode, hw: HardwareSettings) -> dict[DriveMode, DriveModeAvailability]:
    ok, reason = axle_distribution_available(mode, hw)
    return {
        DriveMode.AWD: DriveModeAvailability(True),
        DriveMode.FWD: DriveModeAvailability(ok, reason),
        DriveMode.RWD: DriveModeAvailability(ok, reason),
        DriveMode.CUSTOM: DriveModeAvailability(ok, reason),
    }


def axle_weights(drive_mode: DriveMode, split: PowerSplitSettings, distribution_available: bool) -> tuple[float, float]:
    """Angeforderte Gewichtung (vorne, hinten) in Prozent für den Antriebsmodus."""
    if not distribution_available:
        return 50.0, 50.0
    if drive_mode == DriveMode.FWD:
        return 100.0, 0.0
    if drive_mode == DriveMode.RWD:
        return 0.0, 100.0
    if drive_mode == DriveMode.CUSTOM:
        front = split.custom_front_percent
    else:
        front = split.awd_front_percent
    front = max(0.0, min(100.0, front))
    return front, 100.0 - front


def axle_scales(front_weight: float, rear_weight: float) -> tuple[float, float]:
    """Achsfaktoren aus der Gewichtung (siehe Moduldokumentation)."""
    largest = max(front_weight, rear_weight)
    if largest <= 0:
        return 0.0, 0.0
    return front_weight / largest, rear_weight / largest


def apply_deadzone(value: float, deadzone: float) -> float:
    """Totzone mit stetiger Skalierung auf 0…1 (bzw. −1…1)."""
    magnitude = abs(value)
    if magnitude <= deadzone:
        return 0.0
    scaled = (magnitude - deadzone) / (1.0 - deadzone) if deadzone < 1 else 0.0
    return min(1.0, scaled) * (1.0 if value >= 0 else -1.0)
