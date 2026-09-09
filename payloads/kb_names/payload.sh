#!/bin/bash
# Title: KB Names
# Description: Hostname harvest for the network you are authorized to test. On YOUR OWN AP (mode B): dnsmasq logs every hostname every joined client resolves + DHCP leases give client names; output feeds KB Hijack's target file directly. Joined to a target net (mode A): best-effort passive listen for DNS names in the clear. Never transmits probes beyond local DNS self-tests.
# Author: Smaug <smaug@devbox2>
# Category: general
# Version: 1.0
# Device-verified facts (2026-09-09 spikes):
# - busybox tcpdump does NOT decode DNS summaries ("A?" count = 0) -> name harvest
#   on STA mode is best-effort ASCII fragments from -A (label-split, like GhostRecon).
# - busybox nslookup prints no PTR names -> no reverse-DNS harvest on this device.
# - /tmp/dhcp.leases = "epoch mac ip HOSTNAME 01:mac" in AP mode (Devbox2 seen live).
# - AP mode: our dnsmasq IS clients' resolver -> log-queries=extra is COMPLETE and
#   per-client attributed (Portal v1.0 already ships the log drop pattern).
# - mDNS/NBNS almost silent on br-lan test (0 pkt/5s) -> not relied on.
LOG green "KB Names v1.0 - hostname harvest"
DNSINIT=${KBN_DNSINIT:-/etc/init.d/dnsmasq.hak5}
GENCONF=${KBN_GENCONF:-/var/etc/dnsmasq.conf.cfg*}
LOOT=/root/loot
TGTFILE=${KBN_TARGETS:-/root/portals/hijack_targets.txt}
mkdir -p "$LOOT" 2>/dev/null || LOOT=/tmp

canary_ans(){ nslookup "$1" 127.0.0.1 2>/dev/null | awk '/^Name:/{f=1} f&&/^Address:/{print $2; exit}'; }
restart_dnsmasq(){
  local i
  kill $(pidof dnsmasq) 2>/dev/null
  i=0; while [ $i -lt 8 ]; do pidof dnsmasq >/dev/null || break; sleep 1; i=$((i+1)); done
  pidof dnsmasq >/dev/null || "$DNSINIT" start >/dev/null 2>&1
  i=0; while [ $i -lt 12 ]; do pidof dnsmasq >/dev/null && return 0; sleep 1; i=$((i+1)); done
  "$DNSINIT" start >/dev/null 2>&1; sleep 2
  pidof dnsmasq >/dev/null
}

