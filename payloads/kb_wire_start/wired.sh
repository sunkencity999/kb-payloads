#!/bin/sh
# KB Wire mechanism (v1.0) - establish, canary-prove, watch, expire, self-immolate.
# Started by KB Wire Start (interactive) or /etc/rc.d/S99kbwire (boot). NO pager
# UI functions here: it must survive sourcing at boot with nothing but ash.
# Config: wired.conf written by the Start payload (DIR RIG PORT WD EXP PERSIST SSHP).
CONF=${1:-/root/kbwire/wired.conf}
[ -f "$CONF" ] || exit 0
# shellcheck disable=SC1090
. "$CONF"
PAGERD=${PAGERD:-22}   # pager-side sshd port (22 = real device; lab knob only)
# pager-side sshd ADDRESS for the forward target. 127.0.0.1 fails on firmwares
# whose sshd binds an interface (excludes lo - witnessed on Mark VII-era pager:
# tunnel up, forward zero-byte, canary honest-fail). Set to the br-lan IP there.
PTGT=${PTGT:-127.0.0.1}
INT=${KB_WIRE_INTERACTIVE:-0}
say(){ echo "$(date -u +%FT%TZ) $*" >> "$DIR/wired.log" 2>/dev/null; }
# date-gate fails CLOSED: a process born past its window (stale boot after
# immolate-window, or a late relaunch) must never raise the wire at all - it
# destroys itself on sight instead of retrying until expiry re-checks fire.
if [ "$(date +%s)" -gt "$EXP" ]; then
  echo "$(date -u +%FT%TZ) born past expiry - refusing to exist" >> "$DIR/wired.log" 2>/dev/null
  for p in $(ps | grep "$DIR/wire_key" | grep -v grep | awk '{print $1}'); do kill "$p" 2>/dev/null; done
  rm -f /etc/rc.d/S99kbwire 2>/dev/null
  rm -rf "$DIR" 2>/dev/null
  exit 0
fi

tunnel_pids(){ ps | grep "$DIR/wire_key" | grep -v grep | awk '{print $1}'; }

establish(){
  try=0
  while [ $try -lt 3 ]; do
    pp=$((PORT+try))
    ssh -f -i "$DIR/wire_key" \
      -o BatchMode=yes -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$DIR/known_hosts" \
      -o ConnectTimeout=10 \
      -R "127.0.0.1:$pp:$PTGT:$PAGERD" -p "$SSHP" "$RIG" \
      "wire" 2>>"$DIR/wired.log" \
    && { echo "$pp" > "$DIR/port.now"; say "tunnel up: rig 127.0.0.1:$pp -> pager:22"; return 0; }
    try=$((try+1))
    say "establish failed (attempt $try, tried port $pp)"
    sleep 2
  done
  return 1
}

# Canary: the SSH-2.0 banner is sent by the pager's sshd BEFORE auth - seeing it
# through the rig's forward proves the entire loop with zero credentials.
canary(){
  pp=$(cat "$DIR/port.now" 2>/dev/null)
  [ -n "$pp" ] || return 1
  # rides the shell-locked wire key: rig-side dispatcher answers exec "canary"
  # by reading the banner at rig:127.0.0.1:$pp (the forward) - what comes back
  # MUST be the PAGER sshd greeting, proving the whole loop without any auth.
  ssh -i "$DIR/wire_key" \
    -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$DIR/known_hosts" -o ConnectTimeout=10 -p "$SSHP" "$RIG" \
    "canary" 2>>"$DIR/wired.log" | grep -q "^SSH-"
  return
}

immolate(){
  say "IMMOLATE: window closed - destroying key, dir, and boot entry"
  for p in $(tunnel_pids); do kill "$p" 2>/dev/null; done
  rm -f /etc/rc.d/S99kbwire 2>/dev/null
  rm -rf "$DIR" 2>/dev/null
}

if ! establish; then
  if [ "${PERSIST:-0}" = "1" ]; then
    say "boot/no-link: persist mode - retrying every ${WD}s until window closes"
    while :; do
      sleep "$WD"
      [ "$(date +%s)" -gt "$EXP" ] && { immolate; exit 0; }
      establish && break
    done
    canary && say "canary OK after boot (banner looped)" \
             || say "canary failed after boot - tunnel up but loop unproven; watchdog keeps watching"
  else
    say "FATAL: establish failed - rig unreachable OR wire key not authorized (rig side: kbwire_rig.sh install)"
    echo WIRE_FAIL >> "$DIR/wired.log"
    exit 1
  fi
else
  if canary; then
    say "canary OK: SSH banner looped rig-forward-pager"
    [ "$INT" = "1" ] && echo WIRE_READY >> "$DIR/wired.log"
  else
    for p in $(tunnel_pids); do kill "$p" 2>/dev/null; done
    say "FATAL: canary FAILED - forward not answering as pager sshd; wire NOT claimed live"
    [ "$INT" = "1" ] && echo WIRE_CANARYFAIL >> "$DIR/wired.log"
    exit 2
  fi
fi

# watchdog loop: re-establish on loss; immolate at expiry (the failsafe that
# does not depend on anyone remembering - Stuxnet's date-gate, aimed at us)
while :; do
  sleep "$WD"
  # re-source config every pass: expiry/WD editable from disk without restart
  # (the operator soft-kill: shorten EXP, the gate obeys on next pass - and
  # immolation always honors the CURRENT window, not launch-time memory)
  [ -f "$CONF" ] && . "$CONF"
  now=$(date +%s)
  [ "$now" -gt "$EXP" ] && { immolate; exit 0; }
  if ! ps | grep "$DIR/wire_key" | grep -v grep >/dev/null; then
    say "tunnel lost - re-establishing"
    if establish; then
      canary && say "re-established + canary OK" || say "re-established but canary failed"
    else
      say "re-establish failed this pass (retry at next interval)"
    fi
  fi
done
