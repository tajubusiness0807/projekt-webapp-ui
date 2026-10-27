#!/usr/bin/env bash
# Aktualisierung auf dem Raspberry Pi: neue Projektversion entpacken/kopieren und dieses Skript ausführen.
#   sudo deployment/scripts/update.sh
# Einstellungen (SQLite) und Zugangsdaten in /var/lib/allwheel-control bleiben erhalten.
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ $EUID -ne 0 ]]; then
  echo "Bitte mit sudo ausführen." >&2
  exit 1
fi
systemctl stop allwheel-control || true
"$SRC_DIR/deployment/scripts/install.sh"
