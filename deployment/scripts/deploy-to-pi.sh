#!/usr/bin/env bash
# Überträgt das Projekt vom Entwicklungsrechner auf den Pi und installiert/aktualisiert es dort.
#   deployment/scripts/deploy-to-pi.sh pi@192.168.4.1
# Voraussetzungen: SSH-Zugang zum Pi, rsync auf beiden Seiten, Frontend lokal gebaut.
set -euo pipefail
TARGET=${1:?"Ziel angeben, z. B. pi@192.168.4.1"}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ ! -f "$ROOT/frontend/dist/index.html" ]]; then
  echo "frontend/dist fehlt – zuerst deployment/scripts/build-frontend.sh ausführen." >&2
  exit 1
fi
rsync -az --delete \
  --exclude '.git' --exclude 'node_modules' --exclude '.venv' --exclude 'backend/data' \
  --exclude '__pycache__' --exclude '.pytest_cache' \
  "$ROOT"/ "$TARGET":/tmp/allwheel-control-src/
ssh -t "$TARGET" "sudo /tmp/allwheel-control-src/deployment/scripts/install.sh"
