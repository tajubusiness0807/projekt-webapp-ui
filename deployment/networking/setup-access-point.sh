#!/usr/bin/env bash
# Richtet den Raspberry Pi als WLAN-Access-Point ein (Raspberry Pi OS Bookworm, NetworkManager).
#
#   sudo deployment/networking/setup-access-point.sh "AllWheel" "SicheresPasswort123" [DE]
#
# Ergebnis: WLAN "AllWheel" (WPA2-PSK), Pi unter 192.168.4.1, DHCP für Handys/Tablets.
# Die Weboberfläche ist dann unter http://192.168.4.1:8080 erreichbar (mit TLS: https://192.168.4.1:8443).
# Ohne Internet-Weiterleitung – das Fahrzeugnetz bleibt isoliert.
set -euo pipefail
SSID=${1:?"SSID angeben"}
PSK=${2:?"WLAN-Passwort angeben (mindestens 12 Zeichen empfohlen)"}
COUNTRY=${3:-DE}
CON=allwheel-ap

if [[ $EUID -ne 0 ]]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi
if [[ ${#PSK} -lt 8 ]]; then echo "WPA2 verlangt mindestens 8 Zeichen." >&2; exit 1; fi
if ! command -v nmcli >/dev/null; then
  echo "NetworkManager (nmcli) nicht gefunden. Unter Bullseye die Dateien hostapd.conf/dnsmasq.conf nutzen (docs/installation.md)." >&2
  exit 1
fi

raspi-config nonint do_wifi_country "$COUNTRY" 2>/dev/null || iw reg set "$COUNTRY" || true
nmcli connection delete "$CON" >/dev/null 2>&1 || true
nmcli connection add type wifi ifname wlan0 con-name "$CON" autoconnect yes ssid "$SSID" \
  802-11-wireless.mode ap 802-11-wireless.band bg 802-11-wireless.channel 6 \
  wifi-sec.key-mgmt wpa-psk wifi-sec.proto rsn wifi-sec.pairwise ccmp wifi-sec.group ccmp wifi-sec.psk "$PSK" \
  ipv4.method shared ipv4.addresses 192.168.4.1/24 ipv6.method disabled
# Energiesparen des WLAN-Chips abschalten (verhindert Latenzspitzen)
nmcli connection modify "$CON" 802-11-wireless.powersave 2
nmcli connection up "$CON"
echo "Access Point aktiv: SSID \"$SSID\", Adresse 192.168.4.1"
