#!/bin/bash
# Title: KB Wire Stop
# Description: Cuts the reverse wire cleanly: watchdog first (so nothing re-establishes mid-stop), then tunnel, then boot entry, then the identity and dir. Verifies absence of each. Also sweeps strays when no marker dir remains. KB Wire rig-side companion (kbwire_rig.sh remove) revokes the key as the true kill-switch.
# Author: Smaug <smaug@devbox2>
# Category: remote_access
# Version: 1.0
LOG green "KB Wire Stop v1.0"
DIR=${KB_WIRE_DIR:-/root/kbwire}
LIVE=0
ps | grep "$DIR/wired.sh" 2>/dev/null | grep -qv grep && LIVE=1
[ -f "$DIR/wired.conf" ] && LIVE=1

if [ "$LIVE" = "0" ]; then
  LOG yellow "no active wire - sweeping strays"
  kill $(ps | grep "$DIR/wire_key" | grep -v grep | awk '{print $1}') 2>/dev/null
  rm -f /etc/rc.d/S99kbwire 2>/dev/null
  rm -rf "$DIR" 2>/dev/null
  ALERT "No wire active"
  exit 0
fi

# order matters: watchdog dies first, or it re-establishes us mid-stop
WDPIDS=$(ps | grep "$DIR/wired.sh" | grep -v grep | awk '{print $1}')
[ -n "$WDPIDS" ] && kill $WDPIDS 2>/dev/null && LOG green "watchdog stopped"
sleep 1
TPIDS=$(ps | grep "$DIR/wire_key" | grep -v grep | awk '{print $1}')
[ -n "$TPIDS" ] && kill $TPIDS 2>/dev/null && LOG green "tunnel closed"
sleep 1

rm -f /etc/rc.d/S99kbwire 2>/dev/null && LOG green "boot entry removed (if present)"
# final identity destruction: dir gone = key gone = wire unrebuildable from device alone
rm -rf "$DIR" 2>/dev/null

# verify - trust absence, confirmed by two independent mechanisms
sleep 1
LEFTP=$(ps | grep -E "wired\.sh|wire_key" | grep -v grep | wc -l)
LEFTD=0; [ -e "$DIR" ] && LEFTD=1
LEFTR=0; [ -e /etc/rc.d/S99kbwire ] && LEFTR=1
if [ "$LEFTP" = "0" ] && [ "$LEFTD" = "0" ] && [ "$LEFTR" = "0" ]; then
  LOG green "wire fully destroyed: no processes, no identity, no boot entry"
  LOG yellow "rig side still has the key until: tools/kb_wire/kbwire_rig.sh remove"
  VIBRATE "Wire:d=3,o=3,b=250:r" || LOG yellow "vibrate skipped"
  ALERT "Wire stopped, verified clean"
else
  LOG red "STOP INCOMPLETE - procs:$LEFTP dir:$LEFTD rc.d:$LEFTR"
  LOG red "repeat Stop; if a tunnel won't die, rig-side remove ends it in ServerAlive window"
  ALERT "Stop INCOMPLETE - re-run"
fi
exit 0
