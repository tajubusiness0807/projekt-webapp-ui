# Architektur

## Überblick

```
┌──────────────── Smartphone / Tablet (Browser) ────────────────┐
│ React + TypeScript (statisch vom Pi ausgeliefert, keine CDNs) │
│  Eingaben ─▶ Totmann-Kanäle (Lease 250 ms) ─▶ Sender 20 Hz    │
│  Anzeige  ◀─ Telemetrie-Store (nur bestätigte Backend-Werte)  │
└───────────────┬───────────────────────────────▲───────────────┘
        WebSocket /ws (hello+Token, seq, ts)     │ Telemetrie 10 Hz
┌───────────────▼───────────────────────────────┴───────────────┐
│ Raspberry Pi 3B – ein Python-Prozess (FastAPI, asyncio)        │
│                                                                │
│  websocket/handler ─▶ CommandGate ─▶ SessionManager (Besitz)   │
│                         │                                      │
│                         ▼                                      │
│  VehicleService.step() 25 Hz ─────────────────────────────┐    │
│   1 Telemetrie lesen + plausibilisieren                   │    │
│   2 Watchdog: Loop, Controller, Akku, Temperatur, Client  │    │
│   3 SafetyManager (Zustandsautomat, Fehler)               │    │
│   4 DriveComputer (Profile, Rampen, Grenzen, Verteilung)  │    │
│   5 DrivetrainCoordinator ─▶ Adapter vorne / hinten       │    │
│   6 Simulation (nur Simulationsmodus)                     │    │
│                                                           │    │
│  LoopSupervisor-Thread (unabhängig) ── Nullbefehl bei Hänger   │
│  SQLite: Einstellungen (versioniert), Ereignisse, Zähler       │
│  sd_notify ─▶ systemd-Watchdog                                 │
└───────────────┬────────────────────────────────────────────────┘
                │ UART 115200 (nur Hardwaremodus)
        Controller A (Achse lt. Konfig.)   Controller B
```

## Backend-Module (`backend/app`)

| Paket | Inhalt |
|---|---|
| `main.py`, `__main__.py` | App-Fabrik, Lebenszyklus, Sicherheits-Header, statisches Frontend, Uvicorn-Start (optional TLS) |
| `config/env.py` | Startkonfiguration aus Umgebungsvariablen (`AWC_*`), `.env`-Lader |
| `models/` | `common` (Aufzählungen), `settings` (validierte Einstellungen + Patch-Logik), `protocol` (WebSocket-Nachrichten), `faults` (Fehlerkatalog) |
| `storage/` | SQLite mit Schreib-Thread; `SettingsStore` mit Versionen, Migration, Rückfall auf Standardwerte |
| `services/vehicle_service.py` | Regelschleife, Überwachung, Befehlsverarbeitung, Telemetrie |
| `services/drive_logic.py` | Reine Fahrlogik (testbar ohne I/O) |
| `services/session_manager.py` | Sitzungen, Sende-Warteschlangen, Steuerungsbesitz |
| `services/auth.py` | PIN/Passwort, HMAC-Tokens, Sperre nach Fehlversuchen |
| `services/events.py` | Ereignisprotokoll (Ringpuffer + SQLite + Live-Verteilung, Drosselung) |
| `safety/command_gate.py` | Sequenz-, Alters- und Ratenprüfung je Sitzung |
| `safety/state_machine.py` | Zustandsautomat INITIALIZING/LOCKED/ARMED/FAULT/EMERGENCY_STOP |
| `safety/limits.py` | Wirksame Profile, Antriebsmodus-Verfügbarkeit, Achsgewichtung, Totzone |
| `safety/watchdog.py` | `LoopSupervisor`-Thread |
| `controllers/base.py` | `MotorControllerInterface` und Datentypen |
| `controllers/simulated.py` | Simulationsadapter |
| `controllers/foc_protocol.py` | Geprüfter Codec für hoverboard-firmware-hack-FOC |
| `controllers/foc_serial.py` | Serieller Adapter für **einen** Controller |
| `controllers/coordinator.py` | Koordination beider Controller |
| `controllers/factory.py` | Aufbau Simulation/Hardware, Freigabe-Checkliste |
| `simulation/` | Fahrzeugphysik, Fehlerinjektion |
| `telemetry/` | Messwerte mit Zustand, Aggregation/Plausibilisierung, Akku-Schätzung, WLAN, Systemzustand |
| `websocket/handler.py` | `/ws`-Endpunkt (Origin, Hello, Empfänger, Sender) |
| `api/` | REST-Endpunkte |

