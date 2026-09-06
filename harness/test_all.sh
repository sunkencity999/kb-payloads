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

echo "== result: $pass pass, $fail fail =="
[ $fail -eq 0 ]
