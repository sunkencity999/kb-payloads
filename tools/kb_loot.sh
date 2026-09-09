#!/bin/bash
# KB Loot v1.0 - verified loot collection (rig side, not a Pager payload).
# The workflow's Phase 6 as one command: enumerate device loot, pull once over
# ssh (tar stream), verify EVERY file byte-exact against a device-side sha256
# manifest (independent of what the payloads themselves hashed), dedupe re-runs
# by content hash against a local ledger, optional verified-clean of only what
# THIS run transferred, optional Drive zip. --local mode = same pipeline against
# a local directory (CI unit hook, no ssh).
#
# Usage: kb_loot.sh [TARGET] [-o OUTDIR] [--clean-verified] [--drive] [--local DIR]
#   TARGET      user@host of the Pager (default KB_PAGER env or root@172.16.52.1)
#   -o OUTDIR   engagement dir root (default ./loot  relative to CWD)
#   --clean-verified  delete remote files ONLY if transferred+verified this run
#   --drive     zip the engagement dir and push via drive_push.sh if available
#   --local DIR run the verify/dedupe pipeline on DIR instead of ssh (test hook)
set -u
TARGET=${KB_PAGER:-root@172.16.52.1}
REMOTE=${KB_LOOT_DIR:-/root/loot}
OUT=${KB_LOOT_OUT:-./loot}
CLEAN=0; DRIVE=0; LOCAL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT=$2; shift 2;;
    --clean-verified) CLEAN=1; shift;;
    --drive) DRIVE=1; shift;;
    --local) LOCAL=$2; shift 2;;
    *) TARGET=$1; shift;;
  esac
done
command -v sha256sum >/dev/null 2>&1 || { echo "FAIL: need sha256sum on rig"; exit 1; }
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUT" || { echo "FAIL: cannot create $OUT"; exit 1; }
LEDGER="$OUT/collected.sha256"; touch "$LEDGER"
RUNDIR="$OUT/pull-$STAMP"; mkdir -p "$RUNDIR"
say(){ printf '%s\n' "$*"; }

# ---- stage 1: get a staged tree + a device-side manifest ----
MANIFEST="$RUNDIR/.remote.sha256"; STAGED=""
if [ -n "$LOCAL" ]; then
  STAGED="$LOCAL"
  if [ -n "${KB_LOOT_FAKE_MANIFEST:-}" ]; then
    # test hook ONLY: verify against an external manifest (exercises BAD path;
    # in normal local mode manifest is computed FROM the staged tree, so local
    # mode structurally cannot detect corruption - that is ssh-mode territory)
    cp "$KB_LOOT_FAKE_MANIFEST" "$MANIFEST"
  else
    (cd "$LOCAL" && find . -type f | sort | while read -r f; do sha256sum "$f"; done) > "$MANIFEST"
  fi
else
  say "== probing $TARGET:$REMOTE =="
  ssh -o ConnectTimeout=10 "$TARGET" "test -d $REMOTE && find $REMOTE -type f | wc -l" \
    || { say "FAIL: cannot reach $TARGET:$REMOTE"; exit 1; }
  say "== device manifest (authoritative, computed before transfer) =="
  ssh "$TARGET" "cd $REMOTE && find . -type f | sort | while read -r f; do sha256sum \"\$f\"; done" > "$MANIFEST" \
    || { say "FAIL: device manifest failed"; exit 1; }
  NDEV=$(grep -c . "$MANIFEST"); say "$NDEV files on device"
  [ "$NDEV" -gt 0 ] || { say "nothing to collect"; exit 0; }
  say "== pulling (tar over ssh, one connection) =="
  ssh "$TARGET" "cd $REMOTE && tar cf - ." | tar xf - -C "$RUNDIR" \
    || { say "FAIL: transfer failed"; exit 1; }
  STAGED="$RUNDIR"
fi

