"""SQLite-Speicher für versionierte Einstellungen, Ereignisprotokoll und Zähler.

* WAL-Modus und ``synchronous=NORMAL`` schonen die SD-Karte des Raspberry Pi.
* Ereignisse werden gepuffert von einem eigenen Thread geschrieben, damit Schreibzugriffe
  niemals die Regelschleife blockieren.
* Es werden keine Zugangsdaten und keine personenbezogenen Daten gespeichert.
"""

from __future__ import annotations

import json
import logging
import queue
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

_SCHEMA = """
CREATE TABLE IF NOT EXISTS settings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    version INTEGER NOT NULL UNIQUE,
    schema_version INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    source TEXT NOT NULL,
    data TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,
    level TEXT NOT NULL,
    code TEXT NOT NULL,
    category TEXT NOT NULL,
    message TEXT NOT NULL,
    details TEXT
);
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
CREATE TABLE IF NOT EXISTS kv (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""

MAX_EVENTS = 5000


@dataclass(frozen=True)
class StoredSettings:
    version: int
    schema_version: int
    created_at: int
    source: str
    data: dict[str, Any]


class Database:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.Lock()
        self._conn: sqlite3.Connection | None = None
        self._queue: "queue.Queue[tuple[Any, ...] | None]" = queue.Queue(maxsize=2000)
        self._writer: threading.Thread | None = None
        self._inserted_since_prune = 0

    # ------------------------------------------------------------------ Lebenszyklus
    def open(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(self.path), check_same_thread=False, timeout=5.0)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        conn.executescript(_SCHEMA)
        conn.commit()
        self._conn = conn
        self._prune()
        self._writer = threading.Thread(target=self._writer_loop, name="awc-db-writer", daemon=True)
        self._writer.start()

    def close(self) -> None:
        if self._writer is not None:
            self._queue.put(None)
            self._writer.join(timeout=3.0)
            self._writer = None
        with self._lock:
            if self._conn is not None:
                self._conn.close()
                self._conn = None

    @property
    def conn(self) -> sqlite3.Connection:
        if self._conn is None:
            raise RuntimeError("Datenbank ist nicht geöffnet")
        return self._conn

    # ------------------------------------------------------------------ Einstellungen
    def latest_settings(self) -> StoredSettings | None:
        with self._lock:
            row = self.conn.execute(
                "SELECT version, schema_version, created_at, source, data FROM settings ORDER BY version DESC LIMIT 1"
            ).fetchone()
        if row is None:
            return None
        try:
            data = json.loads(row[4])
        except json.JSONDecodeError:
            data = {}
        return StoredSettings(row[0], row[1], row[2], row[3], data)

    def insert_settings(self, version: int, schema_version: int, source: str, data: dict[str, Any]) -> int:
        created_at = int(time.time() * 1000)
        with self._lock:
            self.conn.execute(
                "INSERT INTO settings(version, schema_version, created_at, source, data) VALUES (?,?,?,?,?)",
                (version, schema_version, created_at, source, json.dumps(data, separators=(",", ":"))),
            )
            # Nur die letzten 50 Versionen aufbewahren.
            self.conn.execute(
                "DELETE FROM settings WHERE version NOT IN (SELECT version FROM settings ORDER BY version DESC LIMIT 50)"
            )
            self.conn.commit()
        return created_at

    def settings_history(self, limit: int = 20) -> list[dict[str, Any]]:
        with self._lock:
            rows = self.conn.execute(
                "SELECT version, schema_version, created_at, source FROM settings ORDER BY version DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return [
            {"version": r[0], "schema_version": r[1], "created_at": r[2], "source": r[3]} for r in rows
        ]

    # ------------------------------------------------------------------ Ereignisse
    def enqueue_event(self, ts: int, level: str, code: str, category: str, message: str, details: Any) -> None:
        payload = json.dumps(details, separators=(",", ":"), default=str) if details is not None else None
        try:
            self._queue.put_nowait((ts, level, code, category, message, payload))
        except queue.Full:  # pragma: no cover - nur bei extremer Last
            log.warning("Ereignis-Warteschlange voll, Ereignis verworfen: %s", code)

    def flush(self, timeout: float = 2.0) -> None:
        """Wartet, bis alle gepufferten Ereignisse geschrieben sind (für Tests und Shutdown)."""
        deadline = time.monotonic() + timeout
        while not self._queue.empty() and time.monotonic() < deadline:
            time.sleep(0.01)
        time.sleep(0.02)

    def query_events(self, limit: int = 200, level: str | None = None) -> list[dict[str, Any]]:
        sql = "SELECT id, ts, level, code, category, message, details FROM events"
        params: list[Any] = []
        if level:
            sql += " WHERE level = ?"
            params.append(level)
        sql += " ORDER BY id DESC LIMIT ?"
        params.append(limit)
        with self._lock:
            rows = self.conn.execute(sql, params).fetchall()
        result = []
        for r in rows:
            try:
                details = json.loads(r[6]) if r[6] else None
            except json.JSONDecodeError:
                details = None
            result.append(
                {"id": r[0], "ts": r[1], "level": r[2], "code": r[3], "category": r[4], "message": r[5], "details": details}
            )
        return result

    def clear_events(self) -> None:
        with self._lock:
            self.conn.execute("DELETE FROM events")
            self.conn.commit()

    # ------------------------------------------------------------------ Schlüssel/Wert
    def get_kv(self, key: str) -> str | None:
        with self._lock:
            row = self.conn.execute("SELECT value FROM kv WHERE key = ?", (key,)).fetchone()
        return None if row is None else str(row[0])

    def set_kv(self, key: str, value: str) -> None:
        with self._lock:
            self.conn.execute(
                "INSERT INTO kv(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (key, value),
            )
            self.conn.commit()

    # ------------------------------------------------------------------ intern
    def _writer_loop(self) -> None:
        while True:
            item = self._queue.get()
            if item is None:
                break
            batch = [item]
            while len(batch) < 100:
                try:
                    nxt = self._queue.get_nowait()
                except queue.Empty:
                    break
                if nxt is None:
                    self._write_batch(batch)
                    return
                batch.append(nxt)
            self._write_batch(batch)

    def _write_batch(self, batch: list[tuple[Any, ...]]) -> None:
        try:
            with self._lock:
                if self._conn is None:
                    return
                self._conn.executemany(
                    "INSERT INTO events(ts, level, code, category, message, details) VALUES (?,?,?,?,?,?)", batch
                )
                self._conn.commit()
            self._inserted_since_prune += len(batch)
            if self._inserted_since_prune > 500:
                self._prune()
        except sqlite3.Error as exc:  # pragma: no cover - Speicherfehler (z. B. SD-Karte voll)
            log.error("Ereignisse konnten nicht gespeichert werden: %s", exc)

    def _prune(self) -> None:
        with self._lock:
            if self._conn is None:
                return
            self._conn.execute(
                "DELETE FROM events WHERE id <= (SELECT id FROM events ORDER BY id DESC LIMIT 1 OFFSET ?)",
                (MAX_EVENTS,),
            )
            self._conn.commit()
        self._inserted_since_prune = 0
