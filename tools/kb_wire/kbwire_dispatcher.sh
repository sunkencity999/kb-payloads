#!/bin/bash
# KB Wire dispatcher (rig side) - the ONLY thing the wire key can ever run.
# Invoked by sshd as a forced command (restrict,port-forwarding,no-pty). The
# wire key is a key with no shell behind it BY ARCHITECTURE, not policy.
# Commands recognized (exact match only; anything else is denied + logged):
#   wire    - the keepalive body of the -R tunnel (sleep forever; ServerAlive
#             from the device closes the channel when the wire drops)
#   canary  - read the SSH banner on 127.0.0.1:PORT (the forward) and echo it -
#             proves rig-forward-pager loop without any credentials
STATE="${KBWIRE_STATE:-$HOME/.kbwire}"
LOGF="$STATE/access.log"
ts() { date -u +%FT%TZ; }
log() { echo "$(ts) ip=${SSH_CLIENT%% *} cmd=${1:-none} verdict=$2" >> "$LOGF" 2>/dev/null; }
PORTBASE=${KBWIRE_PORTBASE:-2222}
[ -f "$STATE/state" ] && PORTBASE=$(awk -F= '/^PORTBASE/{print $2}' "$STATE/state")
[ -n "${KBWIRE_PORTBASE:-}" ] && PORTBASE="$KBWIRE_PORTBASE"
case "$SSH_ORIGINAL_COMMAND" in
  canary)
    # GREET FIRST, then read: hardened sshds (pager firmware) stay silent until a
    # client version arrives (anti-version-scan). A bare banner-read starves there
    # and the canary would false-fail the whole loop (device-witnessed 2026-09-12).
    for p in $PORTBASE $((PORTBASE+1)) $((PORTBASE+2)); do
      B=$(timeout 6 bash -c "exec 3<>/dev/tcp/127.0.0.1/$p; printf 'SSH-2.0-KBWireCanary_1\r\n' >&3; head -c 40 <&3" 2>/dev/null)
      case "$B" in SSH-*) log canary "ok :$p"; printf '%s\n' "$B"; exit 0;; esac
    done
    log canary "no-banner"
    exit 1;;
  wire)
    log wire "keepalive"
    # keepalive body - the forward lives as long as this does
    while :; do sleep 3600; done
    ;;
  "")
    log interactive "denied"; exit 1;;
  *)
    log "$SSH_ORIGINAL_COMMAND" "denied"; exit 1;;
esac
