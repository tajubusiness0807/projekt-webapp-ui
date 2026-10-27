"""Integrationstests: komplette Anwendung (FastAPI, Regelschleife, WebSocket) im Simulationsmodus."""

from __future__ import annotations

import json
import time
from dataclasses import replace
from typing import Any, Iterator

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.config.env import EnvSettings
from app.main import create_app

from .conftest import ADMIN_PASSWORD, PIN


@pytest.fixture
def client(env: EnvSettings) -> Iterator[TestClient]:
    app = create_app(env)
    with TestClient(app) as c:
        yield c


def login(client: TestClient, secret: str = PIN, role: str = "driver") -> str:
    r = client.post("/api/auth/login", json={"secret": secret, "role": role})
    assert r.status_code == 200, r.text
    return r.json()["token"]


class WsClient:
    def __init__(self, ws: Any) -> None:
        self.ws = ws
        self.seq = 0
        self.telemetry: dict[str, Any] | None = None
        self.events: list[dict[str, Any]] = []
        self.misc: list[dict[str, Any]] = []

    def hello(self, token: str, client_id: str = "testclient") -> dict[str, Any]:
        self.ws.send_text(json.dumps({"type": "hello", "protocol": 1, "token": token, "client_id": client_id, "device": client_id, "ts": int(time.time() * 1000)}))
        return self.wait_for("welcome")

    def send(self, kind: str, **fields: Any) -> None:
        self.seq += 1
        payload = {"type": kind, "seq": self.seq, "ts": int(time.time() * 1000), **fields}
        self.ws.send_text(json.dumps(payload))

    def drive(self, throttle: float = 0.0, brake: float = 0.0, steer: float = 0.0, profile: str = "eco") -> None:
        self.send("drive", throttle=throttle, brake=brake, steer=steer, profile=profile, source="pedals")

    def receive(self) -> dict[str, Any]:
        msg = json.loads(self.ws.receive_text())
        if msg["type"] == "telemetry":
            self.telemetry = msg
        elif msg["type"] == "event":
            self.events.append(msg["event"])
        else:
            self.misc.append(msg)
        return msg

    def wait_for(self, kind: str, predicate: Any = None, limit: int = 400) -> dict[str, Any]:
        for _ in range(limit):
            msg = self.receive()
            if msg["type"] == kind and (predicate is None or predicate(msg)):
                return msg
        raise AssertionError(f"Keine Nachricht {kind}")

    def ack(self, ref_type: str) -> dict[str, Any]:
        return self.wait_for("ack", lambda m: m["ref_type"] == ref_type)

    def drive_for(self, seconds: float, **kw: Any) -> None:
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            self.drive(**kw)
            self.receive_nowait_until(0.05)

    def receive_nowait_until(self, seconds: float) -> None:
        # TestClient-WebSockets sind blockierend: Telemetrie kommt mit 10 Hz, daher nur kurz lesen.
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            self.receive()


def test_health_and_auth_errors(client: TestClient) -> None:
    assert client.get("/api/health").json()["mode"] == "simulation"
    assert client.get("/api/settings").status_code == 401
    r = client.post("/api/auth/login", json={"secret": "0000"})
    assert r.status_code == 401
    token = login(client)
    assert client.get("/api/auth/me", headers={"authorization": f"Bearer {token}"}).json()["role"] == "driver"
    assert client.get("/api/settings", headers={"authorization": f"Bearer {token}x"}).status_code == 401


def test_login_rate_limit(client: TestClient) -> None:
    for _ in range(5):
        assert client.post("/api/auth/login", json={"secret": "9999"}).status_code == 401
    r = client.post("/api/auth/login", json={"secret": PIN})
    assert r.status_code == 429
    assert "Retry-After" in r.headers


def test_admin_endpoints_require_admin(client: TestClient) -> None:
    driver = login(client)
    h = {"authorization": f"Bearer {driver}"}
    assert client.post("/api/settings/reset", headers=h).status_code == 403
    assert client.patch("/api/settings", headers=h, json={"patch": {"ui": {"speedometer_max_kmh": 40}}}).status_code == 403
    admin = login(client, ADMIN_PASSWORD, "admin")
    ha = {"authorization": f"Bearer {admin}"}
    r = client.patch("/api/settings", headers=ha, json={"patch": {"safety": {"absolute_max_speed_kmh": 12}}})
    assert r.status_code == 200 and r.json()["version"] == 2
    r = client.patch("/api/settings", headers=ha, json={"patch": {"safety": {"absolute_max_speed_kmh": 400}}})
    assert r.status_code == 422
    assert client.post("/api/settings/reset", headers=ha).json()["version"] == 3
    assert len(client.get("/api/settings/history", headers=ha).json()) == 3
    assert client.get("/api/system", headers=ha).json()["mode"] == "simulation"


