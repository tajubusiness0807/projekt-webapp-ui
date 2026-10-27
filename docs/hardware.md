# Hardware und Inbetriebnahme

> Dieses Dokument enthält **keine erfundenen Pinbelegungen**. Die Referenzbilder sind Designvorlagen,
> keine Schaltpläne. Alle Anschlüsse müssen am konkreten Board anhand seiner Dokumentation bzw.
> durch Messung bestimmt werden.

## 1. Komponenten (voraussichtlich)

| Komponente | Hinweise |
|---|---|
| Raspberry Pi 3B | 1 GB RAM, eine vollwertige UART (PL011, standardmäßig für Bluetooth belegt) + Mini-UART |
| 2 × Hoverboard-Mainboard | Typ und Firmware **noch nicht identifiziert** |
| 4 × Hoverboard-Nabenmotor | je Mainboard zwei Motoren (links/rechts einer Achse) |
| Akku mit BMS | typ. 10S Li-Ion (36 V nominal, ≈ 42 V voll) – tatsächliche Werte eintragen |
| DC/DC-Wandler 5 V für den Pi | ausreichend dimensioniert (≥ 3 A), Unterspannung zeigt die Systemansicht |
| Sicherungen, Hauptschalter | je Controller abgesichert |
| **Hardware-Not-Aus** | muss die Antriebsleistung unabhängig von Pi und Software trennen |
| 2 × USB-UART-Adapter (empfohlen) | **3,3-V-Pegel**, z. B. CP2102/FT232 mit 3,3-V-Einstellung |

Empfehlung für zwei Controller: **zwei USB-UART-Adapter** (`/dev/ttyUSB0`, `/dev/ttyUSB1`) mit festen
Namen über udev (`deployment/udev/99-allwheel-serial.rules`). Der Mini-UART des Pi 3B ist taktabhängig
und für zwei unabhängige Verbindungen ungeeignet; die PL011-UART kann nach `dtoverlay=disable-bt`
für **einen** Controller genutzt werden.

## 2. Firmware-Kompatibilität prüfen

