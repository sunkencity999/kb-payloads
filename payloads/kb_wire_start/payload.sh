#!/bin/bash
# Title: KB Wire Start
# Description: Self-healing, self-expiring REVERSE ssh wire from the Pager to the operator's rig. The Pager (behind NAT/firewall, no inbound) calls OUT and parks a tunnel: rig 127.0.0.1:PORT -> Pager sshd. A banner canary proves the whole loop BEFORE it claims LIVE; a watchdog re-establishes on loss; a hard expiry self-immolates everything (dir, key, rc.d entry) even if every operator forgets. Optional boot persistence via /etc/rc.d - expiry still applies.
# Author: Smaug <smaug@devbox2>
# Category: remote_access
# Version: 1.0
# Device-verified 2026-09-12: stock OpenSSH 9.9p2 honors BatchMode /
# ExitOnForwardFailure / ServerAlive* / StrictHostKeyChecking=accept-new;
# ssh-keygen ed25519 present; pager sshd listens :22; /etc/rc.d boot entries
# run; busybox awk systime(); flash ~3.4G free. Rig side needs OpenSSH only.
LOG green "KB Wire Start v1.0 - reverse tunnel, proven loop, hard expiry"
# wired.sh lives beside this payload - but MKVII SOURCES payload.sh, so $0 may
# be the menu shell, not this file. Resolve by CANDIDATES (first dir that
# actually holds wired.sh), never by trusting $0 alone. (Device-witnessed bug
# 2026-09-13: sourcing via a runner elsewhere = false "Install broken".)
SRC=""
for _c in "${KB_WIRE_SRC:-}" "$(dirname "$0" 2>/dev/null)" "$PWD" \
          /root/payloads/user/remote_access/kb_wire_start; do
  [ -n "$_c" ] && [ -f "$_c/wired.sh" ] && { SRC="$_c"; break; }
done
DIR=${KB_WIRE_DIR:-/root/kbwire}
RIGCONF_FILE=${KB_WIRE_RIGCONF:-/root/kbwire/rig.conf}
mkdir -p "$DIR" 2>/dev/null || { LOG red "no writable $DIR"; ALERT "Flash write failed"; exit 0; }

# already live? (watchdog running = wire up) - cancel path is first-class
if ps | grep "$DIR/wired.sh" | grep -qv grep; then   # DIR-bound, not literal
  LOG yellow "wire already live (watchdog running) - use KB Wire Stop first"
  ALERT "Wire already live"; exit 0
fi

RIG=${KB_WIRE_RIG:-}
if [ -z "$RIG" ] && [ -f "$RIGCONF_FILE" ]; then
  RIG=$(awk -F= '/^RIG=/{print $2}' "$RIGCONF_FILE" 2>/dev/null)
fi
if [ -z "$RIG" ]; then
  LOG red "rig not configured - write RIG=user@host to $RIGCONF_FILE"
  LOG red "(optional PORT= and SSHP= on later lines; or KB_WIRE_RIG env)"
  ALERT "No rig configured"; exit 0
fi
PORT=${KB_WIRE_PORT:-$(awk -F= '/^PORT=/{print $2}' "$RIGCONF_FILE" 2>/dev/null)}
PORT=${PORT:-2222}
SSHP=${KB_WIRE_SSHP:-$(awk -F= '/^SSHP=/{print $2}' "$RIGCONF_FILE" 2>/dev/null)}
SSHP=${SSHP:-22}
case "$PORT" in ''|*[!0-9]*) PORT=2222;; esac
case "$SSHP" in ''|*[!0-9]*) SSHP=22;; esac

# engagement window: env or 72h default; decimal hours allowed (awk math)
HRS=${KB_WIRE_HOURS:-72}
case "$HRS" in ''|*[!0-9.]*) HRS=72;; esac
HOK=$(awk -v h="$HRS" 'BEGIN{print (h+0>0 && h+0<2000) ? 1 : 0}')
[ "$HOK" = "1" ] || HRS=72
WD=${KB_WIRE_WD:-30}
case "$WD" in ''|*[!0-9]*) WD=30;; esac
EXP=$(awk -v h="$HRS" 'BEGIN{print systime()+int(h*3600)}')
NOW=$(date +%s)
[ "$NOW" -lt "$EXP" ] || { LOG red "bad window (expiry not in future)"; ALERT "Bad window"; exit 0; }

# persistence choice - the operator decides; expiry enforces what they forget
if [ -n "${KB_WIRE_PERSIST:-}" ]; then
  PERSIST=$KB_WIRE_PERSIST
else
  PICK=$(LIST_PICKER "Persistence" "Session only (reboot kills wire)" "Survive reboot (rc.d; expiry still enforced)") || {
    LOG red "cancelled by user - nothing started"; exit 0; }
  PERSIST=0; case "$PICK" in *urvive*) PERSIST=1;; esac
fi
case "$PERSIST" in 0|1) :;; *) PERSIST=0;; esac

