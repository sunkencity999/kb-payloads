#!/bin/sh
# watchdog.sh — KB Pocket detached lifecycle loop: applies (optionally), proves,
# guards, and closes the Management AP. Composed as: env-header + watchdog.sh ->
# /tmp/kbpocket.sh -> setsid ash. ONE atomic owner of the door's whole life:
# a menu payload that dies between "picked" and "armed" can never leave a
# half-state — no marker, no AP, no promise.
#
# WHY THIS EXISTS: the Management AP is the door to SSH and the Virtual Pager
# (http://172.16.52.1:1471). A door left open by forgetting is a standing
# attack surface, so this loop closes it by physics instead of memory: hard
# window expiry AND a walkaway idle cut (no associated client long enough).
# Teardown restores the state that existed before we touched anything — prev
# values reach the restore call as VARIABLES read from prev.state at call
# time, never as composed literals (compose-injection house rule).
#
# env (set by kb_pocket_start into the compose file; all sanitized alnum-ish):
#   KBK_IFACE   interface (device default wlan0mgmt)
#   KBK_APPLY   1 = arm our temp AP (KBK_SSID/ENC/KEY); 0 = guard current only
#   KBK_SSID / KBK_ENC / KBK_KEY   the temporary AP (apply mode; "*" SSID in
#               guard mode = "any non-empty ESSID is in service")
#   KBK_WINDOW  hard window seconds; 0 = until KB Pocket Stop
#   KBK_IDLE    walkaway seconds (0 = disabled); no client this long -> cut
#   KBK_PAIRGRACE seconds at start where idle does not count (pairing time)
#   KBK_RESTORE 1 = re-apply prev SSID/enc/key after teardown (apply mode and
#               prev was on: we knocked over the operator's own always-on AP,
#               so WE put it back. Guard mode never restores — the cut is real.)
#   KBK_STATE   loot dir; KBK_MARKER = $KBK_STATE/active (arm token)
#   KBK_PREVFILE 3-line prev state (ssid/enc/key, or "off" + blanks)
#   KBK_AP / _DISABLE / _CLEAR, KBK_IW, KBK_IWINFO   command paths
#   KBK_TEARDOWN 0 = harness: probe+loop but make NO teardown commands
#
# Stdin/timeout law (kb_page lesson 2026-10-10): every external call is
# timeout-wrapped; a hung helper must never pin the guard meant to outlive it.

: "${KBK_IFACE:=wlan0mgmt}" "${KBK_WINDOW:=0}" "${KBK_IDLE:=0}"
: "${KBK_PAIRGRACE:=90}" "${KBK_RESTORE:=0}" "${KBK_APPLY:=1}"
: "${KBK_SSID:=*}" "${KBK_ENC:=sae-mixed}" "${KBK_KEY:=}"
: "${KBK_AP:=WIFI_MGMT_AP}" "${KBK_AP_DISABLE:=WIFI_MGMT_AP_DISABLE}"
: "${KBK_AP_CLEAR:=WIFI_MGMT_AP_CLEAR}" "${KBK_IW:=iw}" "${KBK_IWINFO:=iwinfo}"
: "${KBK_TEARDOWN:=1}"
: "${KBK_PROBE_TRIES:=10}" "${KBK_PROBE_SLEEP:=2}" "${KBK_TICK:=5}"
: "${KBK_STATE:=/root/loot/kbpocket}"
KBK_MARKER=${KBK_MARKER:-$KBK_STATE/active}
KBK_PIDF=${KBK_PIDFILE:-/tmp/kbpocket_wd.pid}
KBK_PREVFILE=${KBK_PREVFILE:-$KBK_STATE/prev.state}

[ -f "$KBK_MARKER" ] || exit 1            # armed via marker only
echo $$ > "$KBK_PIDF" 2>/dev/null

essid() { timeout 4 $KBK_IW dev "$KBK_IFACE" info 2>/dev/null \
          | sed -n 's/^[[:space:]]*ssid //p'; }   # sed not awk-$2: an ESSID
#   may contain spaces; $2 would truncate and a correct arm would probe-fail
# grep -c prints 0 AND exits 1 (house double-0 gotcha): never chain, never
# treat rc as failure — caller takes stdout only.
stations() { timeout 4 $KBK_IW dev "$KBK_IFACE" station dump 2>/dev/null | grep -c '^Station'; }

