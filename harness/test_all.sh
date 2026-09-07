#!/bin/bash
# test_all.sh — run every payload through every harness path. One command, CI-able.
# Exit 0 = all paths green. Requires: busybox (ash).
# Usage: ./test_all.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FIX="$HERE/fixtures"
PAY="$HERE/../payloads"
pass=0; fail=0

# run <label> <expect-regex> ENV=... [ENV=...] -- <payload.sh> [payload args...]
run() {
  local label="$1" expect="$2"; shift 2
  local envs=() args=() seen_sep=0 a
  for a in "$@"; do
    if [ "$seen_sep" = 0 ] && [ "$a" = "--" ]; then seen_sep=1; continue; fi
    if [ "$seen_sep" = 0 ]; then envs+=("$a"); else args+=("$a"); fi
  done
  local out rc
  out=$(env "${envs[@]}" "$HERE/run_payload.sh" "${args[@]}" 2>&1); rc=$?
  if echo "$out" | grep -q "$expect" && [ $rc -eq 0 ]; then
    echo "PASS  $label"; pass=$((pass+1))
  else
    echo "FAIL  $label (rc=$rc, expected /$expect/)"; echo "$out" | tail -5; fail=$((fail+1))
  fi
}

NR="$PAY/kb_netrecon/payload.sh"
GR="$PAY/kb_ghostrecon/payload.sh"
NRMOCK_PATH="$HERE/mocks/netrecon/bin:$PATH"
GRMOCK_PATH="$HERE/mocks/ghostrecon/bin:$PATH"

echo "== kb_netrecon =="
run "full sweep"     "NetRecon: .* hosts" NR_MOCK_DIR="$FIX/nr" MOCK_DIR=$(mktemp -d /tmp/mock.XXXX) PATH="$NRMOCK_PATH" -- "$NR" --answers "LIST_PICKER=Full sweep (nmap)"
run "arp-cache mode" "hosts"              NR_MOCK_DIR="$FIX/nr" MOCK_DIR=$(mktemp -d /tmp/mock.XXXX) PATH="$NRMOCK_PATH" -- "$NR" --answers "LIST_PICKER=ARP cache (fast)"
run "cancel"         "cancelled by user"  NR_MOCK_DIR="$FIX/nr" MOCK_DIR=$(mktemp -d /tmp/mock.XXXX) PATH="$NRMOCK_PATH" -- "$NR" --cancel-first
run "zero hosts"     "0 hosts responded"  NR_MOCK_DIR=$(mktemp -d /tmp/mock.XXXX) MOCK_DIR=$(mktemp -d) PATH="$NRMOCK_PATH" -- "$NR" --answers "LIST_PICKER=Full sweep (nmap)"

echo "== kb_ghostrecon =="
run "full listen"   "devices seen"  GR_MOCK_DIR="$FIX/gr" MOCK_DIR=$(mktemp -d /tmp/mock.XXXX) PATH="$GRMOCK_PATH" -- "$GR" --answers "LIST_PICKER=60 s"
run "quiet network" "too quiet"     GR_MOCK_DIR="$FIX/gr" GR_MOCK_QUIET=1 MOCK_DIR=$(mktemp -d /tmp/mock.XXXX) PATH="$GRMOCK_PATH" -- "$GR" --answers "LIST_PICKER=30 s"
run "no route"      "No default route" GR_MOCK_DIR="$FIX/gr" GR_MOCK_NO_ROUTE=1 MOCK_DIR=$(mktemp -d /tmp/mock.XXXX) PATH="$GRMOCK_PATH" -- "$GR"
run "cancel"        "cancelled by user" GR_MOCK_DIR="$FIX/gr" MOCK_DIR=$(mktemp -d /tmp/mock.XXXX) PATH="$GRMOCK_PATH" -- "$GR" --cancel-first


