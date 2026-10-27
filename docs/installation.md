# Installation

Kurzfassung: Frontend auf dem Entwicklungsrechner bauen → Projekt auf den Pi kopieren →
`sudo deployment/scripts/install.sh` → Access Point einrichten → im Handy-Browser öffnen.

## 1. Entwicklungsrechner (Linux, macOS, Windows/WSL)

Voraussetzungen: Python ≥ 3.11, Node.js ≥ 20, Git.

```bash
git clone <repository> allwheel-control && cd allwheel-control

# Backend
cd backend
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest              # 129 Tests ohne Hardware (+1 Hardwaretest, übersprungen)

# Frontend
cd ../frontend
npm ci
npm test                                # Logik-Tests (Vitest)
npm run build                           # erzeugt frontend/dist

# Starten (Simulation): Backend liefert das gebaute Frontend aus
cd ../backend
AWC_DRIVER_PIN=1234 AWC_ADMIN_PASSWORD=admin-entwicklung .venv/bin/python -m app
# → http://localhost:8080  (PIN 1234)
```

Mit Hot-Reload: `deployment/scripts/dev.sh` (Backend auf 8080, Vite auf 5173 mit Proxy).
Auf einem Handy im selben WLAN: `http://<IP-des-Rechners>:8080`.

Optional per Docker: `docker compose up --build` → `http://localhost:8080`.

## 2. Raspberry Pi vorbereiten

### Betriebssystem

| | Empfehlung |
|---|---|
| Image | **Raspberry Pi OS Lite (Bookworm)** – ohne Desktop spart ≈ 200 MB RAM |
| 32 oder 64 Bit | **64 Bit** (aarch64) empfohlen. 32 Bit (armv7l) wird unterstützt: Für das einzige kompilierte Paket (pydantic-core) gibt es armv7l-Wheels auf PyPI (geprüft). Auf echter Pi-Hardware wurden beide Varianten im Rahmen dieser Entwicklung **nicht** getestet. |
| Python | Bookworm bringt Python 3.11 mit (erforderlich: ≥ 3.11) |
| SD-Karte | Markenkarte (A1/A2), ≥ 16 GB |

Mit dem Raspberry Pi Imager: Hostname (z. B. `allwheel`), Benutzer, SSH aktivieren, WLAN-Land setzen.

Unterschiede 32/64 Bit:
* 64 Bit: `uname -m` → `aarch64`; pip lädt manylinux-aarch64-Wheels.
* 32 Bit: `uname -m` → `armv7l`; pip nutzt armv7l-Wheels bzw. piwheels.org (in Raspberry Pi OS vorkonfiguriert).
  Sollte ein Paket kompiliert werden müssen, vorher `sudo apt install build-essential python3-dev`.
* Node.js für einen Frontend-Build **auf** dem Pi ist auf 32 Bit nur eingeschränkt verfügbar – das Frontend
  daher auf dem Entwicklungsrechner bauen (empfohlen für beide Varianten wegen 1 GB RAM).

### Ältere Systeme (Bullseye)

Bullseye hat Python 3.9 – zu alt. Entweder auf Bookworm aktualisieren (empfohlen) oder Docker verwenden.

## 3. Installation auf dem Pi

```bash
# Auf dem Entwicklungsrechner:
deployment/scripts/build-frontend.sh
deployment/scripts/deploy-to-pi.sh pi@allwheel.local      # rsync + install.sh per SSH

# … oder manuell: Projektordner (mit frontend/dist) auf den Pi kopieren, dann dort:
sudo deployment/scripts/install.sh
```

`install.sh` erledigt:
* Pakete `python3-venv`, `iw`, `rsync`
* Systembenutzer `allwheel` (Gruppe `dialout` für serielle Schnittstellen)
* Programm nach `/opt/allwheel-control`, virtuelle Umgebung `/opt/allwheel-control/venv`
* Daten nach `/var/lib/allwheel-control` (SQLite, Schlüssel, ggf. erzeugte Zugangsdaten)
* Konfiguration `/etc/allwheel-control/allwheel.env` (aus `.env.example`, Rechte 0640)
* systemd-Dienst `allwheel-control` (aktiviert, gestartet)

