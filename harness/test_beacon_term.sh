#!/bin/bash
# signal-test for kb_beacon: run payload in its own ash (device-like), TERM it
# mid-hold, assert restore. Self-contained: no pkill, exact PID targeting only.
cd "$(cd "$(dirname "$0")" && pwd)"
export PATH="$PWD/mocks/beacon/bin:$PATH"
export BCN_STATE=/tmp/bcn_state BCN_SLEEP_STEP=1 MOCK_DIR SHIM_DIR="$PWD"
MOCK_DIR=$(mktemp -d); export MOCK_DIR
printf 'Pixel 8 Pro\n2 min\n' > "$MOCK_DIR/LIST_PICKER"
printf 'alias=BlueZ 5.72\ndisc=no\n' > "$BCN_STATE"
rm -rf /tmp/kb_beacon

# payload lives beside harness/ in dev layout, one level up in the repo layout
if [ -f "$PWD/payloads/kb_beacon/payload.sh" ]; then PAY="$PWD/payloads/kb_beacon/payload.sh"
elif [ -f "$PWD/../payloads/kb_beacon/payload.sh" ]; then PAY="$PWD/../payloads/kb_beacon/payload.sh"
else echo "PAYMENT-NOT-FOUND FAIL"; exit 1; fi
busybox ash -c ". '$PWD/pager_shim.sh'; . '$PAY'" > /tmp/beacon_term_out.txt 2>&1 &
ASHPID=$!
sleep 8
kill -TERM "$ASHPID" 2>/dev/null
# wait with bound: restore ladder sleeps ~4s worst case
for i in $(seq 1 15); do kill -0 "$ASHPID" 2>/dev/null || break; sleep 1; done
kill -0 "$ASHPID" 2>/dev/null && { echo "STILL RUNNING - killing"; kill -9 "$ASHPID"; }
wait "$ASHPID" 2>/dev/null; rc=$?
echo "== payload output tail =="; tail -4 /tmp/beacon_term_out.txt
echo "== runner rc=$rc =="
echo "== state after TERM (expect alias=BlueZ 5.72, disc=no) =="; cat "$BCN_STATE"
[ -f /tmp/kb_beacon/active ] && echo "MARKER STILL PRESENT (bad)" || echo "marker cleaned (good)"
# PASS requires the beacon ACTUALLY transformed (not a vacuous no-op run) and then restored
grep -q "advertises as: Pixel 8 Pro" /tmp/beacon_term_out.txt   && grep -q "identity restored" /tmp/beacon_term_out.txt   && grep -q "^alias=BlueZ 5.72$" "$BCN_STATE" && grep -q "^disc=no$" "$BCN_STATE"   && echo "RESTORE-ON-TERM: PASS" || echo "RESTORE-ON-TERM: FAIL"