def test_security_headers(client: TestClient) -> None:
    r = client.get("/api/health")
    assert r.headers["x-frame-options"] == "DENY"
    assert "default-src 'self'" in r.headers["content-security-policy"]


def test_websocket_requires_hello_and_valid_token(client: TestClient) -> None:
    with client.websocket_connect("/ws") as ws:
        ws.send_text(json.dumps({"type": "drive", "seq": 1, "ts": 1, "throttle": 1, "brake": 0, "steer": 0, "profile": "eco"}))
        with pytest.raises(WebSocketDisconnect) as exc:
            ws.receive_text()
        assert exc.value.code == 4002
    with client.websocket_connect("/ws") as ws:
        ws.send_text(json.dumps({"type": "hello", "protocol": 1, "token": "x" * 40, "client_id": "abcd", "ts": 1}))
        assert json.loads(ws.receive_text())["code"] == "AUTH"
        with pytest.raises(WebSocketDisconnect) as exc:
            ws.receive_text()
        assert exc.value.code == 4001


def test_websocket_rejects_foreign_origin(client: TestClient) -> None:
    with pytest.raises(WebSocketDisconnect) as exc:
        with client.websocket_connect("/ws", headers={"origin": "http://evil.example"}) as ws:
            ws.receive_text()
    assert exc.value.code == 4004


def test_full_driving_flow_over_websocket(client: TestClient) -> None:
    token = login(client)
    with client.websocket_connect("/ws", headers={"origin": "http://testserver"}) as raw:
        ws = WsClient(raw)
        welcome = ws.hello(token)
        assert welcome["mode"] == "simulation"
        assert welcome["capabilities"]["drive_modes"]["fwd"]["available"] is True
        assert any(f["code"] == "E007" for f in welcome["fault_catalog"])
        tel = ws.wait_for("telemetry")
        assert tel["vehicle"]["state"] == "locked" and tel["session"]["is_owner"] is False

        ws.send("claim_control")
        assert ws.ack("claim_control")["ok"]
        ws.drive()
        ws.send("arm")
        ack = ws.ack("arm")
        assert ack["ok"], ack
        ws.drive_for(1.5, throttle=1.0)
        tel = ws.wait_for("telemetry")
        assert tel["vehicle"]["armed"] is True
        assert tel["measurements"]["speed_kmh"]["value"] > 0.5
        assert tel["measurements"]["speed_kmh"]["status"] == "simulated"
        assert tel["control"]["output"]["drive_level"] > 0

        # Loslassen → Anforderung sofort 0
        ws.drive_for(0.3, throttle=0.0)
        tel = ws.wait_for("telemetry")
        assert tel["control"]["output"]["drive_level"] == 0
        assert tel["control"]["input"]["throttle"] == 0

        # Ungültige Nachrichten werden abgelehnt, Verbindung bleibt
        raw.send_text("kein json")
        assert ws.wait_for("ack", lambda m: m["code"] == "INVALID_MESSAGE")["ok"] is False
        ws.send("drive", throttle=float(2), brake=0, steer=0, profile="eco")
        assert ws.wait_for("ack", lambda m: m["code"] == "INVALID_MESSAGE")
        raw.send_text(json.dumps({"type": "drive", "seq": 1, "ts": int(time.time() * 1000), "throttle": 0, "brake": 0, "steer": 0, "profile": "eco"}))
        assert ws.wait_for("ack", lambda m: m.get("code") == "SEQ_ORDER")

        # Fahrmodi
        ws.send("set_profile", profile="sport")
        assert ws.ack("set_profile")["ok"]
        ws.send("set_drive_mode", mode="fwd")
        assert ws.ack("set_drive_mode")["ok"]
        tel = ws.wait_for("telemetry", lambda m: m["vehicle"]["drive_mode"] == "fwd")
        assert tel["control"]["split"]["front_weight"] == 100

        ws.send("disarm")
        assert ws.ack("disarm")["ok"]


