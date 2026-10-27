# Tests

Alle automatisierten Tests laufen **ohne Motorcontroller**. Hardwareadapter werden mit einer
simulierten seriellen Schnittstelle (`FakeSerial`) geprüft, die nie ein reales Gerät öffnet.
Kein automatisierter Test bewegt echte Motoren.

## Ausführen

```bash
cd backend && .venv/bin/python -m pytest          # Backend: Unit + Integration
cd frontend && npm test                            # Frontend-Logik (Vitest)
cd frontend && npm run e2e                         # Ende-zu-Ende (laufendes Backend in Simulation nötig)
```

## Abdeckung

| Bereich | Datei(en) | Art |
|---|---|---|
| Fahrmoduswechsel, Profile ändern Ansprechverhalten | `test_vehicle_service.py` (`test_profiles_change_response`) | Integration (Simulation) |
| Antriebsmoduswechsel, Verfügbarkeit nach Hardware | `test_vehicle_service.py`, `test_limits_and_gate.py` | Unit/Integration |
| Leistungsverteilung (Definition, 60/40, 100/0, FWD) | `test_drive_logic.py`, `test_vehicle_service.py` | Unit/Integration |
| Grenzwertvalidierung, Sport ≤ Sicherheitsgrenzen, Inbetriebnahme | `test_settings.py`, `test_limits_and_gate.py`, `test_drive_logic.py` | Unit |
| Totmannsteuerung (Loslassen, Lease, Neutralverriegelung) | `test_vehicle_service.py`, `frontend/src/lib/deadman.test.ts`, `e2e/smoke.cjs` | Unit/Integration/E2E |
| Verbindungsverlust (getrennt, stumm, über WebSocket) | `test_vehicle_service.py`, `test_api_websocket.py`, `e2e/smoke.cjs` | Integration/E2E |
| Watchdog (langsame Schleife, Supervisor) | `test_vehicle_service.py`, `test_safety_state.py` | Unit/Integration |
| Ungültige WebSocket-Nachrichten (JSON, Bereich, Sequenz, Alter, Rate, Widerspruch, Profil) | `test_api_websocket.py`, `test_limits_and_gate.py`, `test_vehicle_service.py` | Unit/Integration |
| Fehlerhafte Telemetrie (unplausibel, Prüfsumme, Resynchronisation) | `test_foc_protocol.py`, `test_vehicle_service.py` | Unit/Integration |
| Ungültige Konfiguration (Felder, Querbezüge, Manipulation, Rechte) | `test_settings.py` | Unit |
| Controllerfehler (einer/beide offline, Port fehlt) | `test_vehicle_service.py`, `test_hardware_mode.py`, `test_foc_serial_adapter.py` | Integration |
| Not-Aus (Beobachter löst aus, nur Besitzer setzt zurück, keine Auto-Freigabe) | `test_vehicle_service.py`, `test_safety_state.py`, `test_api_websocket.py`, `e2e/smoke.cjs` | Unit/Integration/E2E |
| Wiederverbindung (Besitz zurück, gesperrt) | `test_vehicle_service.py`, `e2e/smoke.cjs` | Integration/E2E |
| Simulation (Kennzeichnung, Physik, Fehlerinjektion) | `test_vehicle_service.py` | Integration |
| Konkurrierende Steuerverbindungen, Übernahme, Sitzungslimit | `test_vehicle_service.py`, `test_api_websocket.py` | Integration |
| Zugangsschutz (Tokens, Sperre, Rechte, Origin, Dateirechte) | `test_auth_and_telemetry.py`, `test_api_websocket.py` | Unit/Integration |
| FOC-Protokoll (Rahmen, Prüfsumme, Mischer, Einheiten) | `test_foc_protocol.py`, `test_foc_serial_adapter.py` | Unit |
| Hardwaremodus-Freigabe (Checkliste, E009, kein stiller Rückfall) | `test_hardware_mode.py` | Integration (FakeSerial) |
| Neigungsmathematik (Hoch-/Querformat, Totzone, Kalibrierung) | `frontend/src/lib/tilt.test.ts` | Unit |
| Gesamte Anwendung über Browser | `frontend/e2e/smoke.cjs` | E2E (Playwright + WebSocket-Beobachter) |

## Nur in der Simulation

Alle Tests oben. Der E2E-Test bricht ab, wenn das Backend nicht im Simulationsmodus läuft.

## Nur mit sicher aufgebauter Hardware

| Test | Wie | Voraussetzung |
|---|---|---|
| Rückmeldungen ohne Bewegung | `AWC_HARDWARE_TESTS=1 AWC_TEST_PORT=/dev/ttyUSB0 pytest tests/hardware -m hardware` | Controller versorgt, Räder aufgebockt, Not-Aus griffbereit |
| Drehrichtung, Zuordnung, Lenkung | manuell, `hardware.md` Schritt B | aufgebockt |
| Firmware-Timeout | manuell (Dienst stoppen) | aufgebockt |
| Hardware-Not-Aus | manuell | aufgebockt |
| Bremsmethode | manuell, `hardware.md` Schritt D | aufgebockt, dann Schrittgeschwindigkeit |
| Achsunabhängigkeit | manuell, Schritt E | aufgebockt |
| Messwerte (Geschwindigkeit, Spannung, Temperatur) | Vergleich mit Messgerät | – |
| Funkreichweite / WLAN-Abriss | Entfernen bis Abriss, Reaktion E007 prüfen | freie Fläche, langsam |

Tests mit Motorbewegung werden bewusst **nicht** automatisiert.
