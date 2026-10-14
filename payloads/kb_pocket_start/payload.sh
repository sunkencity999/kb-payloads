#!/bin/bash
# Title: KB Pocket Start
# Description: Phone-controlled pager door: arms the Management AP (the ONLY network the firewall allows to reach SSH and the Virtual Pager at http://172.16.52.1:1471) with a blend-in SSID and a fresh random WPA3 key shown on the LCD - then a detached watchdog closes the door by PHYSICS: hard window expiry AND walkaway cut (no client for N minutes). Stops restore whatever AP existed before. No bright yellow box comes out of your pocket.
# Author: Smaug <smaug@devbox2>
# Category: remote_access
# Version: 1.0

# Device facts (measured via ssh 2026-10-14, FW 1.5.0-epic):
# - WIFI_MGMT_AP [iface] [ssid] [enc] [key]; enc: psk2 | sae-mixed (usage read
#   from the binary). Disable/Clear/Hide variants all exist; Hide's own help
#   admits hidden SSIDs still leak to wifi tools - so we blend by NAME, not
#   by hiding.
# - wlan0mgmt is its OWN interface: arming it never disturbs portal/client
#   radios. iw dev info / station dump read it (both used by the watchdog).
# - Firewall: SSH + :1471 reachable ONLY from USB-C and this Management AP.
# - /usr/bin/awk present; od ABSENT (urandom via head -c | tr, KEYLEN=16
#   measured today). setsid present (kb_whisper 10-01).
# - The compose env header wraps values in double quotes: sanitizers strip
#   everything outside a safe charset so no " $ backtick \ can ever compose
#   its way into code (house rule, kb_page precedent).
# - Apply happens inside the watchdog, gated on the marker file: no marker,
#   no AP - a payload dying mid-menu can never leave a half-open door.

LOG green "KB Pocket Start v1.0"

PH=${_PAYLOAD_HOME:-/root/payloads/user/remote_access/kb_pocket_start}
PSTATE=${KBK_STATE:-/root/loot/kbpocket}
mkdir -p "$PSTATE" 2>/dev/null || { PSTATE=/tmp/kbpocket; mkdir -p "$PSTATE"; }

WD="$PH/include/watchdog.sh"
PARSER="$PH/include/parse_prev.awk"
BLEND="$PH/include/blendin.list"
[ -f "$WD" ] && [ -f "$PARSER" ] || { LOG red "include/watchdog.sh or parse_prev.awk missing"; ALERT "Payload incomplete"; exit 0; }

# heal a previous watchdog (exact saved PID only - house no-pkill rule)
OLD=$(sed -n '1p' "${KBK_PIDFILE:-/tmp/kbpocket_wd.pid}" 2>/dev/null)
[ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null && kill "$OLD" 2>/dev/null \
  && LOG yellow "stopped stale pocket watchdog pid=$OLD"

# --- snapshot current mgmt AP state BEFORE touching anything (3 lines:
# ssid/enc/key, or "off"): restore-what-was is only possible if we record
# what-was first. Re-run over plain ssh on-device = the parser's proof. ---
PREV=$(${KBK_AWK:-awk} -F"'" -f "$PARSER" "${KBK_CONF:-/etc/config/wireless}" 2>/dev/null)
PREVSSID=$(printf '%s' "$PREV" | sed -n '1p')
# no mgmt iface in config at all → parser prints nothing: treat "absent" and
# "off" as the same state (restore target: nothing)
[ -n "$PREVSSID" ] || { PREVSSID=off; PREV=off; }
printf '%s\n' "${PREV:-off}" > "$PSTATE/prev.state" 2>/dev/null \
  || { LOG red "cannot write $PSTATE/prev.state"; ALERT "Flash write failed"; exit 0; }

# --- pickers (rules: || exit 0 + log; "Leave" LAST on every LIST_PICKER) ---
MODE=$(LIST_PICKER "Door mode" "Arm temp AP (blend-in)" "Guard current AP" "Leave") \
  || { LOG yellow "cancelled - AP untouched"; exit 0; }
case "$MODE" in
  "Arm temp AP"*)   APPLY=1 ;;
  "Guard current"*) APPLY=0 ;;
  *)                LOG yellow "cancelled - AP untouched"; exit 0 ;;
esac
[ "$APPLY" = "0" ] && [ "$PREVSSID" = "off" ] && { LOG red "Guard mode but no management AP is configured - arm one first"; ALERT "Nothing to guard"; exit 0; }