def test_disconnect_while_driving_is_reported_to_other_client(client: TestClient) -> None:
    token = login(client)
    with client.websocket_connect("/ws") as raw_obs:
        observer = WsClient(raw_obs)
        observer.hello(token, "beobachter")
        with client.websocket_connect("/ws") as raw:
            driver = WsClient(raw)
            driver.hello(token, "fahrer")
            driver.send("claim_control")
            assert driver.ack("claim_control")["ok"]
            driver.drive()
            driver.send("arm")
            assert driver.ack("arm")["ok"]
            driver.drive_for(0.8, throttle=1.0)
        # Fahrer-Verbindung getrennt
        tel = observer.wait_for("telemetry", lambda m: m["vehicle"]["state"] == "fault")
        assert any(f["code"] == "E007" for f in tel["faults"])
        assert tel["vehicle"]["armed"] is False
        assert tel["control"]["output"]["drive_level"] == 0


def test_concurrent_control_and_takeover(client: TestClient) -> None:
    token = login(client)
    with client.websocket_connect("/ws") as raw_a, client.websocket_connect("/ws") as raw_b:
        a, b = WsClient(raw_a), WsClient(raw_b)
        a.hello(token, "geraet-a")
        b.hello(token, "geraet-b")
        a.send("claim_control")
        assert a.ack("claim_control")["ok"]
        b.send("claim_control")
        assert b.ack("claim_control")["code"] == "CONTROL_BUSY"
        b.drive(throttle=1.0)
        assert b.wait_for("ack", lambda m: m["ref_type"] == "drive")["code"] == "NOT_OWNER"
        b.send("takeover_control")
        assert b.ack("takeover_control")["ok"]
        msg = a.wait_for("connection")
        assert msg["event"] == "control_lost"
        tel = b.wait_for("telemetry", lambda m: m["session"]["is_owner"])
        assert tel["vehicle"]["armed"] is False


def test_session_limit(env: EnvSettings) -> None:
    app = create_app(env)
    with TestClient(app) as c:
        token = login(c)
        admin = login(c, ADMIN_PASSWORD, "admin")
        r = c.patch("/api/settings", headers={"authorization": f"Bearer {admin}"}, json={"patch": {"safety": {"max_sessions": 1}}})
        assert r.status_code == 200
        with c.websocket_connect("/ws") as first:
            WsClient(first).hello(token, "eins")
            with c.websocket_connect("/ws") as second:
                second.send_text(json.dumps({"type": "hello", "protocol": 1, "token": token, "client_id": "zwei", "ts": 1}))
                assert json.loads(second.receive_text())["code"] == "TOO_MANY_SESSIONS"
                with pytest.raises(WebSocketDisconnect) as exc:
                    second.receive_text()
                assert exc.value.code == 4003


def test_emergency_stop_over_websocket(client: TestClient) -> None:
    token = login(client)
    with client.websocket_connect("/ws") as raw:
        ws = WsClient(raw)
        ws.hello(token)
        ws.send("estop", reason="Integrationstest")
        assert ws.ack("estop")["ok"]
        tel = ws.wait_for("telemetry", lambda m: m["vehicle"]["state"] == "emergency_stop")
        assert tel["vehicle"]["estop"] is True
        ws.send("claim_control")
        ws.ack("claim_control")
        ws.send("arm")
        assert ws.ack("arm")["ok"] is False
        ws.send("estop_reset")
        assert ws.ack("estop_reset")["ok"]


def test_frontend_static_files_served(env: EnvSettings, tmp_path) -> None:  # type: ignore[no-untyped-def]
    dist = tmp_path / "dist"
    (dist / "assets").mkdir(parents=True)
    (dist / "index.html").write_text("<!doctype html><title>AllWheel Control</title>")
    (dist / "assets" / "app.js").write_text("console.log(1)")
    app = create_app(replace(env, frontend_dist=dist))
    with TestClient(app) as c:
        r = c.get("/")
        assert r.status_code == 200 and "AllWheel" in r.text
        assert r.headers["cache-control"] == "no-cache"
        assert "immutable" in c.get("/assets/app.js").headers["cache-control"]
