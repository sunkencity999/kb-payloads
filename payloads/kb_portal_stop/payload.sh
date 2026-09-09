#!/bin/bash
# Title: KB Portal Stop
# Description: Stops KB Portal: kills the server, removes the wildcard DNS drop, restarts dnsmasq, verifies real DNS returns, prints a capture summary. Undo is the product.
# Author: Smaug <smaug@devbox2>
# Category: interception
# Version: 1.0

LOG green "KB Portal Stop v1.0"
DNSINIT=${DNSINIT:-/etc/init.d/dnsmasq.hak5}
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
STATE=${KBP_STATE:-/root/loot/kb_portal}
MARKER="$STATE/active"

DNSINIT=${KBP_DNSINIT:-/etc/init.d/dnsmasq.hak5}
GENCONF=${KBP_GENCONF:-/var/etc/dnsmasq.conf.cfg*}
if [ ! -f "$MARKER" ]; then
  LOG yellow "no active portal marker - sweeping for stray drops anyway"
  CDDIR=$(grep -m1 '^conf-dir=' $GENCONF 2>/dev/null | head -1 | cut -d= -f2)
  if [ -n "$CDDIR" ] && ls "$CDDIR"/kbportal*.conf >/dev/null 2>&1; then
    rm -f "$CDDIR"/kbportal*.conf "$CDDIR"/kbp_canary.conf
    restart_dnsmasq
    LOG green "stray kbportal drops removed, dnsmasq restarted"
    ALERT "Strays cleaned"
    exit 0
  fi
  if netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":80$"; then
    LOG yellow "NOTE: something still listens on :80 (not ours - leaving it)"
  fi
  ALERT "No portal active"
  exit 0
fi

PID=$(sed -n 's/^PID=//p' "$MARKER" | head -1)
DROP=$(sed -n 's/^DROP=//p' "$MARKER" | head -1)
TPL=$(sed -n 's/^TPL=//p' "$MARKER" | head -1)

if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
  kill "$PID" 2>/dev/null; sleep 1
  kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null
  LOG green "portal server stopped (pid $PID)"
else
  LOG yellow "server pid was already gone"
fi

DNSINIT=${KBP_DNSINIT:-/etc/init.d/dnsmasq.hak5}
DROPQ=$(sed -n 's/^DROPQ=//p' "$MARKER" | head -1)
[ -n "$DROPQ" ] && rm -f "$DROPQ"
if [ -n "$DROP" ] && [ -f "$DROP" ]; then
  rm -f "$DROP" "$(dirname "$DROP")/kbp_canary.conf" 2>/dev/null
  restart_dnsmasq
  LOG green "DNS drop removed + dnsmasq restarted"
  # verify real DNS returns: a .invalid name must give NXDOMAIN, not the portal IP
  PORTAL_IP=$(sed -n 's/^IP=//p' "$MARKER" | head -1)
  sleep 2
  # answer-section only: nslookup ALWAYS prints "Address: <server>" header, a raw
  # grep for the portal IP matched it -> permanent false WARNING (fixed 2026-09-07)
  if nslookup revert-check.invalid "$PORTAL_IP" 2>/dev/null | grep -A1 '^Name:' | grep -q "$PORTAL_IP"; then
    LOG red "WARNING: wildcard DNS STILL ACTIVE - restart dnsmasq manually"
    ALERT "DNS still captive!"
  else
    LOG green "DNS verified restored (NXDOMAIN returned, not hijacked)"
  fi
else
  LOG yellow "no drop file found - DNS may not have been captive"
fi

if [ -s /tmp/kbportal_capture.log ]; then
  cp /tmp/kbportal_capture.log "$STATE/$TPL-$(date -u +%Y%m%dT%H%M%SZ).log" 2>/dev/null \
    && LOG green "capture log archived to $STATE/" || LOG red "capture archive FAILED"
  : > /tmp/kbportal_capture.log 2>/dev/null
fi
if [ -s /tmp/kbportal_dns.log ]; then
  cp /tmp/kbportal_dns.log "$STATE/dns-$TPL-$(date -u +%Y%m%dT%H%M%SZ).log" 2>/dev/null \
    && LOG green "DNS query log archived to $STATE/" || LOG yellow "dns log copy failed"
  : > /tmp/kbportal_dns.log 2>/dev/null
fi
rm -f "$MARKER" "$STATE/uhttpd.pid" 2>/dev/null

LOG cyan "capture summary:"
# newest archived capture for this template (archive glob, wc-safe counts)
CAPLOG=$(ls -t "$STATE/$TPL-"*.log 2>/dev/null | head -1)
if [ -n "$CAPLOG" ] && [ -f "$CAPLOG" ]; then
  LINES=$(wc -l < "$CAPLOG")
  POSTS=$(grep "^POST " "$CAPLOG" 2>/dev/null | wc -l)
  FPS=$(grep "^FP " "$CAPLOG" 2>/dev/null | wc -l)
  LOG green "$CAPLOG: $LINES requests, $POSTS form submissions, $FPS fingerprints"
else
  LOG yellow "no capture log for $TPL"
fi
ALERT "Portal stopped, DNS clean"
exit 0
