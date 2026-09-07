#!/bin/bash
# pager_shim.sh — simulate WiFi Pineapple Pager DuckyScript commands on a Linux host.
# Derived from upstream library/user/general/run-in-terminal/pager_ducky_shim.sh
# (hak5/wifipineapplepager-payloads), extended with scripted pickers + device mocks.
#
# WHY THIS EXISTS: it lets us validate payload *logic* (control flow, cancel handling,
# variable quoting, ash compatibility) with no hardware attached.
#
# CRITICAL: BusyBox ash has NO `export -f`. The upstream shim's `export -f` lines are
# bash-only. Under ash you must SOURCE this file into the same shell that runs the
# payload. Do not rely on function export.
#
# Scripting pickers: set MOCK_<CMD>="answer1:answer2:..." before running; each call
# consumes the next answer. Set MOCK_<CMD>_RC=1 to simulate the user pressing BACK
# (cancel) — that is the failure mode most payloads get wrong.

# ---------- UI / LOGGING ----------
LOG() {
  local msg="$*"
  msg=$(echo "$msg" | sed -E 's/^(red|green|blue|yellow|purple|cyan|white|black|orange)[[:space:]]+//I')
  echo "[LOG] $msg"
}
ALERT()  { echo "[ALERT] $*" >&2; }
ERROR_DIALOG() { echo "[ERROR] $*" >&2; return 1; }
PROMPT() { echo "[PROMPT] $*"; }
# Real START_SPINNER emits ONLY the spinner id on stdout (the dialog itself is UI).
# Visual noise must go to stderr or it pollutes `$(START_SPINNER ...)` capture.
START_SPINNER() { echo "[SPIN] $*" >&2; echo "spin-$RANDOM"; }
STOP_SPINNER()  { echo "[SPIN-STOP] ${1:-none}" >&2; }
VIBRATE() {
  # PARITY FIX 2026-09-03: real /usr/bin/VIBRATE with NO arg prints usage and
  # exits 1 (device-verified). Bare `VIBRATE` as a payload's last line makes the
  # whole run exit 1 -> UI shows "experienced an error". Shim must mirror that.
  if [ $# -eq 0 ]; then echo "usage: VIBRATE [rtttl|name]" >&2; return 1; fi
  echo "[VIBE] $*"
}
RINGTONE() { echo "[RING]"; }
BATTERY_PERCENT() { echo "${MOCK_BATTERY:-87}"; }
BATTERY_CHARGING() { echo "false"; }
ENABLE_DISPLAY()  { :; }
DISABLE_DISPLAY() { :; }
DPADLED_CONFIG()  { :; }
WAIT_FOR_BUTTON_PRESS() { echo "[BTN] $*"; }
WAIT_FOR_INPUT() { echo "[WAIT] $*"; }

# ---------- SCRIPTED PICKERS ----------
# Answers come from files, NOT shell variables, because payloads call pickers as
#   __x=$(LIST_PICKER ...)
# which runs the function in a SUBSHELL: any variable it mutates is lost when the
# subshell exits, so successive pickers would hand back the same first answer forever.
# A file survives the subshell, so the queue actually advances.
MOCK_DIR="${MOCK_DIR:-/tmp/pager_mock}"
mkdir -p "$MOCK_DIR"

__mock_answer() {
  cmd="$1"; rc="${2:-0}"
  q="$MOCK_DIR/$cmd"
  if [ ! -s "$q" ]; then
    # No scripted answer left: behave like a *cancel*. Deliberate — an unscripted
    # picker must NOT silently return empty and let the payload sail straight through.
    echo "mock: no scripted answer left for $cmd; simulating BACK/cancel" >&2
    return 1
  fi
  # pop first line, rewrite remainder (portable; no sed -i, no head -c)
  ans="$(head -n 1 "$q")"
  total="$(wc -l < "$q" | tr -d ' ')"
  if [ "$total" -le 1 ]; then : > "$q"; else tail -n +2 "$q" > "$q.new"; mv "$q.new" "$q"; fi

  if [ "$rc" -ne 0 ]; then echo "User cancelled."; return "$rc"; fi
  # honour a per-call cancel token in the answer itself: "!cancel"
  if [ "$ans" = "!cancel" ]; then echo "User cancelled."; return 1; fi
  echo "$ans"
  return 0
}

LIST_PICKER()     { __mock_answer LIST_PICKER     "${MOCK_LIST_PICKER_RC:-0}"; }
TEXT_PICKER()     { __mock_answer TEXT_PICKER     "${MOCK_TEXT_PICKER_RC:-0}"; }
NUMBER_PICKER()   { __mock_answer NUMBER_PICKER   "${MOCK_NUMBER_PICKER_RC:-0}"; }
IP_PICKER()       { __mock_answer IP_PICKER       "${MOCK_IP_PICKER_RC:-0}"; }
MAC_PICKER()      { __mock_answer MAC_PICKER      "${MOCK_MAC_PICKER_RC:-0}"; }
FILE_PICKER()     { __mock_answer FILE_PICKER     "${MOCK_FILE_PICKER_RC:-0}"; }
TIME_PICKER()     { __mock_answer TIME_PICKER     "${MOCK_TIME_PICKER_RC:-0}"; }
CREDENTIAL_PICKER(){ __mock_answer CREDENTIAL_PICKER "${MOCK_CREDENTIAL_PICKER_RC:-0}"; }
CONFIRMATION_DIALOG() { __mock_answer CONFIRMATION_DIALOG "${MOCK_CONFIRMATION_DIALOG_RC:-0}"; }

# ---------- CONFIG STORE (persisted across runs in one file) ----------
PAGER_MOCK_CONFIG="${PAGER_MOCK_CONFIG:-/tmp/pager_mock_config}"
touch "$PAGER_MOCK_CONFIG"
# NOTE: '|' is both the key delimiter and a sed delimiter in a naive impl — use '@'.
__cfg_del() { grep -v "^$1|$2=" "$PAGER_MOCK_CONFIG" > "${PAGER_MOCK_CONFIG}.tmp" 2>/dev/null || true; mv "${PAGER_MOCK_CONFIG}.tmp" "$PAGER_MOCK_CONFIG" 2>/dev/null || true; }
PAYLOAD_GET_CONFIG() {
  line="$(grep -m1 "^$1|$2=" "$PAGER_MOCK_CONFIG" 2>/dev/null)" || return 1
  [ -n "$line" ] || return 1
  echo "${line#*=}"
  return 0
}
PAYLOAD_SET_CONFIG() { __cfg_del "$1" "$2"; echo "$1|$2=$3" >> "$PAGER_MOCK_CONFIG"; }
PAYLOAD_DEL_CONFIG() { __cfg_del "$1" "$2"; }

# ---------- DEVICE / RADIO MOCKS (deterministic fake RF environment) ----------
# 'ush' is the real device shell binary; alias it to ash for parity checks.
ush() { busybox ash -c "$*"; }

# SCRIPT_MOCK_<CMD>: seed the answer queue from the environment, one answer per line.
# Call this from run_payload.sh so callers can script answers with plain env vars.

WIFI_SCAN_AP() {
  echo "B8:27:EB:11:22:33|DevboxLab-2G|WPA2|31|-62|2.4"
  echo "AA:BB:CC:DD:EE:01|corp-office|WPA2|6|-48|5"
  echo "DE:AD:BE:EF:00:01|Hak5|WPA3|44|-77|5"
}
WIFI_SCAN_CLIENT() { echo "9C:B2:08:AA:BB:CC|B8:27:EB:11:22:33|DevboxLab-2G|-58"; }
WIFI_SET_CHANNEL() { echo "[MOCK] channel set $*"; }
WIFI_TRANSMIT_PROBE_REQ() { echo "[MOCK] probe req sent $*"; }
WIFI_TRANSMIT_DEAUTH() { echo "[MOCK] deauth frame built (NOT sent in harness) $*"; }
WIFI_CURRENT_CHANNEL() { echo "6"; }

RECON_STATUS() { echo "running"; }
RECON_START()  { echo "[MOCK] recon start"; }
RECON_STOP()   { echo "[MOCK] recon stop"; }
RECON_AP_SCAN(){ echo "[MOCK] ap scan $*"; }
PINEAP_CLEAR_KNOWN_NETWORKS() { echo "[MOCK] pineap cleared networks"; }
DISK_TOTAL()   { echo "14680064"; }
DISK_FREE()    { echo "9102336"; }
DISK_USED()    { echo "5577728"; }
DISK_PERCENT() { echo "38"; }

# ---------- APPLET INTERCEPTION MOCKS ----------
# BusyBox ash runs a built-in applet when its name is entered — `ip` here is the
# busybox applet, so PATH-first mocks named `ip` are never reached (found
# 2026-09-05 while testing kb_netrecon). Shell functions beat applets (precedent:
# LOG), so mock-capable commands get a conditional function here. Only defined
# when the caller sets NR_MOCK_DIR, so other payloads keep real applets.
if [ -n "${NR_MOCK_DIR:-}" ]; then
  __NR_IP_MOCK="${SHIM_DIR:-.}/mocks/netrecon/bin/ip"
  ip() { "$__NR_IP_MOCK" "$@"; }
fi

# Same applet-collision rule for kb_ghostrecon: `ip` must be a function, not a
# PATH mock. tcpdump is NOT an applet (verified via busybox --list) so its mock
# resolves through PATH normally.
if [ -n "${GR_MOCK_DIR:-}" ]; then
  __GR_IP_MOCK="${SHIM_DIR:-.}/mocks/ghostrecon/bin/ip"
  ip() { "$__GR_IP_MOCK" "$@"; }
fi

# Same applet-collision rule for kb_kickaudit (ip used for iface + neigh checks).
if [ -n "${KA_MOCK_DIR:-}" ]; then
  __KA_IP_MOCK="${SHIM_DIR:-.}/mocks/kickaudit/bin/ip"
  ip() { "$__KA_IP_MOCK" "$@"; }
fi