echo "== kb_ghostbt =="
GBT="$PAY/kb_ghostbt/payload.sh"
GPATH="$HERE/mocks/ghostbt/bin:$PATH"
: > "$FIX/gbt/calls"
run "BLE scan"          "BLE devices"          GBT_MOCK_DIR="$FIX/gbt" MOCK_DIR=$(mktemp -d) PATH="$GPATH" -- "$GBT" --answers "LIST_PICKER=30 s"
: > "$FIX/gbt/calls"
run "cancel"            "cancelled by user"    GBT_MOCK_DIR="$FIX/gbt" MOCK_DIR=$(mktemp -d) PATH="$GPATH" -- "$GBT" --cancel-first
: > "$FIX/gbt/calls"
run "no adapter"        "no bluetooth adapter" GBT_MOCK_DIR="$FIX/gbt" GBT_NO_ADAPTER=1 MOCK_DIR=$(mktemp -d) PATH="$GPATH" -- "$GBT"
: > "$FIX/gbt/calls"
run "BLE silence"       "air just quiet"       GBT_MOCK_DIR="$FIX/gbtsil" MOCK_DIR=$(mktemp -d) PATH="$GPATH" -- "$GBT" --answers "LIST_PICKER=30 s"

echo "== kb_kickaudit =="
KA="$PAY/kb_kickaudit/payload.sh"
KPATH="$HERE/mocks/kickaudit/bin:$PATH"
run "kick patterns"     "kick patterns"        KA_MOCK_DIR="$FIX/ka" MOCK_DIR=$(mktemp -d) PATH="$KPATH" -- "$KA" --answers "LIST_PICKER=2 minutes"
run "cancel"            "cancelled by user"    KA_MOCK_DIR="$FIX/ka" MOCK_DIR=$(mktemp -d) PATH="$KPATH" -- "$KA" --cancel-first
run "no monitor"        "no monitor interface" KA_MOCK_DIR="$FIX/ka" KA_MOCK_NO_MON=1 MOCK_DIR=$(mktemp -d) PATH="$KPATH" -- "$KA" --answers "LIST_PICKER=2 minutes"
run "dead channel"      "dead channel"         KA_MOCK_DIR="$FIX/ka" KA_MOCK_QUIET=1 MOCK_DIR=$(mktemp -d) PATH="$KPATH" -- "$KA" --answers "LIST_PICKER=2 minutes"

echo "== kb_beacon =="
BCN="$PAY/kb_beacon/payload.sh"
BPATH="$HERE/mocks/beacon/bin:$PATH"
# test-only fast copy: 2 min -> 2 s hold (logic unchanged)
sed 's/SECS=$(( SECS \* 60 ))/SECS=$(( SECS ))/' "$BCN" > /tmp/bcn_fast.sh
rm -rf /tmp/kb_beacon /tmp/bcn_state_t
printf 'alias=BlueZ 5.72\ndisc=no\n' > /tmp/bcn_state_t
run "natural end + restore" "identity restored" BCN_STATE=/tmp/bcn_state_t BCN_SLEEP_STEP=1 MOCK_DIR=$(mktemp -d) PATH="$BPATH" -- /tmp/bcn_fast.sh --answers "LIST_PICKER=Kitchen Scale\nLIST_PICKER=2 min"
rm -f /tmp/bcn_state_c; printf 'alias=BlueZ 5.72\ndisc=no\n' > /tmp/bcn_state_c
run "cancel keeps identity" "nothing changed"   BCN_STATE=/tmp/bcn_state_c MOCK_DIR=$(mktemp -d) PATH="$BPATH" -- "$BCN" --cancel-first

echo "== kb_beacon restore-on-SIGTERM =="
if "$HERE/test_beacon_term.sh" >/tmp/bt_out.$$ 2>&1 && grep -q "RESTORE-ON-TERM: PASS" /tmp/bt_out.$$; then
  echo "PASS  restore-on-SIGTERM"; pass=***
else
  echo "FAIL  restore-on-SIGTERM"; tail -5 /tmp/bt_out.$$; fail=$((fail+1))
fi
rm -f /tmp/bt_out.$$ /tmp/bcn_fast.sh

echo "== result: $pass pass, $fail fail =="
[ $fail -eq 0 ]
