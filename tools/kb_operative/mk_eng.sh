#!/bin/bash
# KB Operative mk_eng v1.0 - create a scoped engagement. The scope document
# BECOMES configuration: cidrs + expiry are machine-enforced from here on.
# usage: mk_eng.sh <name> <scope-cidr>[,<cidr>...] <hours> ["notes"]
set -u
ROOT=${KB_OP_ROOT:-$HOME/kbop}
if [ $# -lt 3 ]; then echo "usage: mk_eng.sh <name> <cidrs> <hours> [notes]"; exit 1; fi
NAME=$1; SCOPE=$2; HOURS=$3; NOTES=${4:-}
if [ -e "$ROOT/$NAME" ]; then echo "FAIL: engagement $NAME exists"; exit 1; fi
mkdir -p "$ROOT/$NAME/targets" "$ROOT/$NAME/beacons"
TK=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
if [ ${#TK} -lt 16 ]; then echo "FAIL: token entropy too low (${#TK} chars)"; exit 1; fi
EXPIRY=$(python3 -c "import time; print(int(time.time()+ $HOURS*3600))")
{
  echo "# scoped engagement - authorization must exist in writing BEFORE this line"
  echo "NAME=$NAME"
  echo "SCOPE=$SCOPE"
  echo "EXPIRY=$EXPIRY"
  echo "PHRASE=$TK"
  echo "CREATED=$(date -u +%FT%TZ)"
  printf 'NOTES=%q\n' "$NOTES"
} > "$ROOT/$NAME/engagement.conf"
chmod 600 "$ROOT/$NAME/engagement.conf"
echo "OK: engagement $NAME scope=$SCOPE expires=$(date -u -d @$EXPIRY +%FT%TZ)"
echo "    token written to engagement.conf (600) - pass to agent via env, never the repo"
echo "    deploy: place an agent COPY per host; start it with KB_URL, KB_ENG, and KB_PH set to the phrase stored in engagement.conf"
