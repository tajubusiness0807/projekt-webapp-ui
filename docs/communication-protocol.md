# Kommunikationsprotokoll

AllWheel Control nutzt **eine** WebSocket-Verbindung je Gerät (`/ws`) für alles Zeitkritische und eine
kleine REST-API (`/api/...`) für Anmeldung, Administration und Diagnose. Alle Nachrichten sind JSON
(UTF-8). Protokollversion: **1**.

```
Browser ──hello(token)──▶ Backend
        ◀──welcome────────
        ──drive (20 Hz)──▶     ◀──telemetry (10 Hz, sofort bei Zustandswechsel)──
        ──ping (0,5 Hz)──▶     ◀──pong──
        ──Befehle────────▶     ◀──ack / event / settings / connection──
```

## 1. Verbindungsaufbau

1. `POST /api/auth/login` mit PIN (Fahrer) oder Passwort (Administrator) → signiertes Token.
2. WebSocket zu `ws(s)://<host>/ws` öffnen. Der Server prüft den `Origin`-Header (gleicher Host
   oder `AWC_ALLOWED_ORIGINS`), sonst Abbruch mit Code **4004**.
3. Innerhalb von **5 s** muss `hello` folgen – das Token steht bewusst nicht in der URL.

```json
{ "type": "hello", "protocol": 1, "token": "<token>", "client_id": "a1b2c3…", "device": "Smartphone 7F2A", "ts": 1730000000000 }
```

| Close-Code | Bedeutung |
|---|---|
| 4001 | Token ungültig oder abgelaufen → neu anmelden |
| 4002 | Kein gültiges `hello` innerhalb von 5 s |
| 4003 | Zu viele gleichzeitige Verbindungen (`safety.max_sessions`) |
| 4004 | Herkunft (Origin) nicht erlaubt |
| 4008 | Protokollverletzung (falsche Version, > 50 ungültige Nachrichten in 10 s) |

## 2. Client → Server

### Gemeinsame Felder aller Steuernachrichten

| Feld | Typ | Bedeutung |
|---|---|---|
| `type` | string | Nachrichtentyp |
| `seq` | int ≥ 1 | Fortlaufende Sequenznummer **je Verbindung**, streng steigend |
| `ts` | int | Zeitstempel des Clients in ms (Unix-Zeit) |

Unbekannte Felder, `NaN`/`Infinity`, falsche Typen oder Werte außerhalb der Bereiche werden abgelehnt.

### Fahranforderung `drive`

Wird vom steuernden Gerät **dauerhaft mit 20 Hz** gesendet – auch bei losgelassenen Bedienelementen
(Lebenszeichen).

```json
{ "type": "drive", "seq": 412, "ts": 1730000001234,
  "throttle": 0.62, "brake": 0.0, "steer": -0.15, "profile": "sport", "source": "pedals" }
```

| Feld | Bereich | Bedeutung |
|---|---|---|
| `throttle` | 0 … 1 | Angeforderte Gasstellung |
| `brake` | 0 … 1 | Angeforderte Verzögerung |
| `steer` | −1 … 1 | Lenkanforderung (negativ = links) |
| `profile` | eco/normal/sport/custom | Gewünschter Fahrmodus – muss dem aktiven Profil entsprechen |
| `source` | pedals/joystick/tilt/keyboard/none | Herkunft (nur Diagnose) |

Prüfungen im Backend (`app/safety/command_gate.py`, `vehicle_service._on_drive`):

* **Sequenz**: `seq` ≤ letzte angenommene → `SEQ_ORDER`.
* **Alter**: Ein Paket, das mehr als `max_command_age_ms` (Standard 400 ms) länger unterwegs war als
  das schnellste der letzten 10 s, wird verworfen (`STALE`). Uhrversatz zwischen Handy und Pi spielt
  keine Rolle; nach einem Funkloch von TCP nachgelieferte alte Befehle werden so nicht ausgeführt.
* **Rate**: mehr als `max_command_rate_hz` (Standard 40) Nachrichten/s → `RATE_LIMIT`.
* **Widerspruch**: `throttle > 0` und `brake > 0` gleichzeitig → `CONTRADICTORY`, sicher interpretiert als „kein Gas, Bremse“.
* **Profil**: weicht `profile` vom aktiven Profil ab → `PROFILE_MISMATCH` (Befehl verworfen).
* **Besitz**: nur der Steuerungsbesitzer → sonst `NOT_OWNER`.

Fahrbefehle werden nur bei **Ablehnung** quittiert (kein Ack je Paket). Der tatsächlich verarbeitete
Zustand steht in der Telemetrie (`control.input`, `control.output`).