# ephemeral wire identity: created once per dir, destroyed by Stop/immolation
if [ ! -f "$DIR/wire_key" ]; then
  ssh-keygen -t ed25519 -N "" -C "kbwire-$(date -u +%Y%m%d)" -f "$DIR/wire_key" >/dev/null 2>&1 \
    || { LOG red "ssh-keygen failed"; ALERT "No key"; exit 0; }
  LOG green "wire identity minted (ed25519): $DIR/wire_key"
fi
PTGT=${KB_WIRE_PTGT:-$(awk -F= '/^PTGT=/{print $2}' "$RIGCONF_FILE" 2>/dev/null)}
PTGT=${PTGT:-127.0.0.1}
case "$PTGT" in [0-9]*.[0-9]*.[0-9]*.[0-9]*|[A-Za-z0-9._-]*) :;; *) PTGT=127.0.0.1;; esac
LOG cyan "rig: $RIG   forward: rig:127.0.0.1:$PORT -> $PTGT sshd   window: ${HRS}h"
LOG yellow "first wire to this rig? install the public key rig-side:"
LOG cyan "  $(cat "$DIR/wire_key.pub")"

# mechanism: wired.sh (no UI - also runs from rc.d at boot, self-immolates)
if [ -z "$SRC" ]; then
  LOG red "wired.sh not found beside payload (checked KB_WIRE_SRC, dirname\$0, PWD, canonical path)"
  LOG red "re-push payloads/kb_wire_start/ to the payload dir"
  ALERT "Install broken"; exit 0
fi
cp "$SRC/wired.sh" "$DIR/wired.sh" 2>/dev/null \
  || { LOG red "cannot copy wired.sh from $SRC (flash write failed?)"; ALERT "Install broken"; exit 0; }
ash -n "$DIR/wired.sh" 2>/dev/null || { LOG red "wired.sh failed syntax check"; ALERT "Install broken"; exit 0; }
{
  echo "DIR=$DIR"
  echo "RIG=$RIG"
  echo "PORT=$PORT"
  echo "WD=$WD"
  echo "EXP=$EXP"
  echo "PERSIST=$PERSIST"
  echo "SSHP=$SSHP"
  echo "PTGT=$PTGT"
} > "$DIR/wired.conf" || { LOG red "cannot write wired.conf"; ALERT "Flash write failed"; exit 0; }

if [ "$PERSIST" = "1" ]; then
  printf '#!/bin/sh\n[ -f %s/wired.conf ] && ( setsid sh %s/wired.sh %s/wired.conf & )\n' \
    "$DIR" "$DIR" "$DIR" > /etc/rc.d/S99kbwire && chmod +x /etc/rc.d/S99kbwire \
    || { LOG red "rc.d entry failed - falling back session-only"; PERSIST=0;
         sed -i 's/^PERSIST=.*/PERSIST=0/' "$DIR/wired.conf" 2>/dev/null; }
  [ "$PERSIST" = "1" ] && LOG green "boot persistence armed (/etc/rc.d/S99kbwire; expiry-immolate still active)"
fi

rm -f "$DIR/wired.log"; touch "$DIR/wired.log" 2>/dev/null
KB_WIRE_INTERACTIVE=1 setsid sh "$DIR/wired.sh" "$DIR/wired.conf" >/dev/null 2>&1 &

# wait for the mechanism's own verdict (canary-backed; never trust 'process started')
i=0; VERDICT=""
while [ $i -lt 24 ]; do
  sleep 2; i=$((i+1))
  grep -q "WIRE_READY" "$DIR/wired.log" 2>/dev/null && { VERDICT=READY; break; }
  grep -q "WIRE_FAIL\|WIRE_CANARYFAIL" "$DIR/wired.log" 2>/dev/null && { VERDICT=FAIL; break; }
done
if [ "$VERDICT" != "READY" ]; then
  LOG red "wire NOT established (rig unreachable or key not authorized)"
  tail -3 "$DIR/wired.log" 2>/dev/null | sed 's/^/[LOG]   /'
  if grep -q "WIRE_CANARYFAIL" "$DIR/wired.log" 2>/dev/null; then
    LOG red "canary refused: forward did NOT answer as pager sshd - wire not claimed live, nothing to clean but this dir"
  else
    LOG yellow "fix: rig-side  tools/kb_wire/kbwire_rig.sh install <pubkey>  then start again"
  fi
  ALERT "Wire failed"; exit 0
fi

P=$(cat "$DIR/port.now" 2>/dev/null)
LOG green "WIRE LIVE: $RIG :127.0.0.1:$P -> pager sshd (canary-verified loop)"
LOG cyan "from the rig:  ssh -p $P -o StrictHostKeyChecking=accept-new root@127.0.0.1"
LOG yellow "watchdog every ${WD}s; self-immolate at window end; Stop = KB Wire Stop"
LOG yellow "rig-side off-switch (true kill): tools/kb_wire/kbwire_rig.sh remove"
VIBRATE "Wire:d=6,o=6,b=250:r" || LOG yellow "vibrate skipped"
ALERT "Wire live :$P"
exit 0