SSID=""
if [ "$APPLY" = "1" ]; then
  STYLE=$(LIST_PICKER "SSID style" "Blend-in (random)" "Custom" "Leave") \
    || { LOG yellow "cancelled - AP untouched"; exit 0; }
  [ "$STYLE" = "Leave" ] && { LOG yellow "cancelled - AP untouched"; exit 0; }
  if [ "$STYLE" = "Custom" ]; then
    SSID=$(TEXT_PICKER "SSID (alnum . _ - )") \
      || { LOG yellow "cancelled - AP untouched"; exit 0; }
  else
    if [ -s "$BLEND" ]; then
      LINES=$(wc -l < "$BLEND" | tr -dc '0-9'); LINES=${LINES:-1}
      # awk srand picks the line (busybox+gawk+mawk all support it). NOT
      # security-random — a key is; a blend name tolerates bias. If awk ever
      # answers junk, fallback line 1 (Linksys) is still a fine neighbor-masking
      # name, so this can never fail the arm.
      IDX=$(${KBK_AWK:-awk} -v l="$LINES" 'BEGIN{srand(); printf "%d\n", int(rand()*l)+1}' /dev/null 2>/dev/null)
      IDX=$(printf '%s' "$IDX" | tr -dc '0-9')
      [ -n "$IDX" ] || IDX=1
      SSID=$(sed -n "${IDX}p" "$BLEND")
    fi
    [ -n "$SSID" ] || SSID="HouseofBradd"
  fi
  SSID=$(printf '%s' "$SSID" | tr -cd 'A-Za-z0-9 ._-' | cut -c1-32)
  [ -n "$SSID" ] || { LOG red "SSID sanitized to nothing"; ALERT "Bad SSID"; exit 0; }

  ENC=$(LIST_PICKER "Encryption" "WPA3 mixed (recommended)" "WPA2 only" "Leave") \
    || { LOG yellow "cancelled - AP untouched"; exit 0; }
  case "$ENC" in
    "WPA3 mixed"*) ENC=sae-mixed ;;
    "WPA2 only"*)  ENC=psk2 ;;
    *) LOG yellow "cancelled - AP untouched"; exit 0 ;;
  esac

  # fresh crypto-random key: urandom path MEASURED on this FW 2026-10-14
  KEY=$(head -c 96 /dev/urandom 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 16)
  KEY=$(printf '%s' "$KEY" | tr -dc 'A-Za-z0-9')
  [ ${#KEY} -ge 12 ] || { LOG red "urandom gave short key - refusing weak door"; ALERT "Key gen failed"; exit 0; }
  ENCRESTORE=0
  [ "$PREVSSID" != "off" ] && ENCRESTORE=1
else
  SSID="*"; ENC="none"; KEY=""; ENCRESTORE=0
fi

WINDOW=$(LIST_PICKER "Door stays open" "10 minutes" "2 minutes" "30 minutes" "Until Stop" "Leave") \
  || { LOG yellow "cancelled - AP untouched"; exit 0; }
case "$WINDOW" in
  "2 minutes")   WIN=120 ;;
  "10 minutes")  WIN=600 ;;
  "30 minutes")  WIN=1800 ;;
  "Until Stop")  WIN=0 ;;
  *) LOG yellow "cancelled - AP untouched"; exit 0 ;;
esac
WIN=${KBK_WINDOW_SET:-$WIN}
WIN=$(printf '%s' "$WIN" | tr -dc '0-9'); WIN=${WIN:-0}

IDLE=$(LIST_PICKER "Walkaway cut" "5 minutes" "2 minutes" "Never (window only)" "Leave") \
  || { LOG yellow "cancelled - AP untouched"; exit 0; }
case "$IDLE" in
  "2 minutes") IDL=120 ;;
  "5 minutes") IDL=300 ;;
  "Never"*)    IDL=0 ;;
  *) LOG yellow "cancelled - AP untouched"; exit 0 ;;
esac
IDL=${KBK_IDLE_SET:-$IDL}
IDL=$(printf '%s' "$IDL" | tr -dc '0-9'); IDL=${IDL:-0}
GRACE=${KBK_GRACE_SET:-90}
GRACE=$(printf '%s' "$GRACE" | tr -dc '0-9'); GRACE=${GRACE:-90}

# --- compose: env header (sanitized values only) + watchdog ---
PT=${KBK_PROBE_TRIES_SET:-10}; PT=$(printf '%s' "$PT" | tr -dc '0-9'); PT=${PT:-10}
PSL=${KBK_PROBE_SLEEP_SET:-2}; PSL=$(printf '%s' "$PSL" | tr -dc '0-9'); PSL=${PSL:-2}
TICK=${KBK_TICK_SET:-5};  TICK=$(printf '%s' "$TICK" | tr -dc '0-9');  TICK=${TICK:-5}
IFACE=$(printf '%s' "${KBK_IFACE:-wlan0mgmt}" | tr -dc 'A-Za-z0-9_'); IFACE=${IFACE:-wlan0mgmt}
RUN=${KBK_RUN:-/tmp/kbpocket.sh}
{ printf 'KBK_IFACE="%s"\n' "$IFACE"
  printf 'KBK_APPLY=%s\n' "$APPLY"
  printf 'KBK_SSID="%s"\n' "$SSID"
  printf 'KBK_ENC="%s"\n' "$ENC"
  printf 'KBK_KEY="%s"\n' "$KEY"
  printf 'KBK_WINDOW=%s\n' "$WIN"
  printf 'KBK_IDLE=%s\n' "$IDL"
  printf 'KBK_PAIRGRACE=%s\n' "$GRACE"
  printf 'KBK_PROBE_TRIES=%s\n' "$PT"
  printf 'KBK_PROBE_SLEEP=%s\n' "$PSL"
  printf 'KBK_TICK=%s\n' "$TICK"
  printf 'KBK_RESTORE=%s\n' "$ENCRESTORE"
  printf 'KBK_STATE="%s"\n' "$PSTATE"
  printf 'KBK_MARKER="%s"\n' "$PSTATE/active"
  printf 'KBK_PREVFILE="%s"\n' "$PSTATE/prev.state"
  printf 'KBK_PIDFILE="%s"\n' "${KBK_PIDFILE:-/tmp/kbpocket_wd.pid}"
  printf 'KBK_TEARDOWN=%s\n' "${KBK_TEARDOWN:-1}"
  cat "$WD"
} > "$RUN" 2>/dev/null || { LOG red "cannot compose $RUN"; ALERT "Compose failed"; exit 0; }