# --- apply (or not) the temporary AP ---
if [ "$KBK_APPLY" = "1" ]; then
  timeout 10 $KBK_AP "$KBK_IFACE" "$KBK_SSID" "$KBK_ENC" "$KBK_KEY" >/dev/null 2>&1
fi

# --- prove before trusting: ESSID actually on air before anyone claims it ---
N=0; PROBE=no
while [ "$N" -lt "$KBK_PROBE_TRIES" ]; do
  E=$(essid)
  if [ "$KBK_SSID" = "*" ]; then
    [ -n "$E" ] && { PROBE=yes; break; }
  elif [ "$E" = "$KBK_SSID" ]; then PROBE=yes; break; fi
  sleep "$KBK_PROBE_SLEEP"; N=$((N+1))
done
printf 'TS=%s\nPROBE=%s\nESSID=%s\n' "$(date -u +%FT%TZ)" "$PROBE" "$(essid)" \
  > "$KBK_MARKER.probe" 2>/dev/null
if [ "$PROBE" != yes ]; then               # never entered service -> clean exit
  [ "$KBK_APPLY" = "1" ] && timeout 10 $KBK_AP_CLEAR "$KBK_IFACE" >/dev/null 2>&1
  rm -f "$KBK_MARKER" "$KBK_PIDF" 2>/dev/null
  exit 1
fi

START=$(date +%s); LASTSEEN=$START; REASON="stop"
while :; do
  [ -f "$KBK_MARKER" ] || { REASON="stop"; break; }
  NOW=$(date +%s)
  if [ "$KBK_WINDOW" -gt 0 ] && [ $((NOW - START)) -ge "$KBK_WINDOW" ]; then
    REASON="window"; break
  fi
  if [ "$KBK_IDLE" -gt 0 ] && [ $((NOW - START)) -ge "$KBK_PAIRGRACE" ]; then
    N=$(stations)
    [ "${N:-0}" -gt 0 ] 2>/dev/null && LASTSEEN=$NOW
    if [ $((NOW - LASTSEEN)) -ge "$KBK_IDLE" ]; then REASON="walkaway"; break; fi
  fi
  sleep "$KBK_TICK"
done

# --- teardown: disable always (that's the payload's promise); clear/restore
# only the parts WE changed. Prev values read NOW, as variables, from file. ---
PS=""; PE=""; PK=""
if [ -f "$KBK_PREVFILE" ]; then
  PS=$(sed -n '1p' "$KBK_PREVFILE"); PE=$(sed -n '2p' "$KBK_PREVFILE"); PK=$(sed -n '3p' "$KBK_PREVFILE")
fi
if [ "$KBK_TEARDOWN" = "1" ]; then
  timeout 10 $KBK_AP_DISABLE "$KBK_IFACE" >/dev/null 2>&1
  if [ "$KBK_APPLY" = "1" ]; then
    timeout 10 $KBK_AP_CLEAR "$KBK_IFACE" >/dev/null 2>&1
    if [ "$KBK_RESTORE" = "1" ] && [ -n "$PS" ] && [ "$PS" != "off" ]; then
      timeout 10 $KBK_AP "$KBK_IFACE" "$PS" "$PE" "$PK" >/dev/null 2>&1 \
        && RESTORED="yes($PS)" || RESTORED="failed($PS)"
    else
      RESTORED="left-off"
    fi
  else
    RESTORED="untouched(guard)"
  fi
  STILL=$(timeout 3 $KBK_IWINFO "$KBK_IFACE" mode 2>/dev/null | head -1)
else
  STILL="(harness: no teardown calls)"; RESTORED="(harness)"
fi

printf 'TS=%s\nREASON=%s\nWINDOW=%s\nIDLE=%s\nRESTORED=%s\nMODE_AFTER=%s\n' \
  "$(date -u +%FT%TZ)" "$REASON" "$KBK_WINDOW" "$KBK_IDLE" "$RESTORED" "$STILL" \
  > "$KBK_STATE/last_teardown.log" 2>/dev/null
rm -f "$KBK_MARKER" "$KBK_MARKER.probe" "$KBK_PIDF" 2>/dev/null
exit 0
