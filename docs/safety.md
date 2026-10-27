# Sicherheitskonzept

> **Wichtig:** Ein Raspberry Pi mit Linux und eine Web-App sind **kein Echtzeit-Sicherheitssystem**.
> Die Software verringert Risiken, ersetzt aber keinen unabhängigen **Hardware-Not-Aus**, keine
> Sicherungen und keine sorgfältige Inbetriebnahme. Das Fahrzeug darf nur mit einer Schaltung betrieben
> werden, die die Antriebsleistung unabhängig von Pi und Software trennen kann.

## 1. Schutzebenen

| Ebene | Wirkung | Unabhängig von der App? |
|---|---|---|
| Hardware-Not-Aus / Hauptschalter | Trennt die Antriebsleistung (Akku → Controller) | **ja** – Pflicht |
| Sicherungen, BMS | Überstrom, Kurzschluss, Tiefentladung | ja |
| Firmware-Timeout im Controller | FOC: ohne gültigen Befehl ≈ 0,8 s → `OPEN_MODE`, Leistung 0 | ja |
| systemd-Watchdog (5 s) | Hängt das Backend, wird es neu gestartet – danach gesperrt | teilweise |
| LoopSupervisor-Thread | Hängt die Regelschleife > 500 ms: Nullbefehl direkt an die Controller | teilweise |
| Backend-Watchdog | Befehle, Verbindung, Controller, Messdaten, Akku, Temperatur | nein |
| Frontend-Totmann | Lease, Loslassen, Fokusverlust, JS-Fehler → 0 | nein |

**Abschalten ist nicht Bremsen.** Wird die Antriebsleistung getrennt oder der Befehl auf 0 gesetzt, rollt
das Fahrzeug je nach Firmware-Regelmodus frei aus oder wird elektrisch verzögert. Ein kontrolliertes
Bremsen ist nur mit einer **verifizierten** Bremsmethode gegeben (siehe `hardware.md`). Die Oberfläche
zeigt das ehrlich an („Nur Antrieb aus – keine verifizierte Bremse“).

## 2. Zustandsautomat

| Zustand | Bedeutung | Fahrbefehle |
|---|---|---|
| `initializing` | Start, Prüfung von Konfiguration und Antrieb | gesperrt |
| `locked` | Bereit, Motoren gesperrt | gesperrt (Nullbefehle) |
| `armed` | Vom Fahrer bewusst freigegeben (0,8 s halten) | erlaubt, begrenzt |
| `fault` | Kritischer Fehler aktiv oder noch nicht quittiert | gesperrt, sicherer Stopp |
| `emergency_stop` | Software-Not-Aus | gesperrt, sicherer Stopp |

Freigabe nur, wenn: Steuerungsbesitzer, kein kritischer Fehler, kein Not-Aus, Gas losgelassen,
beide Controller mit aktueller Rückmeldung, Geschwindigkeit messbar und Stillstand, Antriebsmodus verfügbar.

**Keine automatische Freigabe** – weder beim Start, nach einem Neustart, nach Wiederverbindung noch
nach dem Quittieren oder Zurücksetzen des Not-Aus.

## 3. Reaktionen auf Fehler

