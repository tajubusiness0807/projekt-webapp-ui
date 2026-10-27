#!/usr/bin/env bash
# Baut das Frontend auf dem Entwicklungsrechner (empfohlen – der Pi 3B hat nur 1 GB RAM).
# Ergebnis: frontend/dist (wird vom Backend ausgeliefert).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../frontend"
npm ci --no-audit --no-fund
npm run build
echo "Frontend gebaut: $(pwd)/dist"
