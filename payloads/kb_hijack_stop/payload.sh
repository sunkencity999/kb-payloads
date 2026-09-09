#!/bin/bash
# Title: KB Hijack Stop
# Description: Stops KB Hijack: kills the server, removes the targeted DNS drop, restarts dnsmasq, verifies the hijacked names resolve for real again, archives capture with counts. Undo is the product.
# Author: Smaug <smaug@devbox2>
# Category: interception
# Version: 1.0

LOG green "KB Hijack Stop v1.0"
canary_ans(){ nslookup "$1" 127.0.0.1 2>/dev/null | awk '/^Name:/{f=1} f&&/^Address:/{print $2; exit}'; }
manual_respawn(){ # last-resort bring-up straight from the generated conf, bypassing
  local GEN
  GEN=$(ls -t /var/etc/dnsmasq.conf.cfg* 2>/dev/null | head -1)
  [ -f "$GEN" ] || return 1
  kill $(pidof dnsmasq) 2>/dev/null; sleep 1
  nohup /usr/sbin/dnsmasq -C "$GEN" -k >/tmp/dnsmasq_manual.log 2>&1 &
  sleep 2
  pidof dnsmasq >/dev/null
}
restart_dnsmasq(){ # kill ALL instances, wait gone, init start; on procd crash-loop
  # backoff (witnessed 2026-09-09: rapid Start/Stop test cycles push procd into
  # "12 crashes" cooldown and start becomes a no-op) wait once, then manual respawn.
  local i
  kill $(pidof dnsmasq) 2>/dev/null
  i=0
  while [ $i -lt 8 ]; do pidof dnsmasq >/dev/null || break; sleep 1; i=$((i+1)); done
  pidof dnsmasq >/dev/null || "$DNSINIT" start >/dev/null 2>&1
  i=0
  while [ $i -lt 12 ]; do pidof dnsmasq >/dev/null && return 0; sleep 1; i=$((i+1)); done
  sleep 25
  "$DNSINIT" start >/dev/null 2>&1
  i=0
  while [ $i -lt 10 ]; do pidof dnsmasq >/dev/null && return 0; sleep 1; i=$((i+1)); done
  manual_respawn
}
reload_dnsmasq(){ # restart + PROVE conf-dir drops loaded: canary $1 answers $IP.
  # Outcome-verified: pid comparison lies on this box (procd respawn races, init
  # restart sometimes no-ops - all failure modes witnessed 2026-09-09).
  local i
  restart_dnsmasq || return 1
  [ -n "$1" ] || return 0
  i=0
  while [ $i -lt 8 ]; do
    [ "$(canary_ans "$1")" = "$IP" ] && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}
STATE=${KBH_STATE:-/root/loot/kbhijack}
MARKER="$STATE/active"
DNSINIT=${KBH_DNSINIT:-/etc/init.d/dnsmasq.hak5}
GENCONF=${KBH_GENCONF:-/var/etc/dnsmasq.conf.cfg*}

if [ ! -f "$MARKER" ]; then
  LOG yellow "no active hijack marker - sweeping strays"
  CDDIR=$(grep -m1 '^conf-dir=' $GENCONF 2>/dev/null | head -1 | cut -d= -f2)
  if [ -n "$CDDIR" ] && ls "$CDDIR"/kbhijack*.conf >/dev/null 2>&1; then
    rm -f "$CDDIR"/kbhijack*.conf "$CDDIR"/kbp_canary.conf; restart_dnsmasq
    LOG green "stray hijack drops removed"; ALERT "Strays cleaned"; exit 0
  fi
  ALERT "No hijack active"; exit 0
fi

PID=$(sed -n 's/^PID=//p' "$MARKER" | head -1)
DROP=$(sed -n 's/^DROP=//p' "$MARKER" | head -1)
PORTAL_IP=$(sed -n 's/^IP=//p' "$MARKER" | head -1)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

[ -n "$PID" ] && kill "$PID" 2>/dev/null; sleep 1
kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null
LOG green "hijack server stopped"

if [ -n "$DROP" ] && [ -f "$DROP" ]; then
  FIRSTTGT=$(sed -n 's|^address=/\([^/]*\)/.*|\1|p' "$DROP" | head -1)
  rm -f "$DROP" "$(dirname "$DROP")/kbp_canary.conf" 2>/dev/null; restart_dnsmasq
  sleep 2
  if [ -n "$FIRSTTGT" ] && nslookup "$FIRSTTGT" "$PORTAL_IP" 2>/dev/null | grep -A1 '^Name:' | grep -q "$PORTAL_IP"; then
    LOG red "WARNING: $FIRSTTGT STILL hijacked - restart dnsmasq manually"; ALERT "DNS still hijacked!"
  else
    LOG green "DNS verified restored (first target no longer answers as Pager)"
  fi
else
  LOG yellow "drop file already gone"
fi

if [ -s /tmp/kbhijack_capture.log ]; then
  cp /tmp/kbhijack_capture.log "$STATE/capture-$STAMP.log" 2>/dev/null \
    && { sha256sum "$STATE/capture-$STAMP.log" > "$STATE/capture-$STAMP.log.sha256" 2>/dev/null
         LOG green "capture archived + hashed"
         LINES=$(grep -c . "$STATE/capture-$STAMP.log"); LINES=${LINES:-0}
         POSTS=$(grep -c "^POST " "$STATE/capture-$STAMP.log" 2>/dev/null); POSTS=${POSTS:-0}
         TGTS=$(grep -aoE 'tgt=[^|]*' "$STATE/capture-$STAMP.log" 2>/dev/null | sort -u | wc -l)
         LOG green "$STATE/capture-$STAMP.log: $LINES hits, $POSTS credential POSTs, $TGTS distinct targets"
         grep -a "^POST " "$STATE/capture-$STAMP.log" | head -2 | cut -c1-90 | sed 's/^/[FIRST] /'
       } || LOG red "capture archive FAILED"
  : > /tmp/kbhijack_capture.log 2>/dev/null
else
  LOG yellow "capture empty - nobody visited the trap"
fi

rm -f "$MARKER" "$STATE/uhttpd.pid" /tmp/kbhijack_capture.log 2>/dev/null
ALERT "Hijack stopped, DNS clean"
exit 0
