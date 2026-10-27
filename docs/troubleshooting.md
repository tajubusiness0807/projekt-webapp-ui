# Fehlerbehebung

## Oberfläche / Verbindung

| Symptom | Ursache / Lösung |
|---|---|
| Seite lädt nicht | WLAN „AllWheel“ verbunden? `systemctl status allwheel-control`. Port (8080/8443) und Protokoll (http/https) prüfen. |
| „Frontend nicht gebaut“ (JSON-Meldung) | `frontend/dist` fehlt → `deployment/scripts/build-frontend.sh`, erneut installieren. |
| Anmeldung „Zugangsdaten falsch“ | PIN in `/etc/allwheel-control/allwheel.env` bzw. `/var/lib/allwheel-control/credentials.json`. |
| „Zu viele Fehlversuche“ | 60 s warten (Schutz gegen Raten). |
| Banner „Keine Verbindung zum Fahrzeug“ | WLAN-Abriss oder Dienst gestoppt. Das Backend stoppt das Fahrzeug selbsttätig. Nach Wiederverbindung Fehler quittieren und neu freigeben. |
| „Anmeldung abgelaufen“ | Token abgelaufen (`AWC_TOKEN_TTL_HOURS`) oder PIN/Passwort geändert → neu anmelden. |
| WebSocket Code 4004 | Seite über eine andere Adresse geöffnet als der WebSocket (z. B. Proxy) → `AWC_ALLOWED_ORIGINS` setzen. |
| WebSocket Code 4003 | Zu viele Geräte (`safety.max_sessions`). |
| Bedienelemente grau „Nur Beobachter“ | Anderes Gerät steuert → „Steuerung übernehmen“ (nur im Stillstand). |
| Gas reagiert nicht | Motoren gesperrt? Neutralverriegelung (Gas loslassen)? Fehlerbanner beachten. Profil im Gerät stimmt nicht (kurz nach Profilwechsel). |
| Neigungssteuerung „benötigt HTTPS“ | TLS einrichten (installation.md, Abschnitt 5). |
| Neigung „Keine Sensordaten“ | Gerät ohne Sensor (Desktop) oder Berechtigung verweigert (iOS: Safari-Einstellungen → Bewegungs- & Ausrichtungszugriff). |
| Lenkung zieht zur Seite | Neutrallage kalibrieren (Fahransicht → Kalibrieren). |

## Fehlercodes

Ausführliche Beschreibung und Abhilfe in der App unter **Diagnose → Fehlercodes**. Kurzüberblick:

| Code | Bedeutung | Erste Maßnahme |
|---|---|---|
| E001 | Kein Controller verbunden | Versorgung, Hauptschalter, Kabel, Ports |
| E002 | Nur ein Controller | Ausgefallene Seite prüfen |
| E003 | Kommunikationsfehler | Masse, Baudrate, Pegel, Störungen |
| E004 | Ungültige Messdaten | Odometrie-Einstellung, Firmware-Konfiguration |
| E005 | Übertemperatur | Abkühlen lassen |
| E006 | Akku kritisch | Laden |
| E007 | Verbindungsverlust | WLAN prüfen, quittieren, neu freigeben |
| E008 | Watchdog | Systemlast, Unterspannung (Systemansicht) |
| E009 | Hardware nicht initialisiert | Checkliste in der Systemansicht |
| E010 | Not-Aus aktiv | Ursache klären, zurücksetzen |
| E011 | Konfiguration ungültig | Einstellungen prüfen und speichern |
| W012 | Steuerbefehl veraltet | Gas loslassen; WLAN-Empfang prüfen |
| W014 | Geschwindigkeit nicht messbar | Controller-Rückmeldung prüfen |
| W015 | Inbetriebnahme-Modus | Test mit aufgebockten Rädern abschließen |

## Raspberry Pi

| Symptom | Lösung |
|---|---|
| Unterspannung in der Systemansicht | Stärkeren DC/DC-Wandler, kurze dicke Leitungen. Unterspannung verursacht Hänger (E008). |
| Hohe CPU-Last | Desktop deaktivieren (Lite-Image), Telemetrie-Rate senken (Einstellungen → Telemetrie). |
| Dienst startet nicht | `journalctl -u allwheel-control -b` – häufig: ungültige `allwheel.env` (PIN nicht numerisch, Passwort < 8 Zeichen). |
| `pip install` scheitert (32 Bit) | `sudo apt install build-essential python3-dev`, erneut ausführen. |
| Signalstärke „nicht verfügbar“ | Im AP-Modus wird `iw` benötigt; ggf. `AmbientCapabilities=CAP_NET_ADMIN` im Dienst ergänzen. |

## Serielle Schnittstellen / Controller

| Symptom | Lösung |
|---|---|
| `Schnittstelle … nicht verfügbar` | Gerät vorhanden? `ls -l /dev/ttyUSB*`; Benutzer in `dialout`; udev-Namen prüfen. |
| Keine gültigen Pakete | TX/RX vertauscht? GND verbunden? Baudrate 115200? Firmware mit `FEEDBACK_SERIAL_USARTx`? |
| Viele Prüfsummenfehler | `feedback_with_odometry` passend zur Firmware? Störungen durch Motorleitungen, Isolator verwenden. |
| Räder drehen falsch herum | Inbetriebnahme Schritt B (Invertierung/Tausch), nur aufgebockt testen. |
| Firmware piept dauerhaft (3 Töne) | Serial-Timeout: keine gültigen Befehle → Port/Verkabelung prüfen. |

## Daten zurücksetzen

```bash
sudo systemctl stop allwheel-control
sudo rm /var/lib/allwheel-control/allwheel.sqlite3*     # Einstellungen + Protokoll (sichere Standardwerte beim Start)
sudo systemctl start allwheel-control
```

Oder in der App: **Einstellungen → Administration → Auf sichere Standardwerte zurücksetzen**.