if command -v ash >/dev/null 2>&1; then ASHCMD="ash"
elif command -v busybox >/dev/null 2>&1; then ASHCMD="busybox ash"
else ASHCMD="sh"; fi
"$ASHCMD" -n "$RUN" >/dev/null 2>&1 || ASHCMD="sh"
$ASHCMD -n "$RUN" >/dev/null 2>&1 || { LOG red "composed watchdog failed syntax check"; rm -f "$RUN"; ALERT "Watchdog syntax fail"; exit 0; }

# harness hook (documented, default off): compose+check only, never spawns
if [ "${KBK_SPAWN:-1}" = "0" ]; then
  LOG yellow "KBK_SPAWN=0 - composed and checked, NOT spawned (harness mode)"
  ALERT "Pocket composed (no arm)"
  exit 0
fi

# arm token FIRST, then spawn: watchdog applies the AP only while marker lives
rm -f "$PSTATE/active.probe"   # stale probe from a previous run must never
                                # fake PROBE=yes for this one (house prove-the-
                                # machinery-moves rule, applied to the probe itself)
printf 'MODE=%s\nSSID=%s\nENC=%s\nKEY=%s\nWINDOW=%s\nIDLE=%s\nRESTORE=%s\nPREV=%s\nTS=%s\n' \
  "$APPLY" "$SSID" "$ENC" "$KEY" "$WIN" "$IDL" "$ENCRESTORE" "$PREVSSID" \
  "$(date -u +%FT%TZ)" > "$PSTATE/active" || { LOG red "marker write failed"; rm -f "$RUN"; ALERT "Flash write failed"; exit 0; }
setsid $ASHCMD "$RUN" >/dev/null 2>&1 &

# prove it reached service: watchdog writes active.probe (PROBE=yes|no) after
# checking the ESSID is actually on air (max ~20s)
N=0; PROBE=""
while [ "$N" -lt 30 ]; do
  [ -f "$PSTATE/active.probe" ] && PROBE=$(sed -n 's/^PROBE=//p' "$PSTATE/active.probe" 2>/dev/null)
  [ -n "$PROBE" ] && break
  sleep 1; N=$((N+1))
done
WPID=$(sed -n '1p' "${KBK_PIDFILE:-/tmp/kbpocket_wd.pid}" 2>/dev/null)
if [ "$PROBE" != yes ] || [ -z "$WPID" ] || ! kill -0 "$WPID" 2>/dev/null; then
  LOG red "door never proved on air (probe=${PROBE:-none}) - inspect $RUN"
  rm -f "$PSTATE/active" "$RUN"
  ALERT "Pocket failed to arm"
  exit 0
fi

LOG green "POCKET LIVE: pid=$WPID  door=\"$SSID\""
LOG "phone: join \"$SSID\" then open  http://172.16.52.1:1471"
[ "$APPLY" = "1" ] && { LOG "key (LCD only): $(printf '%s' "$KEY" | cut -c1-8) $(printf '%s' "$KEY" | cut -c9-16)"; LOG "net: $ENC  on-air since $(date -u +%FT%TZ)"
  [ "$ENCRESTORE" = "1" ] && LOG "your home AP \"$PREVSSID\" will be RE-ARMED at teardown"
  [ "$ENCRESTORE" = "0" ] && LOG "prev state was off: teardown leaves it off"
}
[ "$APPLY" = "0" ] && LOG "guard mode: current AP untouched until the cut (then OFF, by promise)"
[ "$WIN" -gt 0 ] && LOG "auto-close: window ${WIN}s"
[ "$IDL" -gt 0 ] && LOG "auto-close: walkaway (no client ${IDL}s after 90s pairing grace)"
LOG "close anytime: KB Pocket Stop"
ALERT "Pocket door open: $(printf '%s' "$SSID" | cut -c1-10)"
exit 0