### Konfiguration

```bash
sudo nano /etc/allwheel-control/allwheel.env
#   AWC_DRIVER_PIN=482913
#   AWC_ADMIN_PASSWORD_HASH=…   (erzeugen: cd /opt/allwheel-control/backend && ../venv/bin/python -m app.utils.hash_password)
sudo systemctl restart allwheel-control
```

Ohne PIN/Passwort werden zufällige Werte erzeugt: `sudo cat /var/lib/allwheel-control/credentials.json`.

## 4. Netzwerk

### Pi als Access Point (empfohlen, Bookworm/NetworkManager)

```bash
sudo deployment/networking/setup-access-point.sh "AllWheel" "EinLangesWlanPasswort" DE
```

WLAN „AllWheel“, Pi unter **192.168.4.1**, DHCP für Handys, kein Internet-Routing. Energiesparmodus des
WLAN-Chips wird abgeschaltet (weniger Latenzspitzen).

Bullseye/ohne NetworkManager: `hostapd.conf`, `dnsmasq.conf`, `dhcpcd.conf.snippet` aus
`deployment/networking/` verwenden (`sudo apt install hostapd dnsmasq`).

### Optional: vorhandenes WLAN

```bash
sudo deployment/networking/setup-client-wifi.sh "MeinWLAN" "Passwort"
```

Dann Firewall nutzen (`deployment/networking/nftables-allwheel.conf`, eigenes Netz eintragen).
**Die Oberfläche niemals per Portweiterleitung aus dem Internet erreichbar machen.**

## 5. HTTPS (für die Neigungssteuerung)

Browser geben Bewegungssensoren nur über HTTPS frei.

```bash
sudo deployment/scripts/generate-cert.sh 192.168.4.1 allwheel.local
sudo nano /etc/allwheel-control/allwheel.env
#   AWC_TLS_CERTFILE=/etc/allwheel-control/tls/cert.pem
#   AWC_TLS_KEYFILE=/etc/allwheel-control/tls/key.pem
#   AWC_PORT=8443
sudo systemctl restart allwheel-control
```

Auf dem Handy `https://192.168.4.1:8443` öffnen und die Zertifikatswarnung einmalig akzeptieren
(oder `cert.pem` auf dem Gerät als vertrauenswürdig installieren). iOS fragt beim Aktivieren der
Neigungssteuerung zusätzlich nach der Berechtigung für Bewegungssensoren.

## 6. Bedienung vom Handy

1. Mit dem WLAN „AllWheel“ verbinden.
2. `http://192.168.4.1:8080` (bzw. `https://…:8443`) öffnen; optional „Zum Startbildschirm hinzufügen“
   (Vollbild, Querformat empfohlen).
3. PIN eingeben → **Steuerung übernehmen** → **Freigeben** gedrückt halten (0,8 s).
4. Gas (rechts) und Bremse (links) gedrückt halten. Loslassen = sofort 0.

## 7. Dienst verwalten

```bash
systemctl status allwheel-control
journalctl -u allwheel-control -f        # Protokoll live
sudo systemctl restart allwheel-control  # z. B. nach Hardware-Einstellungen
sudo systemctl disable --now allwheel-control
```

Nach einem Neustart des Pi startet der Dienst automatisch – **die Motoren bleiben gesperrt**, bis ein
Fahrer sie freigibt.

## 8. Aktualisieren

```bash
# Entwicklungsrechner
git pull && deployment/scripts/build-frontend.sh && deployment/scripts/deploy-to-pi.sh pi@allwheel.local
# oder auf dem Pi im neuen Projektordner
sudo deployment/scripts/update.sh
```

Einstellungen (versioniert in SQLite), Zugangsdaten und Betriebsstunden bleiben erhalten.

## 9. Fehlerbehebung

Siehe [troubleshooting.md](troubleshooting.md).
