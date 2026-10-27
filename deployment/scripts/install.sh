#!/usr/bin/env bash
# Installation von AllWheel Control auf dem Raspberry Pi (Raspberry Pi OS Bookworm/Bullseye, 32 oder 64 Bit).
#
# Aufruf im entpackten Projektordner auf dem Pi:
#   sudo deployment/scripts/install.sh
#
# Voraussetzung: frontend/dist wurde auf einem Entwicklungsrechner gebaut (npm run build) und mitkopiert –
# oder es wird hier gebaut (benötigt Node.js ≥ 20, dauert auf dem Pi 3B mehrere Minuten).
# Das Skript ist idempotent und kann für Aktualisierungen erneut ausgeführt werden.
set -euo pipefail

APP_DIR=/opt/allwheel-control
DATA_DIR=/var/lib/allwheel-control
CONF_DIR=/etc/allwheel-control
SERVICE=allwheel-control
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte mit sudo ausführen." >&2
  exit 1
fi

echo "==> Systempakete"
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip iw rsync >/dev/null

PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'; then
  echo "Python $PY_VER gefunden – benötigt wird 3.11 oder neuer (Raspberry Pi OS Bookworm)." >&2
  echo "Unter Bullseye siehe docs/installation.md, Abschnitt „Ältere Systeme“." >&2
  exit 1
fi
echo "    Python $PY_VER, Architektur $(uname -m)"

echo "==> Benutzer und Verzeichnisse"
id -u allwheel >/dev/null 2>&1 || useradd --system --home "$DATA_DIR" --shell /usr/sbin/nologin allwheel
usermod -a -G dialout allwheel
install -d -o allwheel -g allwheel -m 0750 "$DATA_DIR"
install -d -o root -g allwheel -m 0750 "$CONF_DIR"
install -d -m 0755 "$APP_DIR"

echo "==> Anwendung nach $APP_DIR kopieren"
rsync -a --delete \
  --filter='P /venv/' --filter='P /frontend/dist/' --filter='P /frontend/node_modules/' \
  --exclude '.git' --exclude 'node_modules' --exclude '.venv' --exclude '/venv' \
  --exclude 'backend/data' --exclude '__pycache__' --exclude '.pytest_cache' \
  "$SRC_DIR"/ "$APP_DIR"/

if [[ ! -f "$APP_DIR/frontend/dist/index.html" ]]; then
  if command -v npm >/dev/null 2>&1; then
    echo "==> Frontend wird auf dem Pi gebaut (kann einige Minuten dauern)"
    (cd "$APP_DIR/frontend" && npm ci --no-audit --no-fund && npm run build)
  else
    echo "!! frontend/dist fehlt und npm ist nicht installiert." >&2
    echo "   Frontend auf dem Entwicklungsrechner bauen: deployment/scripts/build-frontend.sh" >&2
    exit 1
  fi
fi

echo "==> Python-Umgebung"
if [[ ! -x "$APP_DIR/venv/bin/python" ]]; then
  python3 -m venv "$APP_DIR/venv"
fi
# piwheels liefert vorgebaute Pakete für 32-Bit-ARM; auf 64 Bit kommen die Wheels von PyPI.
"$APP_DIR/venv/bin/pip" install -q --upgrade pip
"$APP_DIR/venv/bin/pip" install -q -r "$APP_DIR/backend/requirements.txt"

echo "==> Konfiguration"
if [[ ! -f "$CONF_DIR/allwheel.env" ]]; then
  install -o root -g allwheel -m 0640 "$APP_DIR/.env.example" "$CONF_DIR/allwheel.env"
  echo "    $CONF_DIR/allwheel.env angelegt – PIN und Passwort dort setzen!"
fi

echo "==> systemd"
install -m 0644 "$APP_DIR/deployment/systemd/$SERVICE.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null
systemctl restart "$SERVICE"
sleep 3
systemctl --no-pager --lines=5 status "$SERVICE" || true

IP=$(hostname -I | awk '{print $1}')
echo
echo "Fertig. Aufruf im Browser: http://${IP:-<IP-des-Pi>}:8080"
echo "Zugangsdaten: in $CONF_DIR/allwheel.env (oder erzeugt in $DATA_DIR/credentials.json)."
echo "Die Anwendung startet im SIMULATIONSMODUS. Hardware siehe docs/hardware.md."