| Ereignis | Erkennung | Reaktion |
|---|---|---|
| Finger vom Pedal / Touch abgebrochen | `pointerup`/`pointercancel`/`lostpointercapture` | Gas sofort 0 |
| Pedal-Komponente hängt/abgestürzt | Lease nicht erneuert (250 ms) | Gas 0 |
| App im Hintergrund, Fokus verloren | `visibilitychange`, `blur`, `pagehide` | Alle Eingaben 0, Pedale müssen neu gedrückt werden |
| JavaScript-Fehler | `error`, `unhandledrejection`, ErrorBoundary | Alle Eingaben 0 |
| Fahrbefehle bleiben aus | > 300 ms (`command_timeout_ms`) | Neutral + **Neutralverriegelung** (W012): erst nach Loslassen wieder Gas |
| Verzögert zugestellte Befehle | Alter > 400 ms (`max_command_age_ms`) | Verworfen |
| Verbindung des Steuergeräts weg | WebSocket geschlossen oder > 1 s still | E007, Sperre, sicherer Stopp, keine Wiederaufnahme |
| Ein Controller ohne Rückmeldung | > 500 ms | E002, gesamtes Fahrzeug gesperrt |
| Beide Controller ohne Rückmeldung | > 500 ms | E001 |
| Prüfsummen-/Schreibfehler gehäuft | > 10 in 2 s | E003 |
| Unplausible Messwerte | Grenzen in `telemetry/aggregator.py` | E004, Werte verworfen |
| Übertemperatur | ≥ kritische Schwelle | E005; ab Warnschwelle Leistungsreduzierung (W005) |
| Akku kritisch | < kritische Spannung für 2 s | E006; ab Warnschwelle optionale Reduzierung (W006) |
| Regelschleife zu langsam / hängt | Zyklus > 500 ms / Supervisor | E008 |
| Hardware angefordert, aber nicht freigegeben | Checkliste | E009, kein Antrieb |
| Gespeicherte Konfiguration ungültig | Validierung beim Laden | E011, sichere Standardwerte |
| Geschwindigkeit nicht messbar | Messwert nicht aktuell | W014, Gas gesperrt (Grenze nicht überwachbar) |
| Zweites Gerät will steuern | `claim_control` | Abgelehnt; Übernahme nur im Stillstand, dann Sperre |

## 4. Grenzwerte

Alle Werte sind im Backend validiert (Pydantic) und werden zur Laufzeit erneut begrenzt:

* Profilwerte ≤ absolute Grenzen (`safety.absolute_max_*`), Sport kann sie nicht überschreiten.
* Rückwärts: eigene Grenzen (Standard 4 km/h, 35 % Gas), Richtungswechsel nur im Stillstand.
* Inbetriebnahme-Modus (Hardware ohne bestätigten Test mit aufgebockten Rädern): max. 15 % Gas, 3 km/h.
* Lenkung ändert nur die Seitenverteilung, kein Drehen auf der Stelle ohne Gas.
* Achsgewichtung: Allrad 20–80 %, Custom 0–100 %; ungleiche Achsen nur, wenn der Controller-Regelmodus das erlaubt.
* Raten: max. 40 Nachrichten/s je Sitzung, max. 8 Sitzungen.
* Rohbefehl an die Controller: `max_command` (Standard 300 von ±1000).

Die Standard-Grenzwerte sind **Startwerte, keine universell gültigen Sicherheitswerte**. Sie müssen für das
konkrete Fahrzeug (Gewicht, Räder, Akku, Fahrer, Gelände) festgelegt werden.

## 5. Zugriffsschutz

* WLAN: WPA2-Access-Point mit eigenem Passwort; kein Internet-Routing; Firewall-Beispiel `deployment/networking/nftables-allwheel.conf`.
* Anmeldung: Fahrer-PIN, Administrator-Passwort (optional als PBKDF2-Hash), HMAC-signierte Tokens mit Ablauf.
* Fehlversuche: 5 pro Minute je IP, danach 60 s Sperre.
* WebSocket: Origin-Prüfung gegen Cross-Site-WebSocket-Hijacking, Hello mit Token innerhalb 5 s.
* Rechtetrennung: Fahrer ändert Fahreinstellungen (nur als Steuerungsbesitzer); Sicherheitsgrenzen, Akku,
  Temperatur, Hardware und Controller nur mit Administrator-Token.
* TLS optional (selbstsigniert) – erforderlich für Bewegungssensoren im Browser.
* Gespeichert werden keine Passwörter im Klartext außer selbst erzeugten Zugangsdaten in einer Datei mit
  Rechten 0600; das Protokoll enthält keine Zugangsdaten. MAC-Adressen werden nicht gespeichert.

## 6. Was nur mit sicher aufgebauter Hardware geprüft werden kann

Siehe [testing.md](testing.md) und die Inbetriebnahme in [hardware.md](hardware.md). Insbesondere:
Drehrichtungen, Firmware-Timeout, Bremsverhalten, Achsunabhängigkeit, Temperatur- und Spannungsmessung,
Wirksamkeit des Hardware-Not-Aus.
