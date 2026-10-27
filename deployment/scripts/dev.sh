#!/usr/bin/env bash
# Entwicklungsumgebung starten: Backend (Simulation, Port 8080) und Vite-Dev-Server (Port 5173).
# Aufruf aus dem Projektordner: deployment/scripts/dev.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT/backend"
if [[ ! -x .venv/bin/python ]]; then
  python3 -m venv .venv
  .venv/bin/pip install -q -r requirements-dev.txt
fi
export AWC_DRIVER_PIN=${AWC_DRIVER_PIN:-1234}
export AWC_ADMIN_PASSWORD=${AWC_ADMIN_PASSWORD:-admin-entwicklung}
.venv/bin/python -m app &
BACKEND=$!
trap 'kill $BACKEND 2>/dev/null' EXIT
cd "$ROOT/frontend"
[[ -d node_modules ]] || npm ci --no-audit --no-fund
echo "Frontend: http://localhost:5173  (PIN $AWC_DRIVER_PIN, Admin $AWC_ADMIN_PASSWORD)"
npm run dev
