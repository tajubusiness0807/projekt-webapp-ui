"""Verbindungs-Sitzungen und eindeutiger Steuerungsbesitz.

* Jede WebSocket-Verbindung ist eine Sitzung (Beobachter).
* Genau eine Sitzung kann Steuerungsbesitzer sein; nur sie darf Fahr- und Einstellbefehle senden.
* Eine andere Sitzung kann die Steuerung nur übernehmen, wenn das Fahrzeug steht oder gesperrt ist.
  Bei der Übernahme werden die Motoren gesperrt – es gibt nie zwei gleichzeitig steuernde Geräte.
* Not-Aus darf jede authentifizierte Sitzung auslösen.
"""

from __future__ import annotations

import asyncio
import json
import secrets
from dataclasses import dataclass, field
from typing import Any

from ..models.common import Role
from ..safety.command_gate import CommandGate
from ..utils.clock import Clock
from .drive_logic import DriverInput


class TooManySessions(Exception):
    pass


@dataclass
class Session:
    id: str
    client_id: str
    role: Role
    device: str
    remote: str | None
    connected_at: float
    gate: CommandGate
    last_message_at: float
    input: DriverInput = field(default_factory=DriverInput.neutral)
    input_source: str = "none"
    input_received_at: float | None = None
    rtt_ms: float | None = None
    invalid_messages: int = 0
    invalid_window_start: float = 0.0
    closed: bool = False
    outbox: "asyncio.Queue[str]" = field(default_factory=lambda: asyncio.Queue(maxsize=64))
    latest_telemetry: str | None = None
    wakeup: asyncio.Event = field(default_factory=asyncio.Event)
    dropped_messages: int = 0

    def send(self, message: dict[str, Any]) -> None:
        """Wichtige Nachricht (Bestätigung, Ereignis, Einstellungen) in die Warteschlange legen."""
        if self.closed:
            return
        try:
            self.outbox.put_nowait(json.dumps(message, separators=(",", ":"), ensure_ascii=False))
        except asyncio.QueueFull:
            self.dropped_messages += 1
        self.wakeup.set()

    def push_telemetry(self, payload: str) -> None:
        """Telemetrie: nur der neueste Stand zählt (keine Pufferung bei langsamen Clients)."""
        if self.closed:
            return
        if self.latest_telemetry is not None:
            self.dropped_messages += 1
        self.latest_telemetry = payload
        self.wakeup.set()

    def reset_input(self) -> None:
        self.input = DriverInput.neutral()
        self.input_source = "none"

    def public_info(self) -> dict[str, Any]:
        return {"id": self.id, "device": self.device, "role": self.role.value}


class SessionManager:
    def __init__(self, clock: Clock, max_sessions: int) -> None:
        self._clock = clock
        self.max_sessions = max_sessions
        self.sessions: dict[str, Session] = {}
        self.owner_id: str | None = None
        self._last_owner_client: str | None = None

    def open(self, client_id: str, role: Role, device: str, remote: str | None) -> Session:
        if len(self.sessions) >= self.max_sessions:
            raise TooManySessions(f"Maximal {self.max_sessions} gleichzeitige Verbindungen")
        now = self._clock.monotonic()
        session = Session(
            id=secrets.token_hex(4),
            client_id=client_id,
            role=role,
            device=device or "unbekannt",
            remote=remote,
            connected_at=now,
            gate=CommandGate(self._clock),
            last_message_at=now,
        )
        self.sessions[session.id] = session
        return session

    def close(self, session_id: str) -> bool:
        """Entfernt die Sitzung. Gibt ``True`` zurück, wenn sie Steuerungsbesitzer war."""
        session = self.sessions.pop(session_id, None)
        if session is None:
            return False
        session.closed = True
        session.wakeup.set()
        if self.owner_id == session_id:
            self.owner_id = None
            return True
        return False

    def owner(self) -> Session | None:
        return self.sessions.get(self.owner_id) if self.owner_id else None

    def is_owner(self, session: Session) -> bool:
        return self.owner_id == session.id

    def claim(self, session: Session) -> tuple[bool, str | None]:
        if self.owner_id == session.id:
            return True, None
        if self.owner_id is not None:
            return False, "Die Steuerung ist bereits einem anderen Gerät zugeordnet"
        self._assign(session)
        return True, None

    def can_auto_reclaim(self, session: Session) -> bool:
        """Ein Gerät, das zuletzt gesteuert hat, bekommt nach Wiederverbindung den Besitz zurück,
        sofern niemand sonst übernommen hat. Die Motoren bleiben dabei gesperrt."""
        return self.owner_id is None and self._last_owner_client == session.client_id

    def release(self, session: Session) -> bool:
        if self.owner_id != session.id:
            return False
        self.owner_id = None
        self._last_owner_client = None
        return True

    def takeover(self, session: Session) -> Session | None:
        previous = self.owner()
        self._assign(session)
        return previous if previous is not None and previous.id != session.id else None

    def _assign(self, session: Session) -> None:
        self.owner_id = session.id
        self._last_owner_client = session.client_id
        session.reset_input()
        session.input_received_at = None

    def broadcast(self, message: dict[str, Any]) -> None:
        for session in list(self.sessions.values()):
            session.send(message)
