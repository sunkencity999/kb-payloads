#!/bin/bash
# Title: KB KickAudit
# Description: Passive Wi-Fi disruption audit. Listens on the monitor interface for deauth/disassoc frames and tells you which clients are being kicked, by whom, how often. Sends nothing. Your own network's "who is yanking whom offline" report.
# Author: Smaug <smaug@devbox2>
# Category: reconnaissance
# Version: 1.0

# v1.0 design facts (device-verified 2026-09-06, Pager FW 24.10.1):
# - tcpdump on wlan0mon decodes 802.11 management frames WITH BSSID/DA/SA fields:
#   "... BSSID:00:11:22:33:... DA:ff:.. SA:00:11:22:33:... Beacon (ssid) ... CH: 9"
# - frame filter: (type mgt) and (subtype deauth or subtype disassoc) for kicks;
#   auth/assocreq/assocresp included as a "rejoin" counter so kicks have context.
# - monitor iface names on this device: wlan0mon / wlan1mon (probe both).
# - THIS PAYLOAD IS READ-ONLY: pure tcpdump listen, no PINEAPPLE_DEAUTH_CLIENT.
#   (Deauth TX exists on the device as hak5cmd PINEAPPLE_DEAUTH_CLIENT - deliberate
#   to keep the transmitter in a separate, authorization-gated payload.)

LOG green "KB KickAudit v1.0 - passive, listens only"

MON=""
for cand in wlan0mon wlan1mon mon0; do
  if ip link show "$cand" >/dev/null 2>&1; then MON=$cand; break; fi
done
[ -n "$MON" ] || { LOG red "no monitor interface (wlan0mon/wlan1mon)"; ALERT "No monitor iface"; exit 0; }

command -v tcpdump >/dev/null 2>&1 || { LOG red "tcpdump missing"; ALERT "No tcpdump"; exit 0; }

MINS=$(LIST_PICKER "Audit window" "2 minutes" "5 minutes" "10 minutes" "5 minutes") || {
  LOG red "cancelled by user - exiting clean"
  exit 0
}
MINS=$(echo "$MINS" | tr -dc '0-9')
[ -n "$MINS" ] || MINS=5
SECS=$(( MINS * 60 ))
T0=$(date +%s)

CAP=$(mktemp)
trap 'rm -f "$CAP" "$CAP.kick" "$CAP.mgmt" "$INV"' EXIT
LOG cyan "auditing ${MINS} min on $MON (deauth/disassoc + rejoin events)"
LOG yellow "nothing is transmitted - pure listen"
SPIN=$(START_SPINNER "kick audit ${MINS}m")
timeout $(( SECS + 15 )) tcpdump -i "$MON" -n -e -l \
  '( type mgt ) and ( subtype deauth or subtype disassoc or subtype auth or subtype assocreq or subtype assocresp )' \
  > "$CAP" 2>/dev/null
STOP_SPINNER "$SPIN"

BYTES=$(wc -c < "$CAP" | tr -d ' ')
if [ "$BYTES" = "0" ]; then
  LOG yellow "no management frames at all in ${MINS}m - monitor iface may be on a dead channel"
  ALERT "KickAudit: silence"
  exit 0
fi

# --- parse: kick lines (deauth/disassoc) ---
# tcpdump prints e.g.:  "BSSID:X DA:Y SA:Z ... Deauth ... reason ..." (or Disassoc).
# attacker-vs-AP attribution: SA = sender of the frame, BSSID = network.
awk '
  {
    bssid=""; da=""; sa=""; kind="";
    if (match($0, /BSSID:[0-9a-f:]{17}/))    { bssid = substr($0, RSTART+6, 17) }
    if (match($0, /DA:[0-9a-f:]{17}/))       { da    = substr($0, RSTART+3, 17) }
    if (match($0, /SA:[0-9a-f:]{17}/))       { sa    = substr($0, RSTART+3, 17) }
    # classify on the SUBTYPE TOKEN (device-verified via tcpdump strings:
    # "DeAuthentication"/"Disassociation"), NOT loose /Deauth/ - reason texts like
    # "reason 3: Deauth coming from AP..." on a DISASSOC frame caused misclassification
    # (harness fixture, 2026-09-06). Deauth tested first: its long reason texts can
    # themselves mention "Disassociation frame".
    kind = ""
    if ($0 ~ /DeAuthentication/)   kind = "DEAUTH"
    else if ($0 ~ /Disassociation/) kind = "DISASSOC"
    if (kind == "") next
    if (bssid == "") next
    # broadcast deauth (everyone kicked) vs targeted
    tgt = (da == "ff:ff:ff:ff:ff:ff") ? "BROADCAST" : da
    print bssid "|" tgt "|" sa "|" kind
  }
