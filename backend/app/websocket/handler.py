"""WebSocket-Endpunkt ``/ws``.

Ablauf: Origin-Prüfung → Annahme → ``hello`` mit Token innerhalb von 5 s → ``welcome`` →
Nachrichten. Eigene Close-Codes:

* 4001 Anmeldung ungültig · 4002 kein Hello · 4003 zu viele Verbindungen
* 4004 Herkunft (Origin) abgelehnt · 4008 Protokollverletzung
"""

from __future__ import annotations

import asyncio
import json
import logging
from urllib.parse import urlsplit

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from pydantic import ValidationError

from .. import PROTOCOL_VERSION
from ..models.protocol import CLIENT_MESSAGE_ADAPTER, MAX_MESSAGE_BYTES, HelloMessage
from ..services.session_manager import Session, TooManySessions
from ..services.vehicle_service import ProtocolViolation, VehicleService

log = logging.getLogger(__name__)
router = APIRouter()

HELLO_TIMEOUT_S = 5.0


def origin_allowed(origin: str | None, host: str | None, allowed: tuple[str, ...]) -> bool:
    """Schutz vor Cross-Site-WebSocket-Hijacking: Browser senden immer einen Origin-Header."""
    if not origin:
        return True  # Kein Browser (z. B. Tests, Kommandozeile) – Token ist trotzdem nötig
    if origin.rstrip("/") in allowed:
        return True
    parsed = urlsplit(origin)
    return bool(host) and parsed.netloc == host


@router.websocket("/ws")
async def websocket_endpoint(ws: WebSocket) -> None:
    service: VehicleService = ws.app.state.service
    if not origin_allowed(ws.headers.get("origin"), ws.headers.get("host"), service.env.allowed_origins):
        await ws.close(code=4004)
        service.events.warning("WS_ORIGIN", "zugang", "WebSocket-Verbindung wegen fremder Herkunft abgelehnt",
                               {"origin": ws.headers.get("origin")}, throttle_key="ws-origin")
        return
    await ws.accept()
    try:
        raw = await asyncio.wait_for(ws.receive_text(), timeout=HELLO_TIMEOUT_S)
        hello = HelloMessage.model_validate_json(raw)
    except (asyncio.TimeoutError, ValidationError, WebSocketDisconnect, ValueError):
        await _close(ws, 4002, "Hello erwartet")
        return
    if hello.protocol != PROTOCOL_VERSION:
        await _send_error(ws, "PROTOCOL_VERSION", f"Protokollversion {PROTOCOL_VERSION} erforderlich")
        await _close(ws, 4008, "Protokollversion")
        return
    info = service.auth.verify(hello.token)
    if info is None:
        await _send_error(ws, "AUTH", "Anmeldung ungültig oder abgelaufen")
        await _close(ws, 4001, "Anmeldung ungültig")
        return
    remote = ws.client.host if ws.client else None
    try:
        session = service.open_session(hello.client_id, info.role, hello.device, remote)
    except TooManySessions as exc:
        await _send_error(ws, "TOO_MANY_SESSIONS", str(exc))
        await _close(ws, 4003, "Zu viele Verbindungen")
        return

    session.send(service.welcome(session))
    service.broadcast_telemetry()
    sender = asyncio.create_task(_sender(ws, session))
    try:
        await _receiver(ws, service, session)
    except ProtocolViolation as exc:
        await _send_error(ws, "PROTOCOL_VIOLATION", str(exc))
        await _close(ws, 4008, "Protokollverletzung")
    except WebSocketDisconnect:
        pass
    except Exception:  # pragma: no cover - unerwartete Fehler sollen die Sitzung sauber beenden
        log.exception("WebSocket-Fehler in Sitzung %s", session.id)
    finally:
        service.close_session(session)
        sender.cancel()
        try:
            await sender
        except (asyncio.CancelledError, Exception):
            pass


async def _receiver(ws: WebSocket, service: VehicleService, session: Session) -> None:
    while True:
        raw = await ws.receive_text()
        if len(raw) > MAX_MESSAGE_BYTES:
            service._reject(session, "unbekannt", None, "TOO_LARGE", "Nachricht zu groß")
            continue
        data: object = None
        try:
            data = json.loads(raw)
            message = CLIENT_MESSAGE_ADAPTER.validate_python(data)
        except (json.JSONDecodeError, ValidationError) as exc:
            kind = data.get("type", "unbekannt") if isinstance(data, dict) else "unbekannt"
            seq = data.get("seq") if isinstance(data, dict) else None
            detail = exc.errors()[0]["msg"] if isinstance(exc, ValidationError) and exc.errors() else "Ungültiges JSON"
            service._reject(session, str(kind)[:32], seq if isinstance(seq, int) else None, "INVALID_MESSAGE", detail)
            continue
        await service.handle_message(session, message)


async def _sender(ws: WebSocket, session: Session) -> None:
    while not session.closed:
        await session.wakeup.wait()
        session.wakeup.clear()
        while not session.outbox.empty():
            await ws.send_text(session.outbox.get_nowait())
        if session.latest_telemetry is not None:
            payload, session.latest_telemetry = session.latest_telemetry, None
            await ws.send_text(payload)


async def _send_error(ws: WebSocket, code: str, message: str) -> None:
    try:
        await ws.send_text(json.dumps({"type": "error", "code": code, "message": message}, ensure_ascii=False))
    except Exception:
        pass


async def _close(ws: WebSocket, code: int, reason: str) -> None:
    try:
        await ws.close(code=code, reason=reason)
    except Exception:
        pass
