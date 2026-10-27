"""Validierte, versionierte Fahrzeugeinstellungen.

Alle Einstellungen werden ausschließlich über diese Modelle angenommen. Unbekannte Felder, ``NaN``,
``Infinity`` und Werte außerhalb der Grenzen werden abgelehnt. Zusätzlich begrenzt das Backend zur
Laufzeit jedes Fahrprofil auf die Sicherheitsgrenzen (``app.safety.limits``) – das Frontend kann
keine Sicherheitsgrenze setzen, die ungeprüft übernommen wird.
"""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator

from .common import Axle, DriveMode, DriveProfileName, OperatingMode

SCHEMA_VERSION = 1

# Abschnitte, die der Fahrer (Steuerungsbesitzer) ändern darf. Alle anderen nur mit Admin-Rechten.
DRIVER_SECTIONS = frozenset({"general", "profiles", "power_split", "tilt", "ui"})
ADMIN_SECTIONS = frozenset({"battery", "temperature", "safety", "hardware", "telemetry"})
# Einzelfelder in Admin-Abschnitten, die der Fahrer trotzdem schalten darf. Der Batterie-Schutz ist
# nur die sanfte Leistungsreduzierung – die kritische Unterspannungsabschaltung bleibt immer aktiv.
DRIVER_FIELDS = {"battery": frozenset({"protection_enabled"})}


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False, validate_assignment=True)


class DriveProfileSettings(StrictModel):
    max_throttle_percent: float = Field(ge=5, le=100, description="Maximale Gasstellung")
    accel_ramp_percent_per_s: float = Field(ge=5, le=400, description="Anstieg der Motoranforderung in %/s")
    brake_strength_percent: float = Field(ge=10, le=100, description="Verzögerungsanforderung bei voller Bremse")
    steering_sensitivity_percent: float = Field(ge=10, le=100, description="Lenkempfindlichkeit")
    deadzone_percent: float = Field(ge=0, le=25, description="Totzone für Gas und Lenkung")
    max_speed_kmh: float = Field(ge=1, le=60, description="Geschwindigkeitsbegrenzung")
    front_power_limit_percent: float = Field(default=100, ge=0, le=100)
    rear_power_limit_percent: float = Field(default=100, ge=0, le=100)
    left_limit_percent: float = Field(default=100, ge=50, le=100)
    right_limit_percent: float = Field(default=100, ge=50, le=100)


def _default_profiles() -> dict[str, DriveProfileSettings]:
    return {
        "eco": DriveProfileSettings(
            max_throttle_percent=50,
            accel_ramp_percent_per_s=35,
            brake_strength_percent=60,
            steering_sensitivity_percent=60,
            deadzone_percent=5,
            max_speed_kmh=8,
        ),
        "normal": DriveProfileSettings(
            max_throttle_percent=75,
            accel_ramp_percent_per_s=70,
            brake_strength_percent=80,
            steering_sensitivity_percent=70,
            deadzone_percent=4,
            max_speed_kmh=12,
        ),
        "sport": DriveProfileSettings(
            max_throttle_percent=100,
            accel_ramp_percent_per_s=130,
            brake_strength_percent=100,
            steering_sensitivity_percent=80,
            deadzone_percent=3,
            max_speed_kmh=18,
        ),
        "custom": DriveProfileSettings(
            max_throttle_percent=70,
            accel_ramp_percent_per_s=60,
            brake_strength_percent=80,
            steering_sensitivity_percent=70,
            deadzone_percent=5,
            max_speed_kmh=10,
        ),
    }


class ProfilesSettings(StrictModel):
    eco: DriveProfileSettings = Field(default_factory=lambda: _default_profiles()["eco"])
    normal: DriveProfileSettings = Field(default_factory=lambda: _default_profiles()["normal"])
    sport: DriveProfileSettings = Field(default_factory=lambda: _default_profiles()["sport"])
    custom: DriveProfileSettings = Field(default_factory=lambda: _default_profiles()["custom"])

    def get(self, name: DriveProfileName) -> DriveProfileSettings:
        return getattr(self, name.value)


class GeneralSettings(StrictModel):
    default_profile: DriveProfileName = DriveProfileName.ECO
    default_drive_mode: DriveMode = DriveMode.AWD


class PowerSplitSettings(StrictModel):
    """Angeforderte Gewichtung vorne/hinten in Prozent (hinten = 100 − vorne).

    ``awd_front_percent`` gilt im Allradmodus (beide Achsen treiben immer an, daher 20…80 %),
    ``custom_front_percent`` im Modus „Custom" (0…100 %).
    """

    awd_front_percent: float = Field(default=50, ge=20, le=80)
    custom_front_percent: float = Field(default=60, ge=0, le=100)


