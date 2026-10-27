"""FastAPI-Anwendung: Lebenszyklus, Routen, statische Auslieferung des Frontends."""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from typing import AsyncIterator

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from . import __version__
from .api.routes import router as api_router
from .config.env import EnvSettings
from .controllers.foc_serial import SerialFactory
from .services.auth import AuthService
from .services.events import EventLog
from .services.vehicle_service import VehicleService
from .storage.database import Database
from .storage.settings_store import SettingsStore
from .utils.clock import Clock, SystemClock
from .websocket.handler import router as ws_router

log = logging.getLogger(__name__)

CSP = (
    "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
    "font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
)


def create_app(
    env: EnvSettings | None = None,
    *,
    clock: Clock | None = None,
    serial_factory: SerialFactory | None = None,
    run_loops: bool = True,
) -> FastAPI:
    env = env or EnvSettings.from_env()
    clock = clock or SystemClock()

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        env.data_dir.mkdir(parents=True, exist_ok=True)
        db = Database(env.data_dir / "allwheel.sqlite3")
        db.open()
        events = EventLog(clock, db)
        store = SettingsStore(db)
        store.load()
        auth = AuthService(env)
        auth.initialize()
        service = VehicleService(env, store, events, auth, clock, db=db, serial_factory=serial_factory)
        app.state.service = service
        app.state.auth = auth
        app.state.db = db
        await service.start(run_loops=run_loops)
        try:
            yield
        finally:
            await service.stop()
            db.flush()
            db.close()

    app = FastAPI(
        title="AllWheel Control",
        version=__version__,
        lifespan=lifespan,
        docs_url="/api/docs",
        redoc_url=None,
        openapi_url="/api/openapi.json",
    )

    @app.middleware("http")
    async def security_headers(request: Request, call_next):  # type: ignore[no-untyped-def]
        response: Response = await call_next(request)
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("X-Frame-Options", "DENY")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        if not request.url.path.startswith("/api/docs"):
            response.headers.setdefault("Content-Security-Policy", CSP)
        path = request.url.path
        if path.startswith("/assets/"):
            response.headers.setdefault("Cache-Control", "public, max-age=31536000, immutable")
        elif not path.startswith("/api"):
            response.headers.setdefault("Cache-Control", "no-cache")
        return response

    app.include_router(api_router)
    app.include_router(ws_router)

    if env.frontend_dist and (env.frontend_dist / "index.html").is_file():
        app.mount("/", StaticFiles(directory=str(env.frontend_dist), html=True), name="frontend")
    else:
        @app.get("/", include_in_schema=False)
        def no_frontend() -> JSONResponse:
            return JSONResponse(
                {
                    "message": "Frontend nicht gebaut. Bitte 'npm run build' im Ordner frontend ausführen "
                    "oder AWC_FRONTEND_DIST setzen. Die API ist unter /api erreichbar.",
                }
            )

    return app
