#!/bin/bash
# Title: KB GhostBt
# Description: Fully passive Bluetooth LE wardrive. Listens for BLE advertisements for 30-90s and inventories every device broadcasting: name, RSSI, vendor, inferred type. Sends zero connection requests.
# Author: Smaug <smaug@devbox2>
# Category: reconnaissance
# Version: 1.0

# v1.0 design facts (device-verified 2026-09-06 on Pager FW 24.10.1 / BlueZ 5.72):
# - `bluetoothctl --timeout N scan on` emits "[NEW] Device MAC NAME" and
#   "[CHG] Device MAC RSSI: 0x...... (-NN)" lines. The (-NN) parenthesized form is
#   the parse target; the raw hex form is 32-bit two's complement (skip it).
# - `bluetoothctl devices` dumps cache after scan, but hci0 cache persists across
#   boots -> always diff a baseline snapshot so loot = devices seen THIS run.
# - scan on/off are pure LE discovery: no page, no connection, no pairing.
# - OUI table /usr/share/nmap/nmap-mac-prefixes on device (also used by GhostRecon).

LOG green "KB GhostBt v1.0 - passive BLE, connects to nothing"

command -v bluetoothctl >/dev/null 2>&1 || { LOG red "bluetoothctl missing"; ALERT "No bluetoothctl"; exit 0; }

# adapter must answer BEFORE we ask the user anything: hardware fail-fast.
# stdout silenced: hciconfig prints an info banner that would pollute the log.
if ! hciconfig hci0 up >/dev/null 2>&1; then
  LOG red "no bluetooth adapter, or it will not power on"
  ALERT "No BT adapter"
  exit 0
fi

SECS=$(LIST_PICKER "Listen time" "30 s" "60 s" "90 s" "60 s") || {
  LOG red "cancelled by user - exiting clean"
  exit 0
}
# picker answers are UI labels ("60 s") - strip to digits before arithmetic
SECS=$(echo "$SECS" | tr -dc '0-9')
[ -n "$SECS" ] || SECS=60
T0=$(date +%s)

BASE=$(mktemp)
NOW=$(mktemp)
NAMELOG=$(mktemp)
trap 'rm -f "$BASE" "$NOW" "$NAMELOG"' EXIT

# baseline = everything the cache already knew (old sightings excluded from loot)
bluetoothctl devices 2>/dev/null | awk '/^Device / {print $2}' | sort > "$BASE"

LOG cyan "listening ${SECS}s for BLE advertisements..."
SPIN=$(START_SPINNER "BLE listen ${SECS}s")
# scan output captured for NAME lines as belt-and-suspenders (cache is primary)
timeout $(( SECS + 15 )) bluetoothctl --timeout "$SECS" scan on 2>/dev/null |
  grep -E "^\[(NEW|CHG)\] Device " > "$NAMELOG" &
SCANJOB=$!
sleep "$SECS"
STOP_SPINNER "$SPIN"
wait "$SCANJOB" 2>/dev/null   # capture-complete barrier before parsing RSSI

bluetoothctl devices 2>/dev/null | awk '/^Device / {print $2, substr($0, index($0, $3))}' > "$NOW"

# last RSSI per MAC from the scan capture
RSSIMAP=$(mktemp); trap 'rm -f "$BASE" "$NOW" "$NAMELOG" "$RSSIMAP"' EXIT
grep -oE "Device [0-9A-F:]{17} RSSI: .* \(-?[0-9]+\)" "$NAMELOG" 2>/dev/null |
  awk '{ mac=$2; r=$NF; gsub(/[()]/,"",r); last[mac]=r } END { for (m in last) print m, last[m] }' > "$RSSIMAP"

# diff: devices NOT in baseline cache = seen this run
NEWF=$(mktemp); trap 'rm -f "$BASE" "$NOW" "$NAMELOG" "$RSSIMAP" "$NEWF"' EXIT
while read -r MAC NAME; do
  [ -n "$MAC" ] || continue
  grep -qx "$MAC" "$BASE" || echo "$MAC|$NAME" >> "$NEWF"
