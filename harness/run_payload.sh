#!/bin/bash
# run_payload.sh — run a Pager payload under BusyBox ash with the mock shim loaded.
#
# Usage:
#   ./run_payload.sh path/to/payload.sh
#   ./run_payload.sh payload.sh --answers 'LIST_PICKER=Scan\nTEXT_PICKER=myssid'
#   ./run_payload.sh payload.sh --cancel-first        # simulate user pressing BACK
#
# Why `busybox ash` and not bash: the Pager runs BusyBox ash. ash has no arrays, no
# `[[ ]]`, no `${!var}` indirect expansion, and no `export -f`. Anything that only
# works in bash must fail HERE, on the host, before we ever touch the device.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD="${1:-}"; shift || true
[ -n "$PAYLOAD" ] || { echo "usage: $0 path/to/payload.sh [--answers '...'] [--cancel-first]"; exit 2; }

export MOCK_DIR="$(mktemp -d)"
trap 'rm -rf "$MOCK_DIR"' EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    --answers)
      shift
      # format: CMD=value lines; each CMD's lines become its scripted answer queue
      printf '%b\n' "$1" | while IFS='=' read -r cmd val; do
        [ -n "$cmd" ] || continue
        printf '%s\n' "$val" >> "$MOCK_DIR/$cmd"
      done
      shift ;;
    --cancel-first)
      # The single most important test: user hits BACK on the first picker.
      printf '!cancel\n' >> "$MOCK_DIR/LIST_PICKER"
      printf '!cancel\n' >> "$MOCK_DIR/TEXT_PICKER"
      printf '!cancel\n' >> "$MOCK_DIR/CONFIRMATION_DIALOG"
      shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Device-provided environment
export PAYLOAD_HOME="$(cd "$(dirname "$PAYLOAD")" && pwd)"
export _PAYLOAD_HOME="$PAYLOAD_HOME"
export PAGER_VERSION="${PAGER_VERSION:-1.1.0-mock}"
export PAGER_HARDWARE="${PAGER_HARDWARE:-pager-1}"

echo "### harness: busybox $(busybox | head -1 | awk '{print $2}'), shell=ash"
export SHIM_DIR="$HERE"   # shim uses this to locate mocks/ (ash has no BASH_SOURCE)
echo "### payload: $PAYLOAD"
echo "### mock answers:"
if [ -n "$(ls -A "$MOCK_DIR" 2>/dev/null)" ]; then
  for f in "$MOCK_DIR"/*; do printf '  %s -> ' "$(basename "$f")"; tr '\n' ',' < "$f"; echo; done
else
  echo "  (none: every picker will simulate a BACK/cancel)"
fi
echo "### --- output ---"
busybox ash -c ". '$HERE/pager_shim.sh'; . '$PAYLOAD'"
rc=$?
echo "### --- exit code: $rc ---"
exit $rc
