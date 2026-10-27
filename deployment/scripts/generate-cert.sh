#!/usr/bin/env bash
# Erzeugt ein selbstsigniertes TLS-Zertifikat für HTTPS/WSS (nötig für die Neigungssteuerung,
# da Browser Bewegungssensoren nur in sicheren Kontexten freigeben).
#   sudo deployment/scripts/generate-cert.sh 192.168.4.1 allwheel.local
# Danach in /etc/allwheel-control/allwheel.env setzen:
#   AWC_TLS_CERTFILE=/etc/allwheel-control/tls/cert.pem
#   AWC_TLS_KEYFILE=/etc/allwheel-control/tls/key.pem
#   AWC_PORT=8443
# Auf dem Handy die Zertifikatswarnung einmalig bestätigen (oder das Zertifikat installieren).
set -euo pipefail
IP=${1:-192.168.4.1}
NAME=${2:-allwheel.local}
DIR=${CERT_DIR:-/etc/allwheel-control/tls}
mkdir -p "$DIR"
openssl req -x509 -newkey rsa:2048 -nodes -days 1825 \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
  -subj "/CN=$NAME/O=AllWheel Control" \
  -addext "subjectAltName=IP:$IP,DNS:$NAME,DNS:localhost" >/dev/null 2>&1
if id -u allwheel >/dev/null 2>&1; then
  chown root:allwheel "$DIR" "$DIR"/*.pem
  chmod 0750 "$DIR"
  chmod 0640 "$DIR/key.pem"
  chmod 0644 "$DIR/cert.pem"
fi
echo "Zertifikat erstellt: $DIR/cert.pem (gültig 5 Jahre, SAN: IP $IP, $NAME)"
