"""Abhängigkeiten für die REST-API (Dienstzugriff und Authentifizierung)."""

from __future__ import annotations

from fastapi import Depends, HTTPException, Request, status

from ..services.auth import AuthService, TokenInfo
from ..services.vehicle_service import VehicleService


def get_service(request: Request) -> VehicleService:
    return request.app.state.service


def get_auth(request: Request) -> AuthService:
    return request.app.state.auth


def _bearer(request: Request) -> str | None:
    header = request.headers.get("authorization", "")
    if header.lower().startswith("bearer "):
        return header[7:].strip()
    return None


def require_token(request: Request, auth: AuthService = Depends(get_auth)) -> TokenInfo:
    info = auth.verify(_bearer(request))
    if info is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Anmeldung erforderlich", headers={"WWW-Authenticate": "Bearer"})
    return info


def require_admin(info: TokenInfo = Depends(require_token)) -> TokenInfo:
    if not info.is_admin:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Administratorrechte erforderlich")
    return info
