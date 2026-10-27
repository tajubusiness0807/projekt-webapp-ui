#!/usr/bin/env bash
# Optional: Pi mit einem vorhandenen WLAN verbinden (z. B. für Entwicklung/Updates).
#   sudo deployment/networking/setup-client-wifi.sh "MeinWLAN" "Passwort"
# Achtung: Im Client-Modus ist die Oberfläche für alle Geräte dieses WLANs erreichbar. Firewall-Regeln
# (nftables-allwheel.conf) verwenden und die Anwendung NIEMALS per Portweiterleitung ins Internet stellen.
set -euo pipefail
SSID=${1:?"SSID angeben"}
PSK=${2:?"Passwort angeben"}
if [[ $EUID -ne 0 ]]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi
nmcli connection down allwheel-ap >/dev/null 2>&1 || true
nmcli device wifi connect "$SSID" password "$PSK" ifname wlan0
nmcli connection modify "$SSID" 802-11-wireless.powersave 2 || true
echo "Verbunden mit \"$SSID\". IP: $(hostname -I | awk '{print $1}')"
echo "Zurück zum Access Point: sudo nmcli connection up allwheel-ap"
