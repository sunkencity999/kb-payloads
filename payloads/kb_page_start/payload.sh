#!/bin/bash
# Title: KB Page Start
# Description: BLE pager broadcaster: broadcasts your text as rotating encoded BLE advertisements (KBP v1 frames) - no pairing, no connection, no consent needed by the receiver, zero network footprint. Detached rotator keeps broadcasting after the payload exits; auto-expires. Stop with KB Page Stop.
# Author: Smaug <smaug@devbox2>
# Category: interception
# Version: 1.0

# Device facts (measured via ssh 2026-10-10, FW 1.5.0-epic, BlueZ 5.72):
# - btmgmt add-adv -d <hex> -t <ttl-sec> <instance> => "Instance added: N"
# - NO del-adv/rem-adv/show-adv in this btmgmt build: removal = per-instance
#   -t timeout OR the power off/on ladder (witnessed: power off emitted
#   "advertising_removed: instance 1" - the proven flush).
# - od -tx1, printf %02x, fractional sleep, seq: all verified present.
# - Internal adapter CANNOT randomize address (btmgmt: supported options
#   public-address only) - broadcast is attributable to the pager MAC. Design
#   fact, not a bug; stated in README.
# - Interpreter rule (KB Whisper CI lesson 10-01): never invoke bare `ash`.

LOG green "KB Page Start v1.0"

PH=${_PAYLOAD_HOME:-/root/payloads/user/interception/kb_page_start}
PSTATE=${KBP_STATE:-/root/loot/kbpage}
mkdir -p "$PSTATE" 2>/dev/null || { PSTATE=/tmp/kbpage; mkdir -p "$PSTATE"; }

if ! command -v btmgmt >/dev/null 2>&1; then
  LOG red "btmgmt missing - this payload is pager-only"; ALERT "No btmgmt"; exit 0
fi

# heal a previous rotator (exact PID only - house no-pkill rule)
OLD=$(sed -n '1p' "${KBP_PIDFILE:-/tmp/kbpage_rot.pid}" 2>/dev/null)
[ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null && kill "$OLD" 2>/dev/null \
  && LOG yellow "stopped stale rotator pid=$OLD"

# --- pickers (rules: || exit 0 + log; every LIST_PICKER default LAST) ---
TXT=$(TEXT_PICKER "Page text (ascii)") \
  || { LOG yellow "cancelled - nothing broadcast"; exit 0; }
TXT=$(printf '%s' "$TXT" | tr -cd ' -~' | tr -d '"$`\\')
# tr -cd keeps printable ASCII; tr -d strips the 4 chars that could break the
# double-quoted env header in compose (" $ backtick backslash) — compose-file
# injection is a payload-input problem like any other (house quote discipline)
[ -n "$TXT" ] || { LOG red "no printable characters in page text"; ALERT "Empty page"; exit 0; }
[ ${#TXT} -le 288 ] || { TXT=$(printf '%s' "$TXT" | cut -c1-288); LOG yellow "page truncated to 288 chars"; }

RATE=$(LIST_PICKER "Broadcast pace" "Steady (2 s)" "Fast (1 s)" "Slow (5 s)" "Leave") \
  || { LOG yellow "cancelled - nothing broadcast"; exit 0; }
[ "$RATE" = "Leave" ] && { LOG green "cancelled - nothing broadcast"; exit 0; }
case "$RATE" in
  Fast*)   INTERVAL=1 ;;
  Slow*)   INTERVAL=5 ;;
  *)       INTERVAL=2 ;;
esac

DUR=$(LIST_PICKER "Broadcast window" "2 minutes" "10 minutes" "Until Stop" "Leave") \
  || { LOG yellow "cancelled - nothing broadcast"; exit 0; }
case "$DUR" in
  "2 minutes"*) LIMIT=120 ;;
  "10 minutes"*) LIMIT=600 ;;
  "Until Stop"*) LIMIT=0 ;;
  *) { LOG yellow "cancelled - nothing broadcast"; exit 0; } ;;
esac

TRI="$PH/include/kbproto.sh"
ROT="$PH/include/rotator.sh"
[ -f "$TRI" ] && [ -f "$ROT" ] || { LOG red "include/kbproto.sh or rotator.sh missing"; ALERT "Payload incomplete"; exit 0; }

# compose: env header + pure proto + loop (one ash process, no export needed)
RUN=${KBP_RUN:-/tmp/kbpage.sh}
{ printf 'KBP_TEXT="%s"\n' "$TXT"
  printf 'KBP_INTERVAL=%s\n' "$INTERVAL"
  printf 'KBP_LIMIT=%s\n' "$LIMIT"
  printf 'KBP_TTL=%s\n' "$(( INTERVAL * 2 ))"
  printf 'KBP_STATE="%s"\n' "$PSTATE"
  printf 'KBP_MARKER="%s"\n' "$PSTATE/active"
  printf 'KBP_PIDFILE="%s"\n' "${KBP_PIDFILE:-/tmp/kbpage_rot.pid}"
  cat "$TRI" "$ROT"
} > "$RUN" 2>/dev/null || { LOG red "cannot compose $RUN"; ALERT "Compose failed"; exit 0; }

if command -v ash >/dev/null 2>&1; then ASHCMD="ash"
elif command -v busybox >/dev/null 2>&1; then ASHCMD="busybox ash"
else ASHCMD="sh"; fi
"$ASHCMD" -n "$RUN" >/dev/null 2>&1 || ASHCMD="sh"
$ASHCMD -n "$RUN" >/dev/null 2>&1 || { LOG red "composed rotator failed syntax check"; rm -f "$RUN"; ALERT "Rotator syntax fail"; exit 0; }

# harness hook (documented, default off): compose+check only, never spawns
if [ "${KBP_SPAWN:-1}" = "0" ]; then
  LOG yellow "KBP_SPAWN=0 - composed and checked, NOT spawned (harness mode)"
  ALERT "Page composed (no spawn)"
  exit 0
fi

printf 'TS=%s\nTXT=%s\nINTERVAL=%s\nLIMIT=%s\n' "$(date -u +%FT%TZ)" "$TXT" "$INTERVAL" "$LIMIT" > "$PSTATE/active"
setsid $ASHCMD "$RUN" >/dev/null 2>&1 &
sleep 2
WPID=$(sed -n '1p' "${KBP_PIDFILE:-/tmp/kbpage_rot.pid}" 2>/dev/null)
if [ -z "$WPID" ] || ! kill -0 "$WPID" 2>/dev/null; then
  LOG red "rotator died instantly - inspect $RUN"
  rm -f "$PSTATE/active" "$RUN"
  ALERT "Page failed to start"
  exit 0
fi

printf 'ROT=%s\nTS=%s\nTEXT=%s\nPACE=%ss\nWINDOW=%s\n' "$WPID" "$(date -u +%FT%TZ)" "$TXT" "$INTERVAL" "$LIMIT" >> "$PSTATE/active"

LOG green "PAGE LIVE: pid=$WPID  \"$TXT\"  ${INTERVAL}s/frame  window=${LIMIT}s (0=open)"
LOG "KBP v1 frames: 020106|len|ff|ffff|4b4250 01|seq|total|text"
LOG "every instance auto-expires in $((INTERVAL*2))s even if this dies"
LOG "stop anytime: KB Page Stop"
ALERT "Page broadcasting: $(printf '%s' "$TXT" | cut -c1-12)"
exit 0