# ---- stage 2: byte-exact verify (rig hashes vs device manifest) ----
say "== verify =="
OKC=0; BADC=0; BADLIST=""; NEWC=0; DUPC=0; TRANSFERRED=""; VERIFIED_ALL=""
while read -r hash path; do
  [ -n "${hash:-}" ] || continue
  if [ -f "$STAGED/$path" ]; then
    L=$(cd "$STAGED" && sha256sum "$path" | awk '{print $1}')
  else
    L="missing"
  fi
  if [ "$L" = "$hash" ]; then
    OKC=$((OKC+1)); VERIFIED_ALL="$VERIFIED_ALL $path"
    if grep -q "^$hash " "$LEDGER" 2>/dev/null; then
      DUPC=$((DUPC+1))
    else
      NEWC=$((NEWC+1))
      echo "$hash $path" >> "$LEDGER"
      TRANSFERRED="$TRANSFERRED $path"
    fi
  else
    BADC=$((BADC+1)); BADLIST="$BADLIST $path"
    say "BAD  $path (device=$hash rig=$L)"
  fi
done < "$MANIFEST"
say "verified OK: $OKC   bad: $BADC   new-to-ledger: $NEWC   dupes (already collected): $DUPC"

# retry pass for BAD (re-scp individually once)
if [ "$BADC" -gt 0 ] && [ -z "$LOCAL" ]; then
  say "== retrying bad files =="
  for p in $BADLIST; do
    scp -q "$TARGET:$REMOTE/$p" "$STAGED/$p" 2>/dev/null
    L=$(cd "$STAGED" && sha256sum "$p" 2>/dev/null | awk '{print $1}')
    D=$(grep -F " $p" "$MANIFEST" | awk '{print $1}')
    if [ "$L" = "$D" ]; then say "OK(retry) $p"; BADC=$((BADC-1));
    else say "STILL-BAD $p - keep on manual list"; fi
  done
fi

# ---- stage 3: engagement summary ----
SUM="$OUT/summary-$STAMP.txt"
{ echo "# KB Loot $STAMP target=$([ -n "$LOCAL" ] && echo local:$LOCAL || echo "$TARGET:$REMOTE")"
  echo "# verified=$OKC bad=$BADC new=$NEWC dupes=$DUPC"
  [ -n "$BADLIST" ] && echo "# BAD:$BADLIST"
  awk '{print $2}' "$MANIFEST" | sort | sed 's/^/  /'
} > "$SUM"

# ---- stage 4: optional verified-clean (ONLY this run's new transfers) ----
if [ "$CLEAN" = "1" ] && [ -z "$LOCAL" ]; then
  # safe for EVERY file verified this run: RUNDIR holds a byte-exact copy of each
  # (that is what verified means here), whether new or dup of a past collection.
  if [ -n "$VERIFIED_ALL" ]; then
    set -- $VERIFIED_ALL; N=$#
    say "== clean-verified: removing $N files (each byte-exact verified this run) =="
    for p in $VERIFIED_ALL; do
      ssh "$TARGET" "rm -f \"$REMOTE/$p\"" || say "WARN: rm failed $p"
    done
  else
    say "== clean-verified: nothing verified this run, device untouched =="
  fi
fi

# ---- stage 5: optional Drive lane ----
if [ "$DRIVE" = "1" ]; then
  ZIP="$OUT/kb-loot-$STAMP.zip"
  (cd "$OUT" && zip -qr "kb-loot-$STAMP.zip" "pull-$STAMP" "collected.sha256" "$(basename "$SUM")") 2>/dev/null \
    && say "zip: $ZIP" || say "WARN: zip failed (or no zip)"
  DP=${KB_DRIVE_PUSH:-$HOME/.openclaw/workspace-smaug/scripts/drive_push.sh}
  if [ -f "$DP" ]; then "$DP" "$ZIP" || say "WARN: drive_push failed (zip still local)"; else say "drive_push.sh not found - zip left local"; fi
fi

[ "$BADC" -eq 0 ] || { say "RESULT: INCOMPLETE ($BADC bad files - do not trust this pull)"; exit 2; }
say "RESULT: CLEAN - engagement dir $OUT (ledger: $LEDGER)"
exit 0
