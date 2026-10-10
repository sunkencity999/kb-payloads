#!/bin/sh
# kbpage_listen.sh — rig-side live listener for KB Page broadcasts.
# btmon (comes with bluez on Ubuntu) captures the local adapter's HCI stream;
# the decoder reassembles KBP v1 frames into messages. Local, offline.
#
# needs: a Bluetooth adapter on the listening machine (Devbox2 has NONE —
# plug any $5 USB dongle in, or run this on a laptop/ Pi with BT).
# usage: sudo ./kbpage_listen.sh           (btmon needs access to hci monitor)
#        KBP_DEV=hci1 ./kbpage_listen.sh   (pick adapter)
set -u
DEC="$(dirname "$0")/kbpage_decode.py"
[ -f "$DEC" ] || { echo "kbpage_decode.py missing next to me"; exit 1; }
command -v btmon >/dev/null 2>&1 || { echo "btmon missing (apt install bluez)"; exit 1; }
if [ ! -d /sys/class/bluetooth ] || [ -z "$(ls -A /sys/class/bluetooth 2>/dev/null)" ]; then
  echo "no Bluetooth adapter visible (/sys/class/bluetooth empty) - plug in a dongle"
  echo "replay mode works anywhere:  cat frames.log | python3 kbpage_decode.py"
  exit 1
fi
if command -v btmon >/dev/null && [ ! -r /dev/vhci ] && [ "$(id -u)" != 0 ]; then
  echo "note: btmon usually needs root for the monitor socket; sudo if it hangs silent"
fi
DEV=${KBP_DEV:-}
if [ -n "$DEV" ]; then btmon -i "$DEV" 2>/dev/null | python3 "$DEC"
else btmon 2>/dev/null | python3 "$DEC"; fi
