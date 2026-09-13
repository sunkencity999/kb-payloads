#!/bin/bash
# KB Wire rig-side v1.0 - the OTHER handle. Installs the wire key onto the rig
# with a FORCED COMMAND + restrict (no shell ever exists on the rig through the
# wire key - only "wire" (keepalive) and "canary" (banner probe) run), and
# removes it as the true kill-switch. This is the operator's off-button: a dead,
# lost, or wiped Pager with a still-live wire dies within one ServerAlive cycle
# the moment `remove` runs.
#
# usage: kbwire_rig.sh install <public-key-line> [portbase]
#        kbwire_rig.sh remove | status
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="${KBWIRE_STATE:-$HOME/.kbwire}"
AK="$HOME/.ssh/authorized_keys"
mkdir -p "$STATE"
cmd=${1:-status}
case "$cmd" in
  install)
    KEY=${2:?install needs the public key line the pager printed}
    PORTBASE=${3:-2222}
    case "$PORTBASE" in ''|*[!0-9]*) echo "FAIL: bad portbase"; exit 1;; esac
    # sanity the key line is well-formed (one base64 blob, one type)
    [ "$(echo "$KEY" | awk '{print NF}')" -ge 2 ] || { echo "FAIL: not a pub key line"; exit 1; }
    grep -qF "$KEY" "$AK" 2>/dev/null && { echo "already installed (same key)"; exit 0; }
    cp "$AK" "$AK.bak-kbwire-$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null
    # forced command + restrict, port-forwarding RE-ENABLED (that IS the wire)
    OPTS="command=\"$HERE/kbwire_dispatcher\",restrict,port-forwarding,no-pty"
    printf '%s %s kbwire\n' "$OPTS" "$KEY" >> "$AK" || { echo "FAIL: cannot write authorized_keys"; exit 1; }
    chmod 600 "$AK"
    { echo "PORTBASE=$PORTBASE"; echo "INSTALLED=$(date -u +%FT%TZ)"; } > "$STATE/state"
    echo "OK: wire key installed (forced-command, restrict+port-forwarding). Forward base=$PORTBASE"
    echo "    kill-switch: $0 remove   (revokes + kills live wire session)"
    ;;
  remove)
    n=$(grep -c ' kbwire$' "$AK" 2>/dev/null || true)
    if [ "$n" = "0" ]; then echo "no wire key installed"; rm -f "$STATE/state"; exit 0; fi
    tmp=$(mktemp)
    grep -v ' kbwire$' "$AK" > "$tmp" && mv "$tmp" "$AK" && chmod 600 "$AK"
    # end the live session NOW (don't wait for ServerAlive): dispatcher dies ->
    # sshd closes channel -> -R forward torn down -> device watchdog retries and
    # every retry auth-fails (BatchMode, key gone) forever. True kill.
    pkill -f "kbwire_dispatcher" 2>/dev/null && echo "live wire session ended" || echo "no live session"
    rm -f "$STATE/state"
    echo "OK: wire key revoked ($n line removed) + live session killed. Pager retries will auth-fail until next install."
    ;;
  status)
    if [ -f "$STATE/state" ]; then
      echo "installed $(awk -F= '/^INSTALLED/{print $2}' "$STATE/state") portbase $(awk -F= '/^PORTBASE/{print $2}' "$STATE/state")"
    else echo "not installed (state file absent)"; fi
    [ "$(grep -c ' kbwire$' "$AK" 2>/dev/null || true)" != "0" ] && echo "authorized_keys: wire key PRESENT" || echo "authorized_keys: wire key absent"
    ps -eo pid,args 2>/dev/null | grep "kbwire_dispatcher" | grep -v grep | head -3 | sed 's/^/live: /' || true
    ;;
  *) echo "usage: kbwire_rig.sh install <pubkey> [portbase] | remove | status"; exit 1;;
esac
exit 0