### Weitere Befehle

| `type` | Felder | Wer | Wirkung |
|---|---|---|---|
| `set_profile` | `profile` | Besitzer | Fahrprofil wechseln (**Fahrmodusänderung**) |
| `set_drive_mode` | `mode`: awd/fwd/rwd/custom | Besitzer | Antriebsmodus (**Antriebsmodusänderung**); nur wenn verfügbar |
| `set_power_split` | `target`: awd/custom, `front_percent` | Besitzer | Gewichtung vorne (hinten = 100 − vorne) |
| `set_direction` | `direction`: forward/reverse | Besitzer | Nur im Stillstand und ohne Gas |
| `update_settings` | `patch`, optional `expected_version` | Besitzer | **Konfigurationsänderung** (Fahrer-Abschnitte; Admin-Token für alle) |
| `reset_profiles` | – | Besitzer | Fahrprofile auf Standard |
| `arm` / `disarm` | – | Besitzer | Motorfreigabe / Sperre |
| `estop` | `reason` | **jede Sitzung** | **Not-Aus-Anforderung** |
| `estop_reset` | – | Besitzer | Not-Aus zurücksetzen (bleibt gesperrt) |
| `ack_faults` | – | Besitzer | Behobene Fehler quittieren |
| `claim_control` / `release_control` / `takeover_control` | – | jede | Steuerungsbesitz |
| `reset_trip` | – | Besitzer | Fahrzeit zurücksetzen |
| `sim_inject` | `fault`, `active` | Besitzer | Fehlerinjektion (nur Simulation) |
| `ping` | `ts`, optional `rtt_ms` | jede | Latenzmessung (ohne `seq`) |

Antwort auf jeden Befehl außer `drive`/`ping`:

```json
{ "type": "ack", "ref_type": "arm", "ref_seq": 17, "ok": false, "code": "ARM_REFUSED", "message": "Gas muss losgelassen sein" }
```

## 3. Server → Client

| `type` | Wann | Inhalt |
|---|---|---|
| `welcome` | nach `hello` | Sitzung, Rolle, Betriebsart, Einstellungen + Version, Fähigkeiten, Fehlerkatalog, letzte Ereignisse |
| `telemetry` | 10 Hz und sofort bei Zustandswechsel | **Telemetrie** (siehe unten) inkl. `session` (**Verbindungsstatus**) |
| `ack` | auf Befehle | Ergebnis |
| `event` | bei jedem Ereignis | **Fehlerereignis** bzw. Protokolleintrag |
| `settings` | nach jeder gespeicherten Änderung | neue Einstellungen, Version, Fähigkeiten |
| `connection` | Steuerung verloren | `event: "control_lost"`, Meldung |
| `pong` | auf `ping` | Echo `ts`, `server_ts` |
| `error` | vor Abbruch | `code`, `message` |

### Telemetrie

Gekürztes Beispiel (Simulation):

```json
{
  "type": "telemetry", "seq": 1042, "ts": 1730000001300, "mode": "simulation",
  "vehicle": { "state": "armed", "armed": true, "neutral_required": false, "estop": false,
               "direction": "forward", "profile": "eco", "drive_mode": "awd",
               "brake_state": "coasting", "brake_support": null, "trip_s": 42, "total_drive_s": 45360,
               "restart_required": false, "commissioning": false, "sim_faults": [] },
  "measurements": {
    "speed_kmh":      { "value": 6.4, "status": "simulated", "age_ms": 12, "unit": "km/h" },
    "motor_rpm":      { "value": 205, "status": "simulated", "age_ms": 12, "unit": "U/min" },
    "battery_voltage":{ "value": 39.6, "status": "simulated", "age_ms": 12, "unit": "V" },
    "battery_percent":{ "value": 74, "status": "simulated", "age_ms": 12, "unit": "%" },
    "controller_temp_c": { "value": 26.1, "status": "simulated", "age_ms": 12, "unit": "°C" },
    "motor_temp_c":   { "value": 24.0, "status": "simulated", "age_ms": 12, "unit": "°C" },
    "electrical_power_w": { "value": 48, "status": "simulated", "age_ms": 12, "unit": "W" },
    "wifi_signal_dbm":{ "value": -47, "status": "simulated", "age_ms": 900, "unit": "dBm" },
    "wifi_quality": "stark"
  },
  "control": {
    "input":  { "throttle": 0.5, "brake": 0, "steer": 0 },
    "output": { "target_throttle": 0.47, "effective_throttle": 0.24, "drive_level": 0.24, "brake_level": 0,
                "steer": 0, "speed_limit_kmh": 8, "speed_factor": 1, "front": {"left": 0.24, "right": 0.24},
                "rear": {"left": 0.24, "right": 0.24}, "limited_by": ["profil"] },
    "split":  { "front_weight": 50, "rear_weight": 50, "front_scale": 1, "rear_scale": 1, "distribution_available": true },
    "effective_profile": { "max_throttle_percent": 50, "max_speed_kmh": 8, "limited": {} }
  },
  "controllers": [ { "id": "A", "axle": "front", "adapter": "simulation", "link": "connected",
                     "feedback_age_ms": 8, "frames_ok": 5210, "frames_bad": 0, "...": "…" } ],
  "faults": [],
  "system": { "loop_hz": 25.0, "loop_max_ms": 41.2, "uptime_s": 3600, "cpu_temp_c": 51.0 },
  "session": { "id": "9f2c1a0b", "role": "driver", "is_owner": true, "owner_present": true,
               "owner_device": "Smartphone 7F2A", "count": 2, "can_takeover": false }
}
```