AP=0
BRIP=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]; exit}')
[ -n "$BRIP" ] && AP=1
IF=br-lan; [ "$AP" = "0" ] && IF=$(ip -o route get 8.8.8.8 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
[ -n "$IF" ] || { LOG red "no network (no br-lan, no default route)"; ALERT "No network"; exit 0; }

SECS=$(LIST_PICKER "Harvest time" "30 s" "60 s" "120 s" "60 s") || { LOG green "cancelled"; exit 0; }
SECS=$(echo "$SECS" | tr -dc '0-9'); [ -n "$SECS" ] || SECS=60

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$LOOT/kb_names-$STAMP.txt"

if [ "$AP" = "1" ]; then
  LOG cyan "mode B (own AP $BRIP): full DNS-query harvest via dnsmasq log"
  CONFDIR=$(grep -m1 '^conf-dir=' $GENCONF 2>/dev/null | head -1 | cut -d= -f2)
  [ -n "$CONFDIR" ] || { LOG red "no dnsmasq conf-dir"; ALERT "Config gone"; exit 0; }
  DROP="$CONFDIR/kbnames.conf"; QLOG=/tmp/kbnames_dns.log
  # canary for the log drop: query a throwaway name, prove it lands in QLOG
  rm -f "$QLOG"; touch "$QLOG"; chmod 666 "$QLOG" 2>/dev/null
  printf "log-queries=extra\nlog-facility=$QLOG\nlog-dhcp\n" > "$DROP" || { ALERT "Drop failed"; exit 0; }
  if ! restart_dnsmasq; then rm -f "$DROP"; ALERT "dnsmasq restart failed"; exit 0; fi
  nslookup kbn_selftest.example 127.0.0.1 >/dev/null 2>&1; sleep 1
  if ! grep -aq kbn_selftest "$QLOG" 2>/dev/null; then
    LOG red "query log not receiving (self-test missing) - reverting"; rm -f "$DROP"; restart_dnsmasq
    ALERT "Query log dead"; exit 0
  fi
  LOG green "query log verified live - listening ${SECS}s (names appear as clients resolve them)"
  timeout "$SECS" tail -f "$QLOG" >/dev/null 2>&1
  # harvest
  {
    echo "# KB Names $STAMP mode=AP iface=$IF secs=$SECS"
    echo "# --- joined clients (DHCP leases: hostname ip mac) ---"
    [ -f /tmp/dhcp.leases ] && awk 'NF>=4 {print $4" "$3" "$2}' /tmp/dhcp.leases
    echo "# --- resolved hostnames (count client-ip|name) ---"
    awk '{ if ($0 ~ /query\[/) { n=""; ci=""; for(i=1;i<=NF;i++){ if($i ~ /^query\[/){ n=$(i+1); sub(/^[A-Z]\]/,"",n); sub(/^\]/,"",n) } if($i=="from"){ ci=$(i+1); sub(/#.*/,"",ci) } } if(n!="") print ci"|"n } }' "$QLOG" 2>/dev/null | sort | uniq -c | sort -rn | sed 's/^ *//'
  } > "$OUT"
  # restore dnsmasq
  rm -f "$DROP" "$QLOG"; restart_dnsmasq
  NAMES=$(awk '/^[0-9]+ /{print $2}' "$OUT" 2>/dev/null | cut -d'|' -f2 | grep -vE '^kbn_selftest' | grep -E '\.' | grep -vE '\.local$|^wpad' | sort -u)
  CLIENTS=$(sed -n '/joined clients/,/resolved/p' "$OUT" | grep -E '^[A-Za-z0-9_.-]+ [0-9]' | awk '{print $1}')
else
  LOG cyan "mode A (joined to net on $IF): passive clear-DNS fragment listen ${SECS}s"
  LOG yellow "busybox tcpdump cannot decode DNS: output = label-split fragments, partial by nature"
  timeout "$((SECS+5))" tcpdump -i "$IF" -n -l -A -s 96 udp port 53 2>/dev/null \
    | tr -c 'a-zA-Z0-9._-' '\n' | grep -E '^[a-zA-Z0-9][a-zA-Z0-9._-]{3,62}$' \
    | grep -viE '^(https?|http|Mozilla|Mozilla5|Linux|Windows|Android)' | sort | uniq -c | sort -rn > "$OUT.rawfrag" 2>/dev/null
  awk '{print $2}' "$OUT.rawfrag" 2>/dev/null | sort -u > "$OUT"
  NAMES=$(grep -E '\.' "$OUT" 2>/dev/null)
  CLIENTS=""
  rm -f "$OUT.rawfrag"
fi

[ -s "$OUT" ] || { LOG red "harvest empty - quiet network?"; ALERT "No names"; exit 0; }
NNAMES=$(echo "$NAMES" | grep -c . 2>/dev/null); NNAMES=${NNAMES:-0}
NCLIENTS=$(echo "$CLIENTS" | grep -c . 2>/dev/null); NCLIENTS=${NCLIENTS:-0}
LOG green "$NNAMES hostnames, $NCLIENTS named clients -> $OUT"
echo "$NAMES" | grep -v '^$' | head -8 | sed 's/^/[NAME] /'

if [ "$AP" = "1" ] && [ "$NNAMES" -gt 0 ]; then
  PICK=$(LIST_PICKER "Seed KB Hijack target file ($NNAMES names)" "Merge into hijack_targets.txt" "Just save the loot file") || PICK="Just save the loot file"
  if [ "$PICK" != "Just save the loot file" ]; then
    [ -f "$TGTFILE" ] && cp "$TGTFILE" "$TGTFILE.bak-$STAMP"
    echo "$NAMES" | cat - "$TGTFILE.bak-$STAMP" 2>/dev/null | grep -E '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' | grep -vE '^$|^(wpad|localhost)' | sort -u | head -25 > "$TGTFILE"
    LOG green "seeded $TGTFILE (merged, dedup, cap 25; old file kept as .bak)"
  fi
fi
VIBRATE "Names:d=6,o=6,b=250:r" || LOG yellow "vibrate skipped"
ALERT "KB Names: $NNAMES hostnames"
exit 0
