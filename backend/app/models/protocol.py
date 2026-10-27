"""WebSocket-Nachrichten (Client → Server), streng validiert.

Jede Steuernachricht trägt ``type``, ``seq`` (fortlaufend je Verbindung) und ``ts`` (Client-Zeit in ms).
Unbekannte Felder, ``NaN``/``Infinity`` und Werte außerhalb der Bereiche führen zur Ablehnung.
Server → Client-Nachrichten sind in ``docs/communication-protocol.md`` beschrieben.
"""

from __future__ import annotations

from typing import Annotated, Any, Literal, Union

from pydantic import BaseModel, ConfigDict, Field, TypeAdapter

from .common import Direction, DriveMode, DriveProfileName

MAX_MESSAGE_BYTES = 8192


class _Msg(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False, frozen=True)


class _Ctl(_Msg):
    seq: int = Field(ge=1, le=2**53)
    ts: int = Field(ge=0, le=2**53)


class HelloMessage(_Msg):
    type: Literal["hello"]
    protocol: int = Field(ge=1, le=100)
    token: str = Field(min_length=10, max_length=1024)
    client_id: str = Field(min_length=4, max_length=64, pattern=r"^[A-Za-z0-9_-]+$")
    device: str = Field(default="unbekannt", max_length=32)
    ts: int = Field(ge=0, le=2**53)


class PingMessage(_Msg):
    type: Literal["ping"]
    ts: int = Field(ge=0, le=2**53)
    rtt_ms: float | None = Field(default=None, ge=0, le=60000)


class DriveMessage(_Ctl):
    """Fahranforderung (20 Hz, auch im Leerlauf als Lebenszeichen)."""

    type: Literal["drive"]
    throttle: float = Field(ge=0.0, le=1.0)
    brake: float = Field(ge=0.0, le=1.0)
    steer: float = Field(ge=-1.0, le=1.0)
    profile: DriveProfileName
    source: Literal["pedals", "joystick", "tilt", "keyboard", "none"] = "pedals"


class SetProfileMessage(_Ctl):
    type: Literal["set_profile"]
    profile: DriveProfileName


class SetDriveModeMessage(_Ctl):
    type: Literal["set_drive_mode"]
    mode: DriveMode


class SetPowerSplitMessage(_Ctl):
    type: Literal["set_power_split"]
    target: Literal["awd", "custom"]
    front_percent: float = Field(ge=0, le=100)


class SetDirectionMessage(_Ctl):
    type: Literal["set_direction"]
    direction: Direction


class UpdateSettingsMessage(_Ctl):
    type: Literal["update_settings"]
    patch: dict[str, Any]
    expected_version: int | None = Field(default=None, ge=0)


class SimpleCommand(_Ctl):
    type: Literal[
        "arm",
        "disarm",
        "estop_reset",
        "ack_faults",
        "claim_control",
        "release_control",
        "takeover_control",
        "reset_trip",
        "reset_profiles",
    ]


class EmergencyStopMessage(_Ctl):
    type: Literal["estop"]
    reason: str = Field(default="", max_length=120)


class SimInjectMessage(_Ctl):
    type: Literal["sim_inject"]
    fault: str = Field(max_length=40)
    active: bool


ClientMessage = Annotated[
    Union[
        HelloMessage,
        PingMessage,
        DriveMessage,
        SetProfileMessage,
        SetDriveModeMessage,
        SetPowerSplitMessage,
        SetDirectionMessage,
        UpdateSettingsMessage,
        SimpleCommand,
        EmergencyStopMessage,
        SimInjectMessage,
    ],
    Field(discriminator="type"),
]

CLIENT_MESSAGE_ADAPTER: TypeAdapter[Any] = TypeAdapter(ClientMessage)

# Nachrichten, die nur der Steuerungsbesitzer senden darf (Not-Aus darf jede Sitzung).
OWNER_ONLY = frozenset(
    {
        "drive",
        "set_profile",
        "set_drive_mode",
        "set_power_split",
        "set_direction",
        "update_settings",
        "arm",
        "disarm",
        "estop_reset",
        "ack_faults",
        "reset_trip",
        "reset_profiles",
        "sim_inject",
    }
)
