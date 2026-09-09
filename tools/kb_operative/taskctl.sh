#!/bin/bash
# KB Operative taskctl v1.0 - the handle. Every operator action is a file move
# here, logged. Refusals are the feature: scope + expiry enforced client-side too.
# usage: taskctl.sh <eng> <list|register|queue <host> <taskfile>|kill <host>|recall <host>|dead <host>|results <host>|expire>
set -u
ROOT=${KB_OP_ROOT:-$HOME/kbop}
E=$1; shift || true; D="$ROOT/$E"
[ -f "$D/engagement.conf" ] || { echo "FAIL: no engagement $E"; exit 1; }
. "$D/engagement.conf" 2>/dev/null || true
SCOPE=$(sed -n 's/^SCOPE=//p' "$D/engagement.conf"); EXPIRY=$(sed -n 's/^EXPIRY=//p' "$D/engagement.conf")
now=$(date +%s)
in_scope(){ python3 - "$1" "$SCOPE" <<'PY'
import ipaddress, sys
ip = sys.argv[1]
ok = True
try: ipaddress.ip_address(ip)
except Exception: ok = False
nets = [c.strip() for c in sys.argv[2].split(",") if c.strip()]
try:
    if nets and not any(ipaddress.ip_address(ip) in ipaddress.ip_network(n, strict=False) for n in nets): ok = False
except Exception: ok = False
sys.exit(0 if ok else 1)
PY
}
CMD=${1:-list}
case $CMD in
  list)
    echo "engagement $E  scope=$SCOPE  expiry=$(date -u -d @$EXPIRY +%FT%TZ)  $( [ $now -gt $EXPIRY ] && echo EXPIRED || echo live )"
    for b in "$D"/beacons/*; do [ -e "$b" ] || continue; h=$(basename "$b")
      st=IDLE; [ -f "$D/targets/$h/KILL" ] && st=KILL-ARMED; [ -f "$D/targets/$h/RECALL" ] && st=RECALLED; [ -f "$D/targets/$h/DEAD" ] && st=DEAD
      echo "  $h  last-beat: $(awk '{print strftime("%H:%M:%S",$1)}' "$b" 2>/dev/null)  $(cat "$b" | awk '{print $2}')  [$st]"
    done;;
  register)
    h=$2; R="$D/targets/$h/registered"; [ -f "$R" ] || { echo "FAIL: $h not registered (agent never beat)"; exit 1; }
    IP=$(sed -n '2p' "$R"); if in_scope "$IP"; then echo "IN-SCOPE: $h @ $IP"; else echo "OUT-OF-SCOPE: $h @ $IP NOT in $SCOPE"; exit 2; fi;;
  queue)
    h=$2; T=$3; [ -f "$T" ] || { echo "FAIL: task file $T missing"; exit 1; }
    R="$D/targets/$h/registered"
    [ -f "$R" ] || { echo "FAIL: refusing to queue - $h has never checked in (unregistered host)"; exit 1; }
    IP=$(sed -n '2p' "$R")
    in_scope "$IP" || { echo "REFUSED: $h @ $IP outside scope $SCOPE"; exit 2; }
    [ $now -gt $EXPIRY ] && { echo "REFUSED: engagement expired"; exit 2; }
    mkdir -p "$D/targets/$h/tasks"
    N=$(( $(ls "$D/targets/$h/tasks" 2>/dev/null | grep -cE '^[0-9]{3,6}\.sh') + 1 ))
    f=$(printf '%03d.sh' "$N"); cp "$T" "$D/targets/$h/tasks/$f"
    echo "LOGGED: $(date -u +%FT%TZ) queue $E/$h $f <- $T (scope $SCOPE ok, expiry ok)";;
  kill)
    h=$2; mkdir -p "$D/targets/$h"; echo "armed $(date -u +%FT%TZ)" > "$D/targets/$h/KILL"
    echo "LOGGED: $(date -u +%FT%TZ) KILL armed for $E/$h - agent self-destructs on next beat";;
  recall)
    h=$2; mkdir -p "$D/targets/$h"; echo "armed $(date -u +%FT%TZ)" > "$D/targets/$h/RECALL"
    echo "LOGGED: $(date -u +%FT%TZ) RECALL armed for $E/$h";;
  expire)
    sed -i "s/^EXPIRY=.*/EXPIRY=$((now-1))/" "$D/engagement.conf"
    echo "LOGGED: $(date -u +%FT%TZ) engagement $E EXPIRED - every beating agent receives KILL";;
  rebind)
    # after a target reboot the placed agent is gone (no persistence = design) and
    # the server replay guard would reject a fresh copy restarting N at 1. Rebind
    # is the explicit, LOGGED way to re-arm a name - never silent.
    h=$2; HD="$D/targets/$h"
    [ -d "$HD" ] || { echo "FAIL: $h has no state to rebind"; exit 1; }
    rm -f "$HD/lastn" "$HD/registered" "$HD/RECALL"
    rm -rf "$HD/tasks"
    echo "LOGGED: $(date -u +%FT%TZ) REBIND $E/$h - replay high-water cleared, name re-armed for a fresh placement"
    echo "      (previous beat/results history is preserved under targets/$h/)";;
  results)
    h=$2; for f in "$D"/targets/$h/results/*.out; do [ -e "$f" ] || { echo "no results"; exit 0; }
      echo "===== $(basename "$f" .out) ====="; cat "$f"; echo; done;;
  *) echo "usage: taskctl.sh <eng> list|register|queue|kill|recall|rebind|expire|results"; exit 1;;
esac