### MotorControllerInterface

```python
class MotorControllerInterface(ABC):
    controller_id: str            # "A" oder "B"
    axle: Axle                    # front/rear (aus der Konfiguration)
    capabilities: ControllerCapabilities   # brake, speed_feedback, … (nicht geraten)
    async def connect() -> None              # öffnet, sendet nur Nullbefehl
    async def disconnect() -> None           # Nullbefehl + schließen
    def set_drive_request(cmd: WheelCommand) -> None   # je Rad −1…1, bereits begrenzt
    def set_speed_limit(kmh: float | None) -> bool     # False = Backend begrenzt allein
    def request_brake(level: float) -> BrakeSupport    # APPLIED oder DRIVE_OFF_ONLY
    def read_telemetry() -> ControllerTelemetry | None # nicht blockierend
    def get_status() -> ControllerStatus
    def emergency_stop() -> None                       # thread-sicher, idempotent
    async def close() -> None
```

Neue Controller-Typen (andere Firmware, CAN, PWM …) werden als weitere Implementierung ergänzt und in
`controllers/factory.py` eingehängt. Fahrlogik und Sicherheitsschicht bleiben unverändert.

### Regelzyklus (`VehicleService.step`)

1. `coordinator.poll()` liest beide Controller; `DrivetrainTelemetry.ingest()` verwirft unplausible Pakete (E004).
2. Überwachung: Zyklusdauer (E008), Controller-Zeitüberschreitung (E001/E002), Paketfehler (E003),
   Akku (W006/E006 mit Haltezeit und Hysterese), Temperatur (W005/E005), Steuergerät (E007), Geschwindigkeit messbar (W014).
3. Fahreranforderung: nur vom Besitzer, nur wenn ≤ `command_timeout_ms` alt, sonst neutral + Neutralverriegelung (W012).
4. `DriveComputer.compute()` → Radanforderungen + Bremsstufe.
5. ARMED: `coordinator.apply()`; sonst sicherer Stopp (verifizierte Bremse bei Bewegung, sonst Antrieb aus).
6. Simulation fortschreiben, Bremszustand aus **gemessener** Verzögerung, Fahrzeit, Lebenszeichen.

## Frontend (`frontend/src`)

| Ordner | Inhalt |
|---|---|
| `pages/` | Fahren, Dashboard, Fahrmodi, Leistung, Einstellungen, Verbindung, Diagnose, System, Anmeldung |
| `components/gauges` | SVG-Tacho (`hero` = Bild 1, `compact` = Bild 2) |
| `components/controls` | Pedale, Joystick, Lenkung, Motorfreigabe, Modusauswahl, Verteilung |
| `components/layout` | Kopfzeile, Navigation, Statusleisten, Fehlerbanner, Not-Aus |
| `components/vehicle` | Fahrzeug-Draufsicht |
| `services/` | WebSocket-Client, REST, Neigungssteuerung, Einstellungen, Speicher |
| `stores/` | Zustand (zustand): Fahrzeug/Telemetrie, Eingaben (Totmann), Anmeldung, Hinweise |
| `lib/` | Reine Logik: Totmann-Kanäle, Neigungsmathematik, Formatierung, Beschriftungen |
| `hooks/` | 20-Hz-Sender, Tastatur, Routing, Glättung |

Grundsätze: Anzeige nur aus bestätigter Telemetrie; Profil im Fahrbefehl ist das vom Backend gemeldete;
alle Bedienelemente sind ohne Steuerungsbesitz bzw. ohne Verbindung gesperrt.

## Ressourcen auf dem Raspberry Pi 3B

* Ein Prozess, keine zusätzlichen Dienste (kein Redis, kein Nginx nötig).
* Gemessen in der Simulation auf einem x86-Entwicklungsrechner (während E2E-Test mit zwei Verbindungen):
  ≈ 53 MB Speicher (RSS), ≈ 2 % CPU. Auf dem Pi 3B ist mit deutlich höherer CPU-Last je Kern zu rechnen
  (Schätzung 10–20 % eines Kerns) – bitte auf der echten Hardware in der Systemansicht prüfen.
* SQLite im WAL-Modus; Ereignisse gebündelt in eigenem Thread; Betriebsstunden alle 60 s.
* Frontend ≈ 110 KB JS (gzip) + Schrift, einmalig geladen.
