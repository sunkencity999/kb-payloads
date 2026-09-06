#!/bin/bash
# Title: KB GhostRecon
# Description: Fully passive device profiler. Sends ZERO packets. Listens to the ARP/mDNS/SSDP/NBNS chatter every LAN emits and builds a MAC -> vendor -> class -> name -> IP inventory of everyone talking.
# Author: Smaug <smaug@devbox2>
# Category: general
# Version: 1.0

# v1.0 design facts (device-verified 2026-09-05/06 on Mark VII-era Pager FW):
# - tcpdump -i wlan0cli -n -e -l -A works; -e gives src MAC on every header line;
#   -A gives printable payload so mDNS/SSDP service names land as plain ASCII.
#   A 10 s listen on the home LAN decoded 13 MACs / 7 with service tokens, no reply traffic.
# - ARP "who-has A tell B": src MAC <-> B. "is-at": src MAC <-> that IP (skip teller lines).
# - /usr/share/nmap/nmap-mac-prefixes exists on device (46k lines, "OUI Vendor Name").
# - Nothing here transmits. Cancel must exit 0. Quiet network must say so explicitly.

LOG green "KB GhostRecon v1.0 - passive, sends nothing"

IFACE=$(ip -o route get 8.8.8.8 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
if [ -z "$IFACE" ]; then
  LOG red "No default route - Pager is not connected to a network."
  ALERT "No network"
  exit 0
fi

SSID=$(iwinfo "$IFACE" ssid 2>/dev/null | sed 's/^ESSID: *//; s/"//g' | head -1)
[ -n "$SSID" ] || SSID="(unknown)"

command -v tcpdump >/dev/null 2>&1 || {
  LOG red "tcpdump missing on this device - cannot listen."
  ALERT "No tcpdump"
  exit 0
}

LOG cyan "iface: $IFACE  ssid: $SSID"
LOG yellow "nothing is transmitted - we only listen"

SECS=$(LIST_PICKER "Listen time" "30 s" "60 s" "90 s" "60 s") || {
  LOG red "cancelled by user - exiting clean"
  exit 0
}
# picker answers are labels ("60 s") - strip to digits before arithmetic (ash $(( ))
# treats "60 s" as a syntax error; device-verified hazard class, same family as VIBRATE).
SECS=$(echo "$SECS" | tr -dc '0-9')
[ -n "$SECS" ] || SECS=60
T0=$(date +%s)

CAP=$(mktemp)
trap 'rm -f "$CAP" "$CAP.emit" "$CAP.inv"' EXIT
LOG cyan "listening ${SECS}s on $IFACE (arp/mdns/ssdp/nbns/dhcp)..."
SPIN=$(START_SPINNER "ghost listen ${SECS}s")
# -e: src MAC. -l: line-buffered so SIGTERM keeps everything. -A: printable payload.
# timeout TERM flushes -l output; capture survives in the file.
timeout "$(( SECS + 10 ))" tcpdump -i "$IFACE" -n -e -l -A \
  '( arp or ( udp and ( port 5353 or port 1900 or port 137 or port 68 ) ) )' \
  > "$CAP" 2>/dev/null
STOP_SPINNER "$SPIN"

BYTES=$(wc -c < "$CAP" | tr -d ' ')
if [ "$BYTES" = "0" ]; then
  LOG yellow "network too quiet - no broadcast traffic observed in ${SECS}s"
  ALERT "GhostRecon: silence"
  exit 0
fi
LOG cyan "capture: $BYTES bytes of ambient chatter"

# emit "mac|ip|token" records; token may be empty (bare ARP sighting).
awk -v OFS='|' '
  {
    if ($0 ~ /^[0-9:.]+ ([0-9a-f:]{17}) > /) {
      mac = substr($2, 1, 17); ip = "";
      # src IP = first "a.b.c.d[.port] >" token in the decoded header. Greedy sub()
      # hits the DST not the SRC (harness-caught 2026-09-06: all IPs empty) - match
      # the first occurrence, strip .port, validate 4 octets, drop mDNS/mcast/link-local.
      line = $0;
      if (match(line, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\.[^ >]+)? > /)) {
        ip = substr(line, RSTART, RLENGTH); sub(/ > $/, "", ip);
        n = split(ip, p, ".");
        if (n == 5) ip = p[1] "." p[2] "." p[3] "." p[4];
        else if (n != 4) ip = "";
        if (ip ~ /^(224|239|255|169\.254)\./) ip = "";
      }
      if (mac ~ /^ff:ff:ff:ff:ff:ff$/) mac = "";
      next;
    }
    if (mac == "") next;
    line = $0;
    # mDNS service instance names: foo._tcp.local. Binary -A padding fuses into
    # tokens as dot-runs ("1.........1......_oculusal_sp") - strip through the LAST
    # triple-dot run to recover the real tail; only discard if nothing remains
    # (fixture-verified 2026-09-06: discarding outright lost 2 real devices).
    while (match(line, /[A-Za-z0-9][A-Za-z0-9._-]*\._(tcp|udp)\.local/)) {
      tok = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH);
      sub(/^.*\.\.\./, "", tok);
      if (tok !~ /^\./ && tok != "") print mac, ip, tok;
    }
    # SSDP device classes
    line = $0;
    while (match(line, /urn:schemas-upnp-org:device:[A-Za-z0-9]+:1/)) {
      u = substr(line, RSTART, RLENGTH); sub(/^.*device:/, "", u); sub(/:1$/, "", u);
      print mac, ip, "SSDP:" u; line = substr(line, RSTART + RLENGTH);
    }
    if ($0 ~ /urn:dial-multiscreen-org/) print mac, ip, "SSDP:dial";
    if ($0 ~ /^M-SEARCH/)               print mac, ip, "SSDP:probe";
    if ($0 ~ /Request who-has/) {
      a = $0; sub(/^.*who-has /, "", a); b = a; sub(/ tell .*/, "", b); sub(/ .*/, "", a);
      print mac, a, ""; print mac, b, "";
    }
    if ($0 ~ /is-at/) {
      if ($0 !~ /tell/) { a = $0; sub(/^.*Reply /, "", a); sub(/ is-at.*/, "", a); print mac, a, "" }
    }
    while (match($0, /<[A-Za-z0-9][A-Za-z0-9 -]*<0[01]>/)) {
      print mac, ip, "NBNS:" substr($0, RSTART + 1, RLENGTH - 5);
      $0 = substr($0, RSTART + RLENGTH);
    }
  }