class TiltSettings(StrictModel):
    full_lock_angle_deg: float = Field(default=25, ge=8, le=60, description="Neigung für volle Lenkanforderung")
    max_steer_percent: float = Field(default=80, ge=10, le=100)
    deadzone_deg: float = Field(default=3, ge=0, le=15)
    smoothing: float = Field(default=0.6, ge=0, le=0.95)
    invert: bool = False
    pitch_function: Literal["off", "throttle"] = "off"
    pitch_full_angle_deg: float = Field(default=20, ge=5, le=45)
    pitch_deadzone_deg: float = Field(default=5, ge=0, le=20)


class UiSettings(StrictModel):
    speedometer_max_kmh: int = Field(default=30, ge=10, le=120)
    rpm_gauge_max: int = Field(default=1000, ge=200, le=5000)
    keyboard_throttle_percent: float = Field(default=50, ge=10, le=100)
    pedal_mode: Literal["proportional", "full"] = "proportional"
    haptic_feedback: bool = True
    show_steering_slider: bool = True


class BatterySettings(StrictModel):
    cells_series: int = Field(default=10, ge=6, le=16)
    cell_full_v: float = Field(default=4.15, ge=3.9, le=4.25)
    cell_warning_v: float = Field(default=3.50, ge=3.0, le=3.9)
    cell_critical_v: float = Field(default=3.35, ge=2.9, le=3.8)
    cell_empty_v: float = Field(default=3.30, ge=2.8, le=3.6)
    protection_enabled: bool = Field(default=True, description="Sanfte Leistungsreduzierung unter der Warnschwelle")

    @model_validator(mode="after")
    def _check_order(self) -> "BatterySettings":
        if not (self.cell_empty_v <= self.cell_critical_v < self.cell_warning_v < self.cell_full_v):
            raise ValueError(
                "Akkuspannungen müssen gelten: leer ≤ kritisch < Warnung < voll"
            )
        return self


class TemperatureSettings(StrictModel):
    controller_warning_c: float = Field(default=55, ge=30, le=90)
    controller_critical_c: float = Field(default=70, ge=35, le=100)
    motor_warning_c: float = Field(default=70, ge=30, le=120)
    motor_critical_c: float = Field(default=90, ge=35, le=140)

    @model_validator(mode="after")
    def _check_order(self) -> "TemperatureSettings":
        if self.controller_warning_c >= self.controller_critical_c:
            raise ValueError("Controller: Warnschwelle muss unter der kritischen Schwelle liegen")
        if self.motor_warning_c >= self.motor_critical_c:
            raise ValueError("Motor: Warnschwelle muss unter der kritischen Schwelle liegen")
        return self


class SafetySettings(StrictModel):
    command_timeout_ms: int = Field(default=300, ge=100, le=1000)
    connection_timeout_ms: int = Field(default=1000, ge=300, le=5000)
    controller_timeout_ms: int = Field(default=500, ge=100, le=3000)
    telemetry_stale_ms: int = Field(default=1000, ge=200, le=5000)
    max_command_age_ms: int = Field(default=400, ge=100, le=2000)
    max_command_rate_hz: int = Field(default=40, ge=5, le=60)
    absolute_max_speed_kmh: float = Field(default=20, ge=2, le=40)
    absolute_max_throttle_percent: float = Field(default=100, ge=10, le=100)
    absolute_max_accel_ramp_percent_per_s: float = Field(default=150, ge=10, le=400)
    reverse_max_speed_kmh: float = Field(default=4, ge=1, le=10)
    reverse_max_throttle_percent: float = Field(default=35, ge=10, le=60)
    standstill_speed_kmh: float = Field(default=0.8, ge=0.2, le=3)
    loop_stall_ms: int = Field(default=500, ge=200, le=3000)
    max_sessions: int = Field(default=4, ge=1, le=8)

    @model_validator(mode="after")
    def _check_timeouts(self) -> "SafetySettings":
        if self.command_timeout_ms >= self.connection_timeout_ms:
            raise ValueError("Befehls-Timeout muss kleiner als der Verbindungs-Timeout sein")
        return self


class ControllerSettings(StrictModel):
    id: Literal["A", "B"]
    label: str = Field(max_length=40)
    axle: Axle
    port: str = Field(default="", max_length=128, description="Serielle Schnittstelle, z. B. /dev/ttyUSB0")
    baudrate: Literal[9600, 19200, 38400, 57600, 115200, 230400] = 115200
    feedback_with_odometry: bool = False
    speed_coefficient: float = Field(default=1.0, ge=0.1, le=2.0)
    steer_coefficient: float = Field(default=1.0, ge=0.0, le=2.0)
    max_command: int = Field(default=300, ge=50, le=1000, description="Betragsgrenze des Rohbefehls (Firmware ±1000)")
    invert_left_command: bool = False
    invert_right_command: bool = False
    invert_left_feedback: bool = False
    invert_right_feedback: bool = False
    swap_sides: bool = False


def _default_controllers() -> list[ControllerSettings]:
    return [
        ControllerSettings(id="A", label="Controller A", axle=Axle.FRONT),
        ControllerSettings(id="B", label="Controller B", axle=Axle.REAR),
    ]


