"""REST-API: Anmeldung, Einstellungen, Diagnose und Systeminformationen.

Fahrbefehle laufen ausschließlich über den WebSocket (``/ws``), damit Sequenz, Alter und
Steuerungsbesitz einheitlich geprüft werden.
"""

from __future__ import annotations

import asyncio
from typing import Any, Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from pydantic import BaseModel, Field

from .. import PROTOCOL_VERSION, __version__
from ..models.common import Role
from ..models.faults import FAULT_CATALOG
from ..models.settings import SettingsPatchError, VehicleSettings, apply_settings_patch
from ..services.auth import AuthError, AuthService, TokenInfo
from ..services.vehicle_service import VehicleService
from ..storage.settings_store import VersionConflict
from .deps import get_auth, get_service, require_admin, require_token

router = APIRouter(prefix="/api")


class LoginRequest(BaseModel):
    role: Literal["driver", "admin"] = "driver"
    secret: str = Field(min_length=1, max_length=128)


class SettingsPatchRequest(BaseModel):
    patch: dict[str, Any]
    expected_version: int | None = None


def _client(request: Request) -> str:
    return request.client.host if request.client else "unbekannt"


@router.get("/health")
def health(service: VehicleService = Depends(get_service)) -> dict[str, Any]:
    return {
        "status": "ok",
        "version": __version__,
        "protocol": PROTOCOL_VERSION,
        "mode": service.mode.value,
        "state": service.safety.state.value,
    }


@router.post("/auth/login")
def login(body: LoginRequest, request: Request, auth: AuthService = Depends(get_auth), service: VehicleService = Depends(get_service)) -> dict[str, Any]:
    role = Role(body.role)
    try:
        token, info = auth.login(role, body.secret, _client(request))
    except AuthError as exc:
        service.events.warning(
            "AUTH_FAILED", "zugang", "Anmeldung fehlgeschlagen", {"rolle": role.value},
            throttle_key=f"auth:{_client(request)}", throttle_s=10,
        )
        headers = {"Retry-After": str(exc.retry_after)} if exc.retry_after else None
        raise HTTPException(exc.status, str(exc), headers=headers) from exc
    service.events.info("AUTH_OK", "zugang", f"Anmeldung als {'Administrator' if role == Role.ADMIN else 'Fahrer'}")
    return {"token": token, "role": info.role.value, "expires_at": info.expires_at}


@router.get("/auth/me")
def me(info: TokenInfo = Depends(require_token)) -> dict[str, Any]:
    return {"role": info.role.value, "expires_at": info.expires_at}


@router.get("/settings")
def get_settings(service: VehicleService = Depends(get_service), _: TokenInfo = Depends(require_token)) -> dict[str, Any]:
    return {
        "version": service.store.version,
        "settings": service.settings.model_dump(mode="json"),
        "capabilities": service.capabilities(),
    }


@router.put("/settings")
async def replace_settings(
    body: dict[str, Any], service: VehicleService = Depends(get_service), _: TokenInfo = Depends(require_admin)
) -> dict[str, Any]:
    try:
        settings = VehicleSettings.model_validate(body)
    except Exception as exc:
        raise HTTPException(422, f"Einstellungen ungültig: {exc}") from exc
    version = await service.store.save(settings, "rest:admin")
    return {"version": version}


@router.patch("/settings")
async def patch_settings(
    body: SettingsPatchRequest, service: VehicleService = Depends(get_service), _: TokenInfo = Depends(require_admin)
) -> dict[str, Any]:
    try:
        settings = apply_settings_patch(service.settings, body.patch, allow_admin=True)
        version = await service.store.save(settings, "rest:admin", body.expected_version)
    except SettingsPatchError as exc:
        raise HTTPException(422, {"message": str(exc), "details": exc.details}) from exc
    except VersionConflict as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc
    return {"version": version}


@router.post("/settings/reset")
async def reset_settings(service: VehicleService = Depends(get_service), _: TokenInfo = Depends(require_admin)) -> dict[str, Any]:
    version = await service.store.reset("rest:zuruecksetzen")
    service.events.warning("CONFIG_RESET", "konfiguration", "Einstellungen auf sichere Standardwerte zurückgesetzt")
    return {"version": version}


@router.get("/settings/history")
async def settings_history(service: VehicleService = Depends(get_service), _: TokenInfo = Depends(require_admin)) -> list[dict[str, Any]]:
    return await asyncio.to_thread(service.store.history, 20)


@router.get("/diagnostics/faults")
def fault_catalog() -> list[dict[str, Any]]:
    return [d.to_dict() for d in FAULT_CATALOG.values()]


@router.get("/diagnostics/events")
async def events(
    limit: int = Query(200, ge=1, le=1000),
    level: Literal["info", "warning", "critical"] | None = None,
    service: VehicleService = Depends(get_service),
    _: TokenInfo = Depends(require_token),
) -> list[dict[str, Any]]:
    if service.db is None:
        return service.events.recent(limit)
    return await asyncio.to_thread(service.db.query_events, limit, level)


@router.delete("/diagnostics/events")
async def clear_events(service: VehicleService = Depends(get_service), _: TokenInfo = Depends(require_admin)) -> dict[str, Any]:
    if service.db is not None:
        await asyncio.to_thread(service.db.clear_events)
    service.events.info("LOG_CLEARED", "diagnose", "Ereignisprotokoll gelöscht")
    return {"ok": True}


@router.get("/system")
async def system_info(service: VehicleService = Depends(get_service), _: TokenInfo = Depends(require_token)) -> dict[str, Any]:
    snapshot = await asyncio.to_thread(service.system_monitor.snapshot)
    return {
        "version": __version__,
        "protocol": PROTOCOL_VERSION,
        "mode": service.mode.value,
        "system": snapshot,
        "readiness": [item.to_dict() for item in (service.build.readiness if service.build else [])],
        "hardware_init_error": service.build.init_error if service.build else None,
        "restart_required": service.restart_required,
        "tls": service.env.tls_certfile is not None,
    }
