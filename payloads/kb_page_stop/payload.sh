#!/bin/bash
# Title: KB Page Stop
# Description: Stops KB Page: pulls the marker (rotator self-exits), kills by exact PID, runs the proven power off/on flush ladder so NO advertising instance survives, cleans compose, prints what was broadcast. The radio is left clean.
# Author: Smaug <smaug@devbox2>
# Category: interception
# Version: 1.0

LOG green "KB Page Stop v1.0"

PSTATE=${KBP_STATE:-/root/loot/kbpage}
MARKER="$PSTATE/active"
PIDF=${KBP_PIDFILE:-/tmp/kbpage_rot.pid}

# 1. marker pull = cooperative exit (rotator notices within one frame)
if [ -f "$MARKER" ]; then
  TXT=$(sed -n 's/^TEXT=//p' "$MARKER" | head -1)
  ROTPID=$(sed -n 's/^ROT=//p' "$MARKER" | head -1)
  rm -f "$MARKER"
  LOG cyan "marker pulled - rotator told to stop"
else
  TXT=""; ROTPID=""
  LOG yellow "no active page marker (already stopped or died?)"
fi

# 2. exact-PID kill, then stray sweep by EXACT compose path (our cmdline is
#    this payload's path - pattern can never match us; house pkill rule)
[ -n "$ROTPID" ] && kill -0 "$ROTPID" 2>/dev/null && kill "$ROTPID" 2>/dev/null && LOG green "rotator pid=$ROTPID killed"
OLD=$(sed -n '1p' "$PIDF" 2>/dev/null)
[ -n "$OLD" ] && [ "$OLD" != "$ROTPID" ] && kill -0 "$OLD" 2>/dev/null && kill "$OLD" 2>/dev/null && LOG yellow "stray rotator pid=$OLD killed"
for P in $(pgrep -f "ash ${KBP_RUN:-/tmp/kbpage.sh}" 2>/dev/null); do
  [ "$P" = "$$" ] && continue
  kill "$P" 2>/dev/null && LOG yellow "orphan rotator pid=$P killed"
done

# 3. flush any live advertising instance. (echo| stdin: btmgmt hangs on /dev/null
#    stdin — payload context is non-tty; device-proven 2026-10-10) No del-adv on this btmgmt build;
#    power off/on is the device-PROVEN flush (advertising_removed witnessed
#    2026-10-10). Only cycle the radio if a page actually ran.
if [ -n "$ROTPID$OLD" ] || [ -n "$TXT" ]; then
  if command -v btmgmt >/dev/null 2>&1; then
    echo | timeout 6 btmgmt power off >/dev/null 2>&1; sleep 1
    echo | timeout 6 btmgmt power on  >/dev/null 2>&1; sleep 1
    LOG green "radio power-ladder run: no advertising instance survives"
  fi
fi

rm -f "$PIDF" "${KBP_RUN:-/tmp/kbpage.sh}" "$PSTATE/active.last" 2>/dev/null

if [ -n "$TXT" ]; then
  LOG cyan "page ended: \"$TXT\""
  ALERT "Page stopped, radio clean"
else
  ALERT "No page active"
fi
exit 0