Der mitgelieferte Hardwareadapter unterstützt **ausschließlich** die Firmware
[hoverboard-firmware-hack-FOC](https://github.com/EFeru/hoverboard-firmware-hack-FOC) mit serieller
Steuerung (USART). Das Protokoll wurde anhand der Originalquellen implementiert und mit Unit-Tests
abgesichert (`backend/app/controllers/foc_protocol.py`):

| Element | Wert laut Originalquelle |
|---|---|
| Baudrate | 115200, 8N1 (`USART2_BAUD`/`USART3_BAUD`) |
| Befehl | `uint16 0xABCD, int16 steer, int16 speed, uint16 checksum (= start ^ steer ^ speed)` – 8 Byte, Little Endian |
| Wertebereich | ±1000 (`INPUT_MIN/INPUT_MAX`) |
| Rückmeldung | `start, cmd1, cmd2, speedR_meas, speedL_meas, [wheelR_cnt, wheelL_cnt], batVoltage, boardTemp, cmdLed, checksum` |
| Einheiten | Drehzahl U/min, Spannung V·100, Temperatur °C·10 |
| Rückmelde-Intervall | 10 ms |
| Mischer | `R = speed·Kspeed − steer·Ksteer`, `L = speed·Kspeed + steer·Ksteer` |
| Timeout | `SERIAL_TIMEOUT 160` × 5 ms ≈ 0,8 s → `OPEN_MODE` (Leistung 0) |

Vorgehen:

1. **Mainboard identifizieren**: Mikrocontroller ablesen (STM32F103RCT6, GD32F103RCT6 werden von der
   FOC-Firmware unterstützt; Split-Boards, AT32 u. a. benötigen andere Firmware → anderer Adapter).
2. Firmware nach Projektanleitung bauen und flashen (ST-Link). Für jede Achse ein Board.
   Relevante `config.h`-Optionen: `VARIANT_USART`, `CONTROL_SERIAL_USART3` und `FEEDBACK_SERIAL_USART3`
   (rechtes Sensorkabel, 5-V-tolerant) **oder** `USART2` (linkes Kabel, **nicht** 5-V-tolerant),
   `CTRL_MOD_REQ` (Regelmodus), ggf. `ENABLE_ODOMETRY`, `SPEED_COEFFICIENT`, `STEER_COEFFICIENT`.
3. Werte in **Einstellungen → Administration → Hardware/Controller** eintragen:
   Mainboard-Typ, Firmware, Version/Commit, Regelmodus, Odometrie, Koeffizienten.

> Laut Firmware-Projekt führen die Sensorkabel neben GND und den UART-Leitungen auch **12/15 V**.
> Diese Ader **niemals** mit Pi oder USB-UART-Adapter verbinden.

## 3. Signalpegel und Verdrahtung (Grundsätze)

* UART-Pegel der Mainboards: 3,3 V. Raspberry-Pi-GPIOs sind **nicht** 5-V-tolerant.
* Verbindung: Controller-TX → Adapter-RX, Controller-RX → Adapter-TX, **GND ↔ GND**. Nichts weiter.
* Empfohlen: galvanische Trennung (digitaler Isolator) wegen Motorströmen und Masseschleifen.
* UART-Leitungen kurz und getrennt von Motorphasen führen; Paketfehler zeigt die Verbindungsansicht.
* Die konkrete Zuordnung der Kabeladern ist am Board zu messen/nachzulesen – sie wird hier bewusst
  nicht angegeben.

## 4. Raspberry-Pi-Konfiguration

```bash
sudo raspi-config        # Interface Options → Serial Port: Login-Shell „Nein“, Hardware „Ja“
# nur wenn die GPIO-UART genutzt wird (Bookworm: /boot/firmware/config.txt, Bullseye: /boot/config.txt):
#   dtoverlay=disable-bt
sudo usermod -a -G dialout allwheel   # erledigt install.sh
ls -l /dev/serial* /dev/ttyUSB*
```

## 5. Freigabe-Checkliste (Hardwaremodus)

Der Hardwaremodus startet **nur**, wenn alle Punkte erfüllt sind (Systemansicht zeigt den Stand):

1. `AWC_HARDWARE_ENABLED=1` in `/etc/allwheel-control/allwheel.env`
2. Betriebsart „Hardware“ in den Einstellungen
3. Mainboard-Typ, Firmware (FOC) und Firmware-Version eingetragen
4. Firmware mit USART-Steuerung und -Feedback gebaut
5. Regelmodus bekannt
6. Protokoll am Controller geprüft (siehe Schritt A unten)
7. Signalpegel geprüft, 15-V-Ader nicht angeschlossen
8. Verkabelung, Sicherungen und Hardware-Not-Aus geprüft
9. Serielle Schnittstellen beider Controller gesetzt (verschieden)
10. Raddurchmesser nachgemessen
11. pyserial installiert

Ist ein Punkt offen, startet das Backend **ohne Antrieb** mit Fehler E009 (kein stiller Rückfall in die
Simulation). Änderungen an Hardware-Einstellungen wirken erst nach `sudo systemctl restart allwheel-control`.

## 6. Inbetriebnahme – Schritt für Schritt (Räder aufgebockt!)

Bis „Test mit aufgebockten Rädern bestanden“ bestätigt ist, läuft der **Inbetriebnahme-Modus**:
max. 15 % Gas, max. 3 km/h, Warnung W015.

**A – Kommunikation ohne Motorbewegung**
1. Antriebsleistung über Hauptschalter, Not-Aus griffbereit.
2. Optional automatisiert: `AWC_HARDWARE_TESTS=1 AWC_TEST_PORT=/dev/ttyUSB0 pytest tests/hardware -m hardware`
   – sendet nur Nullbefehle und prüft gültige Rückmeldungen.
3. In der Verbindungsansicht: „Pakete gültig“ steigt, „fehlerhaft“ bleibt nahe 0, Spannung plausibel.

**B – Drehrichtung und Zuordnung**
1. Fahrzeug sicher aufbocken (alle vier Räder frei).
2. Motoren freigeben, Gas minimal. Prüfen: Drehen alle Räder **vorwärts**? Ist „vorne“ wirklich vorne?
3. Abweichungen mit `invert_left/right_command`, `swap_sides` und der Achszuordnung korrigieren.
4. Rückmeldung prüfen: positive Drehzahl bei Vorwärtsfahrt, sonst `invert_*_feedback`.
5. Lenkung: Lenkanforderung rechts → rechte Seite langsamer. Bei `STEER_COEFFICIENT = 0` ist keine
   Seitendifferenz möglich – Firmware anpassen.
6. Firmware-Timeout prüfen: Dienst stoppen (`systemctl stop allwheel-control`) während die Räder langsam
   drehen → Räder müssen nach ≈ 1 s stoppen (Signaltöne der Firmware).
7. Hardware-Not-Aus während Drehung betätigen → Antrieb muss sofort stromlos sein.

**C – Messwerte**
1. Raddurchmesser messen, eintragen, „nachgemessen“ bestätigen; Geschwindigkeitsanzeige mit Umdrehungen vergleichen.
2. Temperatur nur verwenden, wenn die Boards kalibriert sind (`TEMP_CAL_*`), dann „kalibriert“ bestätigen.
3. Akkuwerte (Zellzahl, Grenzen) passend zum BMS einstellen.

**D – Bremse (optional)**
* Ohne verifizierte Methode schaltet „Bremse“ nur den Antrieb ab (Anzeige „Nur Antrieb aus“).
* `voltage_mode_zero`: nur bei `CTRL_MOD_REQ = VLT_MODE`; Wirkung aufgebockt und dann bei Schrittgeschwindigkeit prüfen.
* `counter_torque`: nur bei `TRQ_MODE`; Gegenmoment entgegen der gemessenen Drehrichtung, im Stillstand 0.
* Erst nach Prüfung „Bremsmethode verifiziert“ setzen.

**E – Achsunabhängigkeit (FWD/RWD/Custom)**
* Nur verfügbar, wenn beide Controller getrennt angesteuert werden (eigene UART je Board) **und** der
  Regelmodus TRQ_MODE ist. Im Spannungs-/Drehzahlmodus würden sich ungleich angesteuerte Achsen
  gegenseitig bremsen – die App bietet dann nur Allrad 50/50 an.

**F – Abschluss**
* „Test mit aufgebockten Rädern bestanden“ bestätigen → Inbetriebnahme-Modus endet nach Neustart.
* Erste Fahrten im Profil Eco auf freier, ebener Fläche, Begleitperson am Not-Aus.

## 7. Noch benötigte Informationen

Siehe Tabelle „Unbekannte Hardwareparameter“ in [analysis.md](analysis.md#4-unbekannte-hardwareparameter).
Besonders: Mainboard-Typ, Firmware/Regelmodus, Akkudaten, Raddurchmesser, Bremsverhalten, Not-Aus-Schaltung.