class HardwareSettings(StrictModel):
    mode: OperatingMode = OperatingMode.SIMULATION
    controller_model: str = Field(default="", max_length=80)
    firmware: Literal["unknown", "hoverboard-firmware-hack-foc"] = "unknown"
    firmware_version: str = Field(default="", max_length=80)
    firmware_variant_usart: bool = False
    firmware_control_mode: Literal["unknown", "voltage", "speed", "torque"] = "unknown"
    protocol_verified: bool = False
    signal_levels_verified: bool = False
    wiring_verified: bool = False
    independent_axle_control: bool = False
    wheel_diameter_m: float = Field(default=0.165, ge=0.08, le=0.6)
    wheel_diameter_verified: bool = False
    temperature_calibrated: bool = False
    wheels_lifted_test_passed: bool = False
    brake_method: Literal["none", "voltage_mode_zero", "counter_torque"] = "none"
    brake_verified: bool = False
    controllers: list[ControllerSettings] = Field(default_factory=_default_controllers)

    @model_validator(mode="after")
    def _check_controllers(self) -> "HardwareSettings":
        if len(self.controllers) != 2:
            raise ValueError("Es müssen genau zwei Controller konfiguriert sein")
        ids = {c.id for c in self.controllers}
        if ids != {"A", "B"}:
            raise ValueError("Controller-IDs müssen A und B sein")
        axles = {c.axle for c in self.controllers}
        if axles != {Axle.FRONT, Axle.REAR}:
            raise ValueError("Ein Controller muss der Vorderachse, einer der Hinterachse zugeordnet sein")
        ports = [c.port for c in self.controllers if c.port]
        if len(ports) != len(set(ports)):
            raise ValueError("Beide Controller dürfen nicht dieselbe Schnittstelle verwenden")
        return self

    def controller_for(self, axle: Axle) -> ControllerSettings:
        for controller in self.controllers:
            if controller.axle == axle:
                return controller
        raise KeyError(axle)


class TelemetrySettings(StrictModel):
    broadcast_hz: int = Field(default=10, ge=2, le=20)
    control_loop_hz: int = Field(default=25, ge=10, le=50)


class VehicleSettings(StrictModel):
    schema_version: Literal[1] = SCHEMA_VERSION
    general: GeneralSettings = Field(default_factory=GeneralSettings)
    profiles: ProfilesSettings = Field(default_factory=ProfilesSettings)
    power_split: PowerSplitSettings = Field(default_factory=PowerSplitSettings)
    tilt: TiltSettings = Field(default_factory=TiltSettings)
    ui: UiSettings = Field(default_factory=UiSettings)
    battery: BatterySettings = Field(default_factory=BatterySettings)
    temperature: TemperatureSettings = Field(default_factory=TemperatureSettings)
    safety: SafetySettings = Field(default_factory=SafetySettings)
    hardware: HardwareSettings = Field(default_factory=HardwareSettings)
    telemetry: TelemetrySettings = Field(default_factory=TelemetrySettings)


class SettingsPatchError(ValueError):
    """Ein Änderungswunsch ist unzulässig (Rechte oder Validierung)."""

    def __init__(self, message: str, details: list[dict[str, Any]] | None = None) -> None:
        super().__init__(message)
        self.details = details or []


def deep_merge(base: dict[str, Any], patch: dict[str, Any]) -> dict[str, Any]:
    result = dict(base)
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def apply_settings_patch(
    current: VehicleSettings, patch: dict[str, Any], *, allow_admin: bool
) -> VehicleSettings:
    """Wendet eine Teiländerung an und validiert das Gesamtergebnis.

    Raises:
        SettingsPatchError: bei fehlenden Rechten, unbekannten Abschnitten oder Validierungsfehlern.
    """
    if not isinstance(patch, dict) or not patch:
        raise SettingsPatchError("Leere oder ungültige Änderung")
    for section in patch:
        if section == "schema_version":
            raise SettingsPatchError("Die Schema-Version kann nicht geändert werden")
        if section in DRIVER_SECTIONS:
            continue
        if section in ADMIN_SECTIONS:
            fields = patch[section]
            driver_ok = isinstance(fields, dict) and fields and set(fields) <= DRIVER_FIELDS.get(section, frozenset())
            if not allow_admin and not driver_ok:
                raise SettingsPatchError(f"Für den Abschnitt „{section}“ sind Administratorrechte nötig")
            continue
        raise SettingsPatchError(f"Unbekannter Abschnitt „{section}“")
    merged = deep_merge(current.model_dump(mode="json"), patch)
    try:
        return VehicleSettings.model_validate(merged)
    except ValidationError as exc:
        details = [
            {"loc": ".".join(str(p) for p in err["loc"]), "msg": err["msg"]} for err in exc.errors()
        ]
        raise SettingsPatchError("Einstellungen ungültig", details) from exc


def default_settings() -> VehicleSettings:
    return VehicleSettings()