done < "$NOW"
[ -f "$NEWF" ] || : > "$NEWF"

TOTAL=$(wc -l < "$NEWF" | tr -d ' ')
if [ "$TOTAL" = "0" ]; then
  LOG yellow "no new BLE devices in ${SECS}s (adapter fine, air just quiet)"
  ALERT "GhostBt: silence"
  exit 0
fi

OUI=/usr/share/nmap/nmap-mac-prefixes
classify() {
  case " $1 " in
    *Govee*)          echo "Govee smart plug/light" ;;
    *"HTC BS"*|*"HTC "*|*VIVE*) echo "HTC Vive basestation" ;;
    *MACBOOK*|*APPLE*|*IPHONE*|*IPAD*) echo "Apple device" ;;
    *PIXEL*|*"SM-"*|*SAMSUNG*) echo "Android phone" ;;
    *MIFI*|*HOTSPOT*|*TP-LINK*|*TL-*) echo "WiFi hotspot/router BT" ;;
    *CAR*|*BLE-*|*KY-*) echo "car key / BLE tracker" ;;
    *) echo "?" ;;
  esac
}
# vendor = OUI lookup only. Randomized/private MACs simply miss the OUI table and
# show "?" - no invented bit heuristics (unverified rules are how you get fake data).
vendor() {
  o=$(echo "$1" | cut -c1-8 | tr -d ':' | tr 'a-f' 'A-F')
  [ -f "$OUI" ] || { echo "?"; return; }
  v=$(awk -v p="$o" '$1 == p {print substr($0, index($0, $2)); exit}' "$OUI")
  [ -n "$v" ] && echo "$v" || echo "?"
}

INV=$(mktemp); trap 'rm -f "$BASE" "$NOW" "$NAMELOG" "$RSSIMAP" "$NEWF" "$INV"' EXIT
IDENT=0
while IFS='|' read -r MAC NAME; do
  [ -n "$MAC" ] || continue
  R=$(awk -v m="$MAC" '$1==m {print $2; exit}' "$RSSIMAP")
  [ -n "$R" ] || R="(old)"
  V=$(vendor "$MAC")
  C=$(classify "$NAME")
  [ "$C" != "?" ] && IDENT=$(( IDENT + 1 ))
  # MACs with no real name look like "AA-BB-CC-DD-EE-FF" - normalize to blank
  NN="$NAME"
  [ "$(echo "$NN" | tr -d 'A-Z0-9:-')" = "" ] && NN="(unnamed)"
  echo "$MAC|$NN|$R|$V|$C" >> "$INV"
done < "$NEWF"
# sort by RSSI (strongest first, closest to you)
INVS=$(mktemp); trap 'rm -f "$BASE" "$NOW" "$NAMELOG" "$RSSIMAP" "$NEWF" "$INV" "$INVS"' EXIT
sort -t'|' -k3,3nr "$INV" > "$INVS" 2>/dev/null || mv "$INV" "$INVS"

SECS_TAKEN=$(( $(date +%s) - T0 ))
LOG green "$TOTAL BLE devices, $IDENT identified (${SECS_TAKEN}s)"
head -10 "$INVS" | while IFS='|' read -r MAC NAME R V C; do
  LOG cyan "${R}dBm  $NAME  $C  $MAC"
done

RUNTS=$(date -u +%FT%TZ)
LOOT=/root/loot/kb_ghostbt.txt
mkdir -p /root/loot 2>/dev/null || LOOT=/tmp/kb_ghostbt.txt
{
  echo "=== $RUNTS | v1.0 GHOSTBT listen=${SECS}s devs=$TOTAL ident=$IDENT secs=$SECS_TAKEN ==="
  cat "$INVS"
} >> "$LOOT" 2>/dev/null || LOG red "loot write failed ($LOOT)"

ALERT "GhostBt: $TOTAL BLE devices"
VIBRATE "GhostBt:d=6,o=5,b=250:g" || LOG yellow "vibrate skipped"