' "$CAP" > "$CAP.emit"

# one row per MAC: merge IPs and tokens, drop empties
awk -F'|' -v SEP='|' '
  {
    if (!($1 in ips) && $2 != "") ips[$1] = $2;
    if ($3 != "" && !seen[$1,$3]++) toks[$1] = toks[$1] SEP $3;
    m[$1] = 1;
  }
  END { for (k in m) print k SEP (k in ips ? ips[k] : "") SEP substr(toks[k], 2) }
' "$CAP.emit" | sort -t'|' -k1,1 > "$CAP.inv"

OUI=/usr/share/nmap/nmap-mac-prefixes   # exists on device AND devbox (verified)
TOTAL=0; IDENT=0
LOOT=/root/loot/kb_ghostrecon.txt
mkdir -p /root/loot 2>/dev/null || LOOT=/tmp/kb_ghostrecon.txt
RUNTS=$(date -u +%FT%TZ)
SEED="=== $RUNTS | v1.0 GHOST iface=$IFACE ssid=$SSID listen=${SECS}s"

classify() {
  case " $1 " in
    *oculusal*)                    echo "Meta Quest VR" ;;
    *companion-link*|*rdlink*)     echo "Apple Mac/Catalyst" ;;
    *googlecast*)                  echo "Chromecast/Google" ;;
    *airplay*)                     echo "AirPlay device" ;;
    *nvstream*)                    echo "NVIDIA SHIELD" ;;
    *nearbypresence*)              echo "Android/Chrome" ;;
    *SSDP:X1*)                     echo "Xfinity gateway" ;;
    *SSDP:dial*)                   echo "Smart TV/DIAL" ;;
    *SSDP:BasicDevice*|*SSDP:probe*) echo "UPnP device" ;;
    *NBNS:*)                       echo "Windows/SMB host" ;;
    *)                             echo "?" ;;
  esac
}
vendor() {
  [ -f "$OUI" ] || { echo "(no OUI table)"; return; }
  p=$(echo "$1" | cut -c1-8 | tr -d ':' | tr 'a-f' 'A-F')
  v=$(awk -v p="$p" '$1 == p {print substr($0, index($0, $2)); exit}' "$OUI")
  [ -n "$v" ] && echo "$v" || echo "?"
}

INV=$(mktemp)
while IFS='|' read -r MAC IP TOKS; do
  [ -n "$MAC" ] || continue
  TOTAL=$(( TOTAL + 1 ))
  CL=$(classify "$TOKS")
  [ "$CL" != "?" ] && IDENT=$(( IDENT + 1 ))
  VEN=$(vendor "$MAC")
  # instance label = text right before ._..._tcp.local; rightmost match, sanitize junk.
  # plain `sed -E` (device sed handles -E; do NOT call `busybox` explicitly - the
  # device may not ship a busybox binary in PATH, verified absent 2026-09-05).
  NAME=$(printf ' %s\n' "$TOKS" | sed -E -n 's/.*[ .]([A-Za-z0-9][A-Za-z0-9 ()+'"'"'-]*)\._[^ ._]+\._(tcp|udp)\.local.*/\1/p' | tail -1 | tr -cd 'A-Za-z0-9 ()+,-._')
  # strip leading separator junk the greedy match can swallow
  NAME=$(printf '%s' "$NAME" | sed -E 's/^[. ,;:]+//; s/[. ,;:]+$//')
  echo "$MAC|$IP|$VEN|$CL|$NAME|$(echo "$TOKS" | tr '|' ' ')" >> "$INV"
done < "$CAP.inv"

SECS_TAKEN=$(( $(date +%s) - T0 ))
LOG green "$TOTAL devices seen, $IDENT identified (${SECS_TAKEN}s)"
head -12 "$INV" | while IFS='|' read -r MAC IP VEN CL NAME TOKS; do
  LOG cyan "${IP:-no IP}  $CL  $MAC  $VEN  ${NAME}"
done

{
  echo "${SEED} devs=$TOTAL ident=$IDENT secs=$SECS_TAKEN ==="
  cat "$INV"
} >> "$LOOT" 2>/dev/null || LOG red "loot write failed ($LOOT)"

ALERT "GhostRecon: $TOTAL devs ($IDENT id)"
VIBRATE "GhostRecon:d=6,o=6,b=63:c" || LOG yellow "vibrate skipped"
rm -f "$INV"
