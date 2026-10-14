#!/bin/bash
# Title: KB Pocket Stop
# Description: Closes the pocket door by promise: pulls the marker so the watchdog self-closes and restores whatever AP existed before, kills by exact PID if wedged, and DIRECT-teardowns (disable/clear/restore-by-variable) if the watchdog died with OUR door still open. Never touches an AP it did not arm. Leaves a teardown receipt in loot.
# Author: Smaug <smaug@devbox2>
# Category: remote_access
# Version: 1.0

LOG green "KB Pocket Stop v1.0"

IFACE=${KBK_IFACE:-wlan0mgmt}
PSTATE=${KBK_STATE:-/root/loot/kbpocket}
[ -d "$PSTATE" ] || PSTATE=/tmp/kbpocket
MARKER="$PSTATE/active"
PIDF=${KBK_PIDFILE:-/tmp/kbpocket_wd.pid}
PREVF="$PSTATE/prev.state"
TEARLOG="$PSTATE/last_teardown.log"

essid() { timeout 4 ${KBK_IW:-iw} dev "$IFACE" info 2>/dev/null \
          | sed -n 's/^[[:space:]]*ssid //p'; }

sweep() { # direct teardown when the watchdog could not finish it
  # $1 APPLY  $2 RESTORE — prev values read from FILE as variables, never
  # composed literals (a key with " $ ` \ passes through byte-identical)
  PS=""; PE=""; PK=""
  if [ -f "$PREVF" ]; then
    PS=$(sed -n '1p' "$PREVF"); PE=$(sed -n '2p' "$PREVF"); PK=$(sed -n '3p' "$PREVF")
  fi
  timeout 10 ${KBK_AP_DISABLE:-WIFI_MGMT_AP_DISABLE} "$IFACE" >/dev/null 2>&1
  if [ "$1" = "1" ]; then
    timeout 10 ${KBK_AP_CLEAR:-WIFI_MGMT_AP_CLEAR} "$IFACE" >/dev/null 2>&1
    if [ "$2" = "1" ] && [ -n "$PS" ] && [ "$PS" != "off" ]; then
      timeout 10 ${KBK_AP:-WIFI_MGMT_AP} "$IFACE" "$PS" "$PE" "$PK" >/dev/null 2>&1 \
        && R="yes($PS)" || R="failed($PS)"
    else
      R="left-off"
    fi
  else
    R="untouched(guard)"
  fi
  printf 'TS=%s\nREASON=direct-sweep\nRESTORED=%s\nMODE_AFTER=%s\n' \
    "$(date -u +%FT%TZ)" "$R" "$(essid)" >> "$TEARLOG" 2>/dev/null
  LOG cyan "direct teardown done: $R"
}

# --- no marker? only sweep a door WE can attribute; a stranger AP stays up ---
if [ ! -f "$MARKER" ]; then
  NOW=$(essid)
  if [ -n "$NOW" ]; then
    LOG yellow "no active marker; AP \"$NOW\" was not armed by this session - left ALONE"
    ALERT "Door not ours"
    exit 0
  fi
  LOG yellow "no pocket door active"
  ALERT "No door active"
  exit 0
fi

APPLY=$(sed -n 's/^MODE=//p'   "$MARKER" | head -1)
SSID=$(sed -n  's/^SSID=//p'   "$MARKER" | head -1)
RESTORE=$(sed -n 's/^RESTORE=//p' "$MARKER" | head -1)
WDPID=$(sed -n '1p' "$PIDF" 2>/dev/null)

rm -f "$TEARLOG"   # stale receipt from a previous run must never fake success
rm -f "$MARKER"    # cooperative close token
LOG cyan "marker pulled - watchdog told to close"

if [ -n "$WDPID" ] && kill -0 "$WDPID" 2>/dev/null; then
  N=0; TEAR=""
  while [ "$N" -lt 30 ]; do
    TEAR=$(sed -n 's/^REASON=//p' "$TEARLOG" 2>/dev/null | head -1)
    [ -n "$TEAR" ] && break
    sleep 1; N=$((N+1))
  done
  if [ -n "$TEAR" ]; then LOG green "watchdog closed the door (reason=$TEAR)"
  else LOG yellow "no teardown receipt in ${N}s - checking radio directly"; fi
fi

# wedged watchdog: exact-PID kill, no pattern sweep (house rule)
if [ -n "$WDPID" ] && kill -0 "$WDPID" 2>/dev/null; then
  kill "$WDPID" 2>/dev/null && LOG yellow "wedged watchdog pid=$WDPID killed"
fi

# sweep iff OUR door is still the one on air (guard mode promised OFF; apply
# mode must not clobber the home AP the watchdog already restored)
NOW=$(essid)
if [ "$APPLY" = "0" ]; then
  [ -n "$NOW" ] && sweep 0 "$RESTORE"
else
  [ "$NOW" = "$SSID" ] && sweep 1 "$RESTORE"
fi

rm -f "$PIDF" "${KBK_RUN:-/tmp/kbpocket.sh}" "$MARKER.probe" 2>/dev/null
FINAL=$(essid)
if [ -n "$FINAL" ]; then
  LOG green "door closed; on air now: \"$FINAL\" (restored/untouched home AP)"
  ALERT "Pocket closed, home AP restored"
else
  LOG green "door closed; management radio silent"
  ALERT "Pocket closed, radio silent"
fi
exit 0
