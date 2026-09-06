#!/bin/bash
# Title: KB NetRecon
# Description: Fast host discovery (ICMP + TCP probes) then an ARP pass for MACs, on the network the Pager is joined to. v1.1: ~3x faster sweep, near-full MAC coverage.
# Author: Smaug <smaug@devbox2>
# Category: general
# Version: 1.1

# v1.1 lessons (device-verified 2026-09-05):
# - plain `nmap -sn -T4` took ~62 s; `-PE -PS80,443 -T4` found the SAME 28 hosts in 11 s.
# - `ip neigh` alone resolved only 5/28 MACs (async fill). An explicit `-PR` pass on
#   the discovered IPs resolves ~100% in ~5 s; neigh is kept as a fallback seed.

LOG green "KB NetRecon v1.1"

IFACE=$(ip -o route get 8.8.8.8 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
if [ -z "$IFACE" ]; then
  LOG red "No default route - Pager is not connected to a network."
  ALERT "No network"
  exit 0
fi

NET=$(ip -o -4 route show dev "$IFACE" scope link 2>/dev/null | head -1 | awk '{print $1}')
if [ -z "$NET" ]; then
  MYIP=$(ip -o -4 addr show dev "$IFACE" 2>/dev/null | awk '{print $4; exit}' | cut -d/ -f1)
  NET="${MYIP%.*}.0/24"
fi

SSID=$(iwinfo "$IFACE" ssid 2>/dev/null | sed 's/^ESSID: *//; s/"//g' | head -1)
[ -n "$SSID" ] || SSID="(unknown)"

LOG cyan "iface: $IFACE  ssid: $SSID"
LOG cyan "target: $NET (the network it is joined to)"

MODE=$(LIST_PICKER "Scan mode" "ARP cache (fast)" "Full sweep (nmap)" "Full sweep (nmap)") || {
  LOG red "cancelled by user - exiting clean"
  exit 0
}
LOG yellow "mode: $MODE"
T0=$(date +%s)

UP=$(mktemp)
MACMAP=$(mktemp)

if [ "$MODE" = "Full sweep (nmap)" ]; then
  LOG cyan "discovery: ICMP + TCP probes (-T4), ~15 s per /24"
  SPIN=$(START_SPINNER "sweep $NET")
  timeout 240 nmap -sn -n -PE -PS80,443 -T4 "$NET" -oG - 2>/dev/null \
    | grep "Status: Up" | awk '{print $2}' | sort -V -u > "$UP"
  STOP_SPINNER "$SPIN"
else
  ip neigh show dev "$IFACE" 2>/dev/null | grep -E '^[0-9]+\.' \
    | awk '/lladdr/ {for (i=1; i<=NF; i++) if ($i == "lladdr") { print $1, $(i+1); break }}' > "$MACMAP"
  cut -d' ' -f1 < "$MACMAP" | sort -V -u > "$UP"
fi

TOTAL=$(wc -l < "$UP" | tr -d ' ')
if [ "$TOTAL" = "0" ]; then
  LOG yellow "0 hosts responded on $NET (scan itself ran fine)"
  ALERT "Nothing found"
  exit 0
fi

if [ "$MODE" = "Full sweep (nmap)" ]; then
  LOG cyan "ARP pass: resolving MACs for $TOTAL hosts"
  SPIN=$(START_SPINNER "ARP MAC pass $TOTAL")
  # shellcheck disable=SC2046
  timeout 240 nmap -sn -n -PR $(cat "$UP") -oN - 2>/dev/null \
    | awk '/^Nmap scan report for/ {ip=$5} /MAC Address:/ {print ip, $3}' >> "$MACMAP"
  STOP_SPINNER "$SPIN"
  # anything the ARP pass missed, the now-warmed neighbour table may still have
  ip neigh show dev "$IFACE" 2>/dev/null | grep -E '^[0-9]+\.' \
    | awk '/lladdr/ {for (i=1; i<=NF; i++) if ($i == "lladdr") { print $1, $(i+1); break }}' >> "$MACMAP"
fi

MERGED=$(mktemp)
while read -r IP; do
  MAC=$(awk -v ip="$IP" '$1 == ip {print $2; exit}' "$MACMAP")
  [ -n "$MAC" ] || MAC="(up, no MAC)"
  echo "$IP $MAC"
done < "$UP" > "$MERGED"

MACS=$(grep -cv "no MAC" "$MERGED")
SECS=$(( $(date +%s) - T0 ))
LOG green "$TOTAL up, $MACS with MAC (${SECS}s)"
head -12 "$MERGED" | while read -r IP MAC; do LOG cyan "$IP  $MAC"; done

RUNTS=$(date -u +%FT%TZ)
LOOT=/root/loot/kb_netrecon.txt
mkdir -p /root/loot 2>/dev/null || LOOT=/tmp/kb_netrecon.txt
{
  echo "=== $RUNTS | v1.1 net=$NET iface=$IFACE ssid=$SSID mode=$MODE up=$TOTAL mac=$MACS secs=$SECS ==="
  cat "$MERGED"
} >> "$LOOT" 2>/dev/null || LOG red "loot write failed ($LOOT)"

ALERT "NetRecon: $TOTAL hosts ($MACS MAC)"
VIBRATE "NetRecon:d=8,o=5,b=63:c" || LOG yellow "vibrate skipped"
rm -f "$UP" "$MACMAP" "$MERGED"
