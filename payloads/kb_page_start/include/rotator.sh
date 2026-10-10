#!/bin/sh
# rotator.sh — KB Page detached broadcaster loop. Composed AFTER kbproto.sh:
#   env-header + kbproto.sh + rotator.sh -> /tmp/kbpage.sh -> setsid ash.
#
# env (set by kb_page_start into the compose file):
#   KBP_TEXT   message (already sanitized printable ASCII)
#   KBP_INTERVAL  seconds between frames (fractional ok; device sleep does 0.3)
#   KBP_LIMIT  total seconds to broadcast; 0 = until KB Page Stop
#   KBP_TTL    per-instance auto-expiry seconds (interval*2 + grace)
#   KBP_MAXFRAMES  frame cap per cycle (default 16 -> 288 chars)
#   KBP_STATE  loot dir; KBP_MARKER = $KBP_STATE/active
#   KBP_BTMGMT btmgmt command (device: btmgmt; harness: PATH mock)
#
# Stdin law (root-caused on-device 2026-10-10 via P/X/Q probe series):
# btmgmt HANGS when stdin is EOF-at-once (/dev/null, setsid default) and
# RETURNS normally when stdin yields a newline first — every call below is
# `echo | timeout 6 btmgmt ...`. Instance ID ceiling (measured 2026-10-10):
# 1-20 accepted, 32 rejected status 0x0d — the true cliff lies between; we
# rotate 1-3, far inside it. This ceiling (NOT the frame content) is what made
# earlier frame-class probes look broken: instance ids 140+ were Invalid
# Parameters all along. Frame format itself verified live: mid-flight power
# off emitted advertising_removed for instances 1,2,3 running OUR mfg frames.
#
# Kill paths, in order of preference:
#   1. per-instance -t TTL: every instance expires on its own — no orphan can
#      outlive 2 intervals even if this process is SIGKILLed.
#   2. marker removed (KB Page Stop): loop self-exits, then power-ladder.
#   3. power off/on ladder: the device-PROVEN flush (2026-10-10 witnessed
#      "advertising_removed: instance 1" on power off). Last resort, ~2s dark.

: "${KBP_INTERVAL:=2}" "${KBP_LIMIT:=0}" "${KBP_MAXFRAMES:=16}"
: "${KBP_BTMGMT:=btmgmt}" "${KBP_STATE:=/root/loot/kbpage}"
KBP_MARKER=${KBP_MARKER:-$KBP_STATE/active}
PIDF=${KBP_PIDFILE:-/tmp/kbpage_rot.pid}
echo $$ > "$PIDF" 2>/dev/null

# sanitize twice defensively (compose already did): printable ASCII only
KBP_TEXT=$(printf '%s' "$KBP_TEXT" | tr -cd ' -~')
[ -n "$KBP_TEXT" ] || exit 1

# chunk count: ceil(len/18), capped (ash has ${#var}; no arrays needed)
MAXCH=${KBP_MAXCHARS:-18}
LEN=${#KBP_TEXT}
TOTAL=$(( (LEN + MAXCH - 1) / MAXCH ))
[ "$TOTAL" -gt "$KBP_MAXFRAMES" ] && TOTAL=$KBP_MAXFRAMES
[ "$TOTAL" -ge 1 ] || exit 1

power_ladder() { # proven flush: off, settle, on
  echo | timeout 6 $KBP_BTMGMT power off >/dev/null 2>&1
  sleep 1
  echo | timeout 6 $KBP_BTMGMT power on  >/dev/null 2>&1
  sleep 1
}

START=$(date +%s)
INST=1
LADDER_OK=0
while :; do
  [ -f "$KBP_MARKER" ] || break            # Stop pulled the marker
  if [ "$KBP_LIMIT" -gt 0 ]; then
    NOW=$(date +%s)
    [ $((NOW - START)) -lt "$KBP_LIMIT" ] || break
  fi
  FR=0
  while [ "$FR" -lt "$TOTAL" ]; do
    [ -f "$KBP_MARKER" ] || break
    CH=$(printf '%s' "$KBP_TEXT" | cut -c$((FR * MAXCH + 1))-$(((FR + 1) * MAXCH)))
    [ -n "$CH" ] || { FR=$((FR+1)); continue; }
    HEX=$(KBP_SEQ=$FR KBP_TOTAL=$TOTAL kbp_encode "$CH")
    # alternating instance ids: previous one is TTL-expiring behind us
    OUT=$(echo | timeout 6 $KBP_BTMGMT add-adv -d "$HEX" -t "$KBP_TTL" "$INST" 2>&1)
    if echo "$OUT" | grep -q "Instance added"; then
      LADDER_OK=1
      printf 'LAST=%s\nTS=%s\nFRAMES=%s\nTOTAL=%s\n' "$FR" "$(date -u +%FT%TZ)" "$FR" "$TOTAL" > "$KBP_MARKER.last" 2>/dev/null
      echo "$HEX" >> "$KBP_STATE/frames.log" 2>/dev/null
    else
      # controller refused (adapter wedged/instance stuck): ladder once, skip frame
      power_ladder
      OUT=$(echo | timeout 6 $KBP_BTMGMT add-adv -d "$HEX" -t "$KBP_TTL" "$INST" 2>&1)
      echo "$OUT" | grep -q "Instance added" || { sleep 2; }   # don't spin if adapter is dead
    fi
    INST=$(( INST % 3 + 1 ))              # 1->2->3->1: id reused only after 3
                                          # intervals > TTL (2 intervals) —
                                          # never collides with a live instance
    sleep "$KBP_INTERVAL"
    FR=$((FR+1))
  done
done

# clean exit: flush any live instance (ours died by TTL unless interval<ttl;
# ladder only if we ever succeeded in adding — never power-cycle a radio we
# never touched)
[ "$LADDER_OK" = 1 ] && power_ladder
rm -f "$PIDF" 2>/dev/null
exit 0
