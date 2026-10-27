# Phase 1 – Analyse und Implementierungsplan

Dieses Dokument hält die Analyse fest, auf der die Implementierung von **AllWheel Control** beruht.
Es beschreibt die Auswertung der Referenzbilder, die technische Architektur, den Funktionsumfang,
alle noch unbekannten Hardwareparameter und den Implementierungsplan.

> Hinweis zu den Referenzbildern: Im Auftrag werden vier Referenzen genannt. Tatsächlich übergeben
> wurden **zwei** Bilder: (1) die reduzierte Fahransicht mit großem zentralen Tachometer und
> (2) die Übersicht mit Fahrmodi, Antriebs- und Leistungseinstellungen. Die kompakte Fahransicht mit
> Neigungssteuerung und der elektrische Schaltplan lagen nicht vor. Die Neigungsanzeige wurde deshalb
> im Stil der beiden vorhandenen Bilder gestaltet, und für die Hardware werden – wie gefordert –
> **keine** Pinbelegungen angenommen.

---

## 1. Designanalyse

### 1.1 Gemeinsame Designsprache (beide Bilder)

| Merkmal | Beobachtung | Umsetzung |
|---|---|---|
| Hintergrund | Nahezu schwarz mit dunkelblauem Stich (#05080f … #0a1220), leichte radiale Aufhellung hinter dem Tacho | CSS-Variablen `--bg-0 … --bg-3`, radialer Verlauf nur hinter Messinstrumenten |
| Karten | Abgerundet (≈ 14–18 px), 1 px Rahmen in gedämpftem Blau (#1b2a44), Fläche minimal heller als der Hintergrund | `.card` mit `border-color: var(--line)` und `background: var(--panel)` |
| Akzent | Cyan → Blau (#22d3ee → #2563eb) für Bögen, aktive Navigation und Auswahl | Tailwind-Farben `accent-*`, SVG-Verläufe |
| Positiv | Türkis/Grün (#10e0a8, #22c55e) für Gas, Eco, „Verbunden", Akku | `ok-*` Farbskala |
| Kritisch | Rot (#ef4444) für Bremse, Fehler, Not-Aus | `danger-*` Farbskala |
| Leuchteffekte | Weiche Glows an Bögen, Zeiger, Pedalrahmen | `filter: drop-shadow` sparsam, nur an aktiven Elementen |
| Typografie | Geometrische Grotesk, große Ziffern (Tacho ≈ 96 px), kleine graue Labels | Inter (lokal gebündelt), `tabular-nums` für Messwerte |
| Icons | Feine Linienicons (Lucide-Stil), eigene Symbole für Bremse und Achsen | `lucide-react` + eigene SVG-Icons |
| Kopfzeile | Logo + „AllWheel Control", grüner Punkt „Verbunden" mit IP, rechts WLAN, Akku, Zahnrad | `Header`-Komponente, Status aus dem Backend |
| Statusleiste unten | Gleichmäßig verteilte Kennzahlen mit Icon, Label, Wert, Trennlinien | `StatusBar`-Komponente mit Messwertzustand |

### 1.2 Bild 1 – Fahransicht

* **Kopfzeile:** Logo, Titel, Verbindungsstatus mit IP (192.168.4.1 = typische Access-Point-Adresse), Akku, Einstellungen.
* **Obere Karten:** links „Modus – Sport ›" (Tacho-Icon), rechts „Antrieb – Allrad ›" (Achs-Icon). Beide öffnen eine Auswahl.
* **Zentraler Tacho:** offener Bogen (≈ 240°) von 0 links unten bis 60 rechts unten, Haupt­striche alle 10 km/h, feine Zwischenstriche, Cyan→Blau-Verlauf, leuchtender Zeiger, große Ziffer „13" mit „km/h".
* **Unter dem Tacho:** Spannung (Blitz), Signal (Antenne + Balken), Batterie.
* **Bremse links:** hohe, rot umrandete Fläche, Bremsen-Warnsymbol „(!)", Schrift „Bremse", Doppelpfeil nach unten.
* **Gas rechts:** hohe, türkis umrandete Fläche, Doppelpfeil nach oben, „Gas", Pfeil nach oben.
* **Statusleiste:** Batterie, Controller-Temperatur, Verbindung („Stark" in Grün).

**Verbesserungen für die Bedienbarkeit (bewusst ergänzt):**
1. **Motorfreigabe** als klarer Schalter unter der Tacho-Ziffer – die Freigabe darf nie automatisch erfolgen.
2. **Not-Aus** dauerhaft sichtbar in der Kopfzeile.
3. **SIMULATION**-Kennzeichnung in der Kopfzeile, solange keine echte Hardware aktiv ist.
4. Füllstand und Prozentwert im Gaspedal (angeforderte Gasstellung) sowie Bremszustand im Bremspedal
   (angefordert / bestätigt / nicht verifiziert).
5. Lenkzeile unter dem Tacho: Neigungsanzeige oder – als Rückfallebene – selbstzentrierender Lenkregler.
6. Fahrtrichtung V/R (nur im Stillstand umschaltbar).

### 1.3 Bild 2 – Übersicht / Dashboard

* **Seitenleiste:** Dashboard (aktiv, blauer Balken), Fahrmodi, Einstellungen, Verbindung, System, Version unten.
* **Großkarte oben:** Tacho (0–100), Draufsicht des Fahrzeugs mit „4WD" und leuchtenden Rädern, Drehzahlmesser (0–5000, Grün→Blau).
* **Fahrmodus-Karte:** Liste Allrad/FWD/RWD (Radio, aktiver Eintrag blau mit Haken) und Kacheln Eco/Normal/Sport/Custom (Eco grün mit Haken).
* **Steuerung:** Joystick, STOP, „+ Schneller", „− Langsamer".
* **Leistung:** Vorne 60 % / Hinten 40 % mit Schieberegler und −/+.
* **Weitere Einstellungen:** Lenkempfindlichkeit, Max. Geschwindigkeit, Beschleunigung, Batterie-Schutz, Autom. Stopp bei Verbindungsausfall.
* **Statusleiste:** Batterie (78 %, 21,6 V / 28,0 V), Temperatur (Motor/Controller), Fahrzeit, Modus, Signal (−42 dBm), System OK.

**Fachliche Anpassungen:**
* „Autom. Stopp bei Verbindungsausfall" ist eine Sicherheitsfunktion und wird als **immer aktiv (gesperrt)** angezeigt – sie lässt sich nicht abschalten.
* „Batterie-Schutz" schaltet nur die *sanfte Leistungsreduzierung*; die kritische Unterspannungsabschaltung bleibt immer aktiv.
* Die Drehzahlskala im Bild (5000 RPM) ist für Radnabenmotoren unrealistisch (typisch < 1000 U/min). Skalen sind daher konfigurierbar (Standard 1000 U/min).
* „Leistung Vorne/Hinten" wird als **angeforderte Gewichtung** bezeichnet, nicht als tatsächliche Leistung.
* Die Draufsicht zeigt die vom Backend **bestätigte** Anforderung je Rad, nicht den lokal gesendeten Befehl.

### 1.4 Ansichten (Umsetzung)

| Route | Ansicht | Quelle |
|---|---|---|
| `#/fahren` | Fahransicht (Cockpit) | Bild 1 |
| `#/dashboard` | Übersicht | Bild 2 |
| `#/fahrmodi` | Fahrprofile + Antriebsmodi | Bild 2 (Fahrmodus-Karte, erweitert) |
| `#/leistung` | Leistungsverteilung vorne/hinten | Bild 2 (Leistung-Karte, erweitert) |
| `#/einstellungen` | Neigung, Anzeige, Admin-Einstellungen | Bild 2 (Weitere Einstellungen, erweitert) |
| `#/verbindung` | Verbindung, Sitzungen, Controller-Kommunikation | Seitenleiste Bild 2 |
| `#/diagnose` | Fehlercodes, Ereignisprotokoll | Anforderung 16 |
| `#/system` | Betriebsart, Hardware-Checkliste, Raspberry-Pi-Zustand | Seitenleiste Bild 2 |

Responsives Verhalten: Tablet quer = Layout wie in den Bildern; Smartphone quer = Fahransicht mit
Pedalen an den Bildschirmrändern (Daumen); Smartphone hoch = Pedale unten nebeneinander, Navigation als Leiste unten.

---

## 2. Technische Architektur

```
Smartphone/Tablet (Browser)
  React + TypeScript (Vite-Build, lokal ausgeliefert)
    ├─ Eingaben: Pedale (Totmann), Joystick, Lenkregler, Neigung, Tastatur
    ├─ Sender: 20 Hz Fahranforderung mit Sequenznummer + Zeitstempel
    └─ Anzeige: ausschließlich bestätigte Zustände/Messwerte vom Backend
        │  WebSocket (ws/wss)  +  REST (Login, Einstellungen, Diagnose)
        ▼
Raspberry Pi 3B – FastAPI (ein Prozess, asyncio)
  ├─ websocket/   Authentifizierung, Nachrichtenvalidierung, Sitzungen, Broadcast (10 Hz)
  ├─ safety/      Befehlsprüfung (Sequenz, Alter, Rate), Zustandsautomat, Watchdog, Loop-Supervisor-Thread
  ├─ services/    Fahrlogik (Profile, Rampen, Begrenzungen, Achsverteilung, Lenkmischung), Fahrzeugdienst (25 Hz)
  ├─ controllers/ MotorControllerInterface → Simulation | FOC-USART (seriell) ; Koordinator für 2 Controller
  ├─ simulation/  Fahrzeugphysik, Akku-/Temperaturmodell, Fehlerinjektion
  ├─ telemetry/   Messwerte mit Zustand (gültig/veraltet/nicht verfügbar/simuliert), WLAN, Systemdaten
  └─ storage/     SQLite: versionierte Einstellungen, Ereignisprotokoll, Betriebsstunden
        │  UART 115200 Baud (nur nach expliziter Konfiguration)
        ▼
2 × Hoverboard-Mainboard (Firmware erst zu identifizieren) → 4 Nabenmotoren
```

**Schichtprinzip:** Kein Befehl gelangt ungeprüft zu einem Controller. Jede Fahranforderung durchläuft
`CommandGate` (Format, Sequenz, Alter, Rate, Widerspruchsfreiheit) → `SafetyManager` (Zustand, Fehler,
Freigabe) → `DriveComputer` (Profil- und Sicherheitsgrenzen, Rampen) → `DrivetrainCoordinator`
(Achszuordnung, Fähigkeiten) → Adapter.

**Unabhängige Schutzebenen** (Software allein reicht nicht):
1. Hardware-Not-Aus / Hauptschalter (muss die Antriebsleistung unabhängig trennen).
2. Firmware-Timeout im Controller (bei FOC: `SERIAL_TIMEOUT` ≈ 0,8 s → `OPEN_MODE`, Leistung 0).
3. systemd-Watchdog (Neustart des Dienstes bei Hänger, danach gesperrt).
4. Loop-Supervisor-Thread im Backend (sendet Nullbefehle, wenn die Regelschleife hängt).
5. Watchdog/Timeouts im Backend, Totmann im Frontend.

---

## 3. Funktionsliste

**Fahren:** Totmann-Gas (proportional), Bremse mit Zustandsunterscheidung, Lenkung (Regler, Joystick,
Neigung, Tastatur), Fahrtrichtung V/R im Stillstand, Motorfreigabe/-sperre, Not-Aus und Rücksetzen.

**Fahrprofile:** Eco, Normal, Sport, Custom mit max. Gasstellung, Beschleunigungsrampe,
Verzögerungsanforderung, Lenkempfindlichkeit, Totzone, max. Geschwindigkeit, Achs- und Seitenbegrenzung.

**Antriebsmodi:** Allrad, FWD, RWD, Custom; Verfügbarkeit abhängig von Controller-Fähigkeiten.

**Leistungsverteilung:** Gewichtung vorne/hinten mit Voreinstellungen (100/0, 0/100, 50/50, frei),
dokumentierte Umrechnung, Anzeige von *Gewichtung*, *begrenzter Motoranforderung* und *gemessener Leistung* (nur bei Messdaten).

**Neigung:** Kalibrierung, Empfindlichkeit, max. Lenkanforderung, Totzone, Glättung, Invertierung,
optionale Vor/Zurück-Funktion (Standard aus), iOS-Berechtigung, automatischer Rückfall.

**Telemetrie:** Geschwindigkeit, Drehzahl, Akkuspannung/-stand, Controller-/Motortemperatur, WLAN,
Latenz, Fahrmodus, Antrieb, Fahrzeit, Fehlerstatus – jeweils mit Zustand.

**Sicherheit:** Watchdog (Befehle, Verbindung, Controller, Messdaten, Regelschleife), Neutralverriegelung,
Verbindungsverlust → Sperre ohne Wiederaufnahme, Startsperre, Not-Aus, Grenzwerte, Fehlercodes.

**Zugriff:** PIN-Login für Fahrer, Passwort für Administration, signierte Tokens, Origin-Prüfung,
Sitzungsbegrenzung, eindeutiger Steuerungsbesitzer mit Übernahme nur im Stillstand.

**Betrieb:** Versionierte Einstellungen (SQLite), Zurücksetzen, Ereignisprotokoll, Diagnoseansicht,
systemd-Dienst, Access-Point-Skripte, optional TLS, optional Docker.

---

## 4. Unbekannte Hardwareparameter

Diese Werte müssen vor dem Hardwarebetrieb ermittelt und in den Einstellungen bestätigt werden.
Solange sie fehlen, bleibt der Hardwaremodus gesperrt (siehe `docs/hardware.md`).

| # | Parameter | Warum benötigt | Wo eintragen |
|---|---|---|---|
| 1 | Mainboard-Typ je Controller (Single-Board STM32F103RCT6/GD32F103RCT6, Split-Board, AT32 …) | Firmware-Kompatibilität | `hardware.controller_model` |
| 2 | Installierte Firmware und Version (z. B. hoverboard-firmware-hack-FOC, Commit) | Protokoll | `hardware.firmware`, `firmware_version` |
| 3 | Firmware-Variante und USART (VARIANT_USART, USART2 oder USART3) | Anschluss, Pegel | `hardware.firmware_variant_usart` |
| 4 | Regelmodus (VLT/SPD/TRQ) | Bremsverhalten, Achsverteilung | `hardware.firmware_control_mode` |
| 5 | Signalpegel der UART-Leitungen (3,3 V), Pegelwandler nötig? | Schutz des Raspberry Pi | `hardware.signal_levels_verified` |
| 6 | Serielle Schnittstellen (`/dev/serial0`, `/dev/ttyUSB0` …) und Zuordnung vorne/hinten | Achszuordnung | `hardware.controllers[].port`, `axle` |
| 7 | Odometrie-Felder im Feedback (ENABLE_ODOMETRY) | Paketlänge | `controllers[].feedback_with_odometry` |
| 8 | SPEED_/STEER_COEFFICIENT der Firmware | Umrechnung links/rechts | `controllers[].speed_coefficient`, `steer_coefficient` |
| 9 | Drehrichtungen (Befehl und Rückmeldung je Seite) | Richtige Fahrtrichtung | `controllers[].invert_*` |
| 10 | Raddurchmesser | Geschwindigkeit aus Drehzahl | `hardware.wheel_diameter_m` |
| 11 | Temperaturkalibrierung der Boards (TEMP_CAL_*) | Gültige Temperaturwerte | `hardware.temperature_calibrated` |
| 12 | Akkutyp, Zellzahl, Grenzspannungen, BMS-Abschaltung | Akkustand, Warnungen | `battery.*` |
| 13 | Verifizierte Bremsmethode | Bremsfunktion | `hardware.brake_method`, `brake_verified` |
| 14 | Unabhängige Ansteuerung beider Controller | Antriebsmodi FWD/RWD/Custom | `hardware.independent_axle_control` |
| 15 | Hardware-Not-Aus-Schaltung, Sicherungen, Hauptschalter | Unabhängige Schutzebene | Dokumentation (`docs/safety.md`) |
| 16 | Versorgung des Pi (DC/DC-Leistung, Unterspannung) | Stabilität | Systemansicht zeigt Unterspannungs-Flags |

---

## 5. Implementierungsplan

| Phase | Inhalt | Ergebnis |
|---|---|---|
| 1 | Analyse (dieses Dokument) | Plan, Parameterliste |
| 2 | Projektstruktur, Modelle, Konfiguration, SQLite, WebSocket, Simulationsadapter | Backend startbar |
| 3 | Frontend: Designsystem, alle Ansichten, Bedienelemente | UI mit echter Interaktion |
| 4 | Fahrlogik, Antriebsmodi, Verteilung, Grenzwerte, Watchdog, Fehlerzustände | Vollständige Steuerung in der Simulation |
| 5 | Automatisierte Tests (pytest, Vitest, Playwright-Smoke) | Grüne Testläufe |
| 6 | Hardwareadapter: FOC-USART-Codec (gegen Originalquellen geprüft), serieller Adapter, Koordinator, Freigabe-Checkliste | Vorbereitet, standardmäßig gesperrt |
| 7 | Deployment: systemd, Access Point, Skripte, TLS, Docker optional, Dokumentation | Installierbar auf Pi 3B |
| 8 | Abschlussprüfung: Start, Design-Screenshots, Tests, Ressourcen | Zusammenfassung |

### Geprüfte Protokollgrundlage (FOC-Firmware)

Das serielle Protokoll wurde gegen die Originalquellen von
[EFeru/hoverboard-firmware-hack-FOC](https://github.com/EFeru/hoverboard-firmware-hack-FOC)
(`Arduino/hoverserial/hoverserial.ino`, `Src/main.c`, `Src/util.c`, `Inc/config.h`) geprüft:

* Befehl: `uint16 start=0xABCD, int16 steer, int16 speed, uint16 checksum = start ^ steer ^ speed` (Little Endian, 8 Byte), Wertebereich ±1000.
* Rückmeldung: `start, cmd1, cmd2, speedR_meas, speedL_meas, [wheelR_cnt, wheelL_cnt], batVoltage, boardTemp, cmdLed, checksum` (18 bzw. 22 Byte), Prüfsumme = XOR aller Felder.
* Einheiten: Drehzahl in U/min, Spannung in V·100, Temperatur in °C·10 (nur nach Kalibrierung gültig).
* Mischer der Firmware: `R = speed·Kspeed − steer·Ksteer`, `L = speed·Kspeed + steer·Ksteer`.
* Firmware-Timeout: `SERIAL_TIMEOUT` 160 × 5 ms ≈ 0,8 s → `OPEN_MODE` (Leistung 0).

Die Kompatibilität des konkreten Mainboards mit dieser Firmware ist damit **nicht** belegt – sie muss
am realen Board geprüft werden (siehe `docs/hardware.md`).