**Messwertzustände:** `valid` (gemessen, aktuell), `simulated` (Simulation, aktuell), `stale` (älter als
`telemetry_stale_ms`), `unavailable` (nie gemessen / nicht messbar). Zusätzlich behandelt das Frontend
alle Werte als veraltet, wenn 1,5 s keine Telemetrie kam.

**Begriffe Leistung:** `split.*_weight` = angeforderte Gewichtung, `output.front/rear` = begrenzte
Motoranforderung je Rad, `controllers[].electrical_power_w` = gemessene elektrische Leistung (nur wenn
der Controller sie liefert; bei FOC-USART **nicht verfügbar**).

## 4. Raten und Zeitlimits (Standardwerte)

| Größe | Wert | Einstellung |
|---|---|---|
| Fahranforderung | 20 Hz | fest im Frontend |
| Telemetrie | 10 Hz | `telemetry.broadcast_hz` |
| Regelschleife | 25 Hz | `telemetry.control_loop_hz` |
| Befehl veraltet → neutral | 300 ms | `safety.command_timeout_ms` |
| Verbindung verloren → Fehler | 1000 ms | `safety.connection_timeout_ms` |
| Controller ohne Rückmeldung | 500 ms | `safety.controller_timeout_ms` |
| Ping | 2 s | Frontend |
| Frontend erklärt Verbindung für tot | 2,5 s ohne Nachricht | Frontend |
| Wiederverbindung | 0,8 s … 5 s (wachsend) | Frontend |

Die Raten sind für den Raspberry Pi 3B ausgelegt (≈ 5 % CPU-Last).

## 5. REST-API

| Methode & Pfad | Recht | Zweck |
|---|---|---|
| `GET /api/health` | – | Status, Version, Betriebsart |
| `POST /api/auth/login` | – | `{secret, role}` → `{token, role, expires_at}`; 5 Fehlversuche/min → 60 s Sperre (429) |
| `GET /api/auth/me` | Token | Rolle prüfen |
| `GET /api/settings` | Token | Einstellungen, Version, Fähigkeiten |
| `PATCH /api/settings` | Admin | `{patch, expected_version}` → neue Version (409 bei Konflikt, 422 ungültig) |
| `PUT /api/settings` | Admin | Komplettersatz |
| `POST /api/settings/reset` | Admin | Sichere Standardwerte |
| `GET /api/settings/history` | Admin | Letzte Versionen |
| `GET /api/diagnostics/events?limit=&level=` | Token | Ereignisprotokoll |
| `DELETE /api/diagnostics/events` | Admin | Protokoll leeren |
| `GET /api/diagnostics/faults` | – | Fehlerkatalog |
| `GET /api/system` | Token | Raspberry-Pi-Zustand, Hardware-Checkliste |
| `GET /api/docs` | – | OpenAPI-Oberfläche |

Token: `Authorization: Bearer <token>` – HMAC-SHA256-signiert, enthält Rolle und Ablauf; ändern sich PIN
oder Passwort, werden alle Tokens ungültig.

## 6. Serielles Protokoll zum Controller (FOC-Firmware)

Siehe `backend/app/controllers/foc_protocol.py` und [hardware.md](hardware.md). Kurzfassung (gegen die
Originalquellen geprüft): Befehl `0xABCD, steer, speed, start^steer^speed` (8 Byte, Little Endian,
±1000), Rückmeldung 18 Byte (22 mit Odometrie) mit XOR-Prüfsumme, 115200 Baud 8N1.
