#!/bin/bash
# Title: KB Beacon
# Description: BLE name chameleon. Makes the Pager advertise as a chosen Bluetooth name for a few minutes - prank, decoy, or wardriving bait - then ALWAYS restores the original adapter identity, even on cancel.
# Author: Smaug <smaug@devbox2>
# Category: games
# Version: 1.0

# v1.0 device-verified 2026-09-06 (independent witness from Devbox2's own adapter):
# - `bluetoothctl system-alias "NAME"` + `discoverable on` => pager advertises NAME
#   (witnessed "SmaugBleTest99" @ -59..-71 dBm from a separate controller).
# - btmgmt `name` sets only the mgmt-level alias which bluetoothd SHOWS but doesn't
#   advertise - use bluetoothctl system-alias, not btmgmt name.
# - `discoverable off` CAN FAIL on this stack (org.bluez.Error.Failed). Recovery
#   ladder verified on-device: btmgmt power off + on clears it. This payload's
#   restore trap MUST run that ladder; never leave the pager discoverable.

LOG green "KB Beacon v1.0 - the chameleon"

SAVEDIR=/root/loot/kb_beacon
mkdir -p "$SAVEDIR" 2>/dev/null || SAVEDIR=/tmp/kb_beacon
mkdir -p "$SAVEDIR" 2>/dev/null
MARKER="$SAVEDIR/active"
# self-heal FIRST: if a previous run was SIGKILLed mid-beacon (no trap can run on
# SIGKILL - device-verified ash behavior harness 2026-09-06: untrapped TERM also
# skips the EXIT trap), the marker tells us we left the adapter transformed.
if [ -f "$MARKER" ]; then
  STUCK=$(sed -n '1p' "$MARKER")
  LOG yellow "previous beacon left un-restored - healing first"
  timeout 6 bluetoothctl discoverable off >/dev/null 2>&1
  timeout 6 bluetoothctl system-alias "$STUCK" >/dev/null 2>&1
  rm -f "$MARKER"
fi

command -v bluetoothctl >/dev/null 2>&1 || { LOG red "bluetoothctl missing"; ALERT "No bluetoothctl"; exit 0; }
if ! hciconfig hci0 up >/dev/null 2>&1; then
  LOG red "no bluetooth adapter, or it will not power on"
  ALERT "No BT adapter"
  exit 0
fi

# --- capture original identity BEFORE touching anything ---
SHOW=$(mktemp)
trap 'rm -f "$SHOW"' EXIT
timeout 6 bluetoothctl show > "$SHOW" 2>/dev/null
ORIG_ALIAS=$(sed -n 's/.*Alias: \(.*\)/\1/p' "$SHOW" | head -1 | sed 's/[[:space:]]*$//')
[ -n "$ORIG_ALIAS" ] || ORIG_ALIAS="BlueZ"
ORIG_DISC=$(sed -n 's/.*Discoverable: \(.*\)/\1/p' "$SHOW" | head -1)
LOG cyan "adapter identity saved: alias '$ORIG_ALIAS' discoverable=$ORIG_DISC"

beacon_off() {
  [ -f "$MARKER" ] || return 0   # idempotent: only acts when transformed
  rm -f "$MARKER"
  timeout 6 bluetoothctl discoverable off >/dev/null 2>&1
  sleep 1
  # ladder step 1: did it actually stick?
  if timeout 5 bluetoothctl show 2>/dev/null | grep -q "Discoverable: yes"; then
    LOG yellow "discoverable off was refused by the stack - power-cycling adapter"
    timeout 6 btmgmt power off >/dev/null 2>&1
    sleep 2
    timeout 6 btmgmt power on >/dev/null 2>&1
    sleep 1
  fi
  timeout 6 bluetoothctl system-alias "$ORIG_ALIAS" >/dev/null 2>&1
  # ladder step 2: verify, retry alias once if bluetoothd raced us
  if ! timeout 5 bluetoothctl show 2>/dev/null | grep -q "Alias: $ORIG_ALIAS"; then
    timeout 6 bluetoothctl system-alias "$ORIG_ALIAS" >/dev/null 2>&1
  fi
  timeout 5 bluetoothctl show 2>/dev/null | grep -qE "Discoverable: yes" && \
    LOG red "WARNING: adapter still discoverable - restart bluetoothd or the pager"
  LOG green "identity restored: '$ORIG_ALIAS'"
}

PICK=$(LIST_PICKER "Advertise as..." "Pixel 8 Pro" "Kitchen Scale" "VIVE BASE STATION 1" "OFFICE-PRINTER-047" "John's iPhone") || {
  LOG red "cancelled by user - nothing changed, exiting clean"
  exit 0
}
[ -n "$PICK" ] || PICK="Pixel 8 Pro"

SECS=$(LIST_PICKER "Hold time" "2 min" "5 min" "10 min" "5 min") || {
  LOG red "cancelled by user - nothing changed, exiting clean"
  exit 0
}
SECS=$(echo "$SECS" | tr -dc '0-9')
[ -n "$SECS" ] || SECS=5
SECS=$(( SECS * 60 ))
T0=$(date +%s)

# --- transform ---
echo "$ORIG_ALIAS" > "$MARKER"
timeout 6 bluetoothctl system-alias "$PICK" >/dev/null 2>&1
timeout 6 bluetoothctl discoverable on >/dev/null 2>&1
LOG yellow "the pager now advertises as: $PICK"
LOG cyan "anyone scanning BLE nearby sees a new '$PICK' - for ${SECS}s"
LOG "BACK at any time ends the beacon early (identity restores on ANY exit)"
VIBRATE "Beacon:d=8,o=6,b=200:c" || LOG yellow "vibrate skipped"

# restore on ANY exit path from here forward: normal end, error, or SIGTERM from
# the user pressing BACK (pager kills the payload -> EXIT trap still runs).
# restore on EVERY exit path from here forward. EXIT trap alone is NOT enough on
# ash: an untrapped SIGTERM kills the shell WITHOUT running the EXIT trap
# (harness-proved 2026-09-06) - so TERM/INT/HUP are trapped explicitly too.
# SIGKILL remains uncatchable -> that is what the startup self-heal marker covers.
BCN_SLEEP_STEP=${BCN_SLEEP_STEP:-5}
trap 'beacon_off' EXIT
trap 'beacon_off; exit 0' INT TERM HUP

SPIN=$(START_SPINNER "beacon '$PICK'")
END=$(( T0 + SECS ))
while [ "$(date +%s)" -lt "$END" ]; do
  sleep "$BCN_SLEEP_STEP"
done
STOP_SPINNER "$SPIN"

SECS_TAKEN=$(( $(date +%s) - T0 ))
LOG green "beacon held '$PICK' for ${SECS_TAKEN}s"

RUNTS=$(date -u +%FT%TZ)
LOOT=/root/loot/kb_beacon.txt
mkdir -p /root/loot 2>/dev/null || LOOT=/tmp/kb_beacon.txt
{
  echo "=== $RUNTS | v1.0 BEACON name=$PICK held=${SECS_TAKEN}s restored=$ORIG_ALIAS ==="
} >> "$LOOT" 2>/dev/null || LOG red "loot write failed ($LOOT)"

ALERT "Beacon done, identity restored"