' "$CAP" | sort | uniq -c | sort -rn | \
  awk '{print $2}' > "$CAP.kick"

# --- rejoin events for context (auth/assoc counts per client) ---
# NOTE: "DeAuthentication" contains "authentication" - guard kicks out first
awk '
  {
    low = tolower($0)
    if (low ~ /deauth/ || low ~ /disassoc/) next
    sa=""; if (match($0, /SA:[0-9a-f:]{17}/)) { sa = substr($0, RSTART+3, 17) }
    if (sa == "") next
    if (low ~ /authent|assoc|reasso/) print sa
  }
' "$CAP" | sort | uniq -c | sort -rn | head -8 > "$CAP.mgmt" 2>/dev/null || : > "$CAP.mgmt"

KICKS=$(wc -l < "$CAP.kick" | tr -d ' ')

# resolve client names from the arp/neigh where possible (same L2 knowledge helps)
client_name() {
  n=$(ip neigh show 2>/dev/null | awk -v m="$1" 'tolower($0) ~ tolower(m) {print $1; exit}')
  [ -n "$n" ] && echo "$n" || echo ""
}

INV=$(mktemp)
KICKED_TOTAL=0
BROADCASTS=0
while IFS='|' read -r BSSID TGT SA KIND; do
  [ -n "$BSSID" ] || continue
  KICKED_TOTAL=$(( KICKED_TOTAL + 1 ))
  [ "$TGT" = "BROADCAST" ] && BROADCASTS=$(( BROADCASTS + 1 ))
  WHO=$TGT
  if [ "$TGT" != "BROADCAST" ]; then
    N=$(client_name "$TGT"); [ -n "$N" ] && WHO="$TGT($N)"
  fi
  ORIGIN="from $SA"
  [ "$SA" = "$BSSID" ] && ORIGIN="AP-originated"
  echo "$BSSID|$WHO|$KIND|$ORIGIN" >> "$INV"
done < "$CAP.kick"

SECS_TAKEN=$(( $(date +%s) - T0 ))
if [ "$KICKED_TOTAL" = "0" ]; then
  LOG green "clean air: $BYTES bytes of management frames, zero deauth/disassoc in ${MINS}m"
  LOG "rejoin activity (top talkers) seen for context:"
  head -4 "$CAP.mgmt" | while read -r CNT MAC; do LOG cyan "  $CNT rejoins  $MAC"; done
  ALERT "KickAudit: clean"
else
  LOG red "$KICKED_TOTAL distinct kick patterns: $BROADCASTS broadcast, $(( KICKED_TOTAL - BROADCASTS )) targeted"
  head -10 "$INV" | while IFS='|' read -r BSSID WHO KIND ORIGIN; do
    LOG red "$KIND  net $BSSID"
    LOG red "   -> $WHO  $ORIGIN"
  done
  LOG yellow "AP-originated = router reboot/driver; foreign SA on your BSSID = someone kicking"
  ALERT "KickAudit: $KICKED_TOTAL kick patterns!"
fi

RUNTS=$(date -u +%FT%TZ)
LOOT=/root/loot/kb_kickaudit.txt
mkdir -p /root/loot 2>/dev/null || LOOT=/tmp/kb_kickaudit.txt
{
  echo "=== $RUNTS | v1.0 KICKAUDIT iface=$MON window=${MINS}m patterns=$KICKED_TOTAL bcast=$BROADCASTS secs=$SECS_TAKEN ==="
  [ "$KICKED_TOTAL" != "0" ] && cat "$INV"
  echo "-- rejoin context (count SA) --"
  cat "$CAP.mgmt"
} >> "$LOOT" 2>/dev/null || LOG red "loot write failed ($LOOT)"

VIBRATE "KickAudit:d=8,o=5,b=200:r" || LOG yellow "vibrate skipped"
