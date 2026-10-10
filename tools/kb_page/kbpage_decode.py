#!/usr/bin/env python3
"""kbpage_decode.py — rig-side listener/reassembler for KBP v1 BLE frames.

Reassembles messages from KB Page advertisements (see kbproto.sh for the
frame):

  020106 <len> ff ffff 4b425001 <seq> <total> <text...>
   ^bytes: 0-2    3   4  5-6     7-10      11     12     13..12+T   (T = len-9)

The len byte BOUNDS the text slice — btmon blobs carry trailing pad bytes and
header junk after the frame; anything beyond 12+T is never part of the message.

Handles both shapes of input:
  - solid-hex lines (a captured frames.log)
  - btmon output, where the AD hex WRAPS ACROSS continuation lines — hex runs
    accumulate in a rolling buffer until a non-hex line breaks the record;
    the frame start is located exactly (magic always sits at char 14 of a
    frame), so candidates are taken at magic-14 and verified by decode().

Dedupe: the rotator re-broadcasts the whole message every cycle; first
sighting per (seq,text) wins; a total change or same-seq-new-text resets
assembly (new message).

usage:
  btmon | tools/kb_page/kbpage_listen.sh                     # live (BT adapter)
  cat frames.log | python3 tools/kb_page/kbpage_decode.py   # replay

Local, offline, no network. For authorized listening on your own air.
"""
import re
import signal
import sys

if hasattr(signal, "SIGPIPE"):
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)

MAGIC = bytes.fromhex("4b425001")          # "KBP" + version 1
MAGIC_CH = 14                              # magic char offset inside a frame
HEXRUN = re.compile(r"(?:[0-9a-fA-F]{2}[ :]?)+")
PURE_HEX = re.compile(r"^\s*(?:[0-9a-fA-F]{2}[ ]?)+\s*$")


def decode(h):
    """Clean frame hex (possibly with trailing junk) -> (seq,total,text) or None."""
    try:
        b = bytes.fromhex(h[: (12 + 62) * 2])   # generous cap; bounds below
    except ValueError:
        return None
    if len(b) < 14:
        return None
    if b[0:3] != bytes.fromhex("020106") or b[4] != 0xFF or b[5:7] != b"\xff\xff":
        return None
    if b[7:11] != MAGIC:
        return None
    T = b[3] - 9
    if not (1 <= T <= 18):
        return None
    if len(b) < 13 + T:
        return None
    seq, total = b[11], b[12]
    if total < 1 or seq >= total:
        return None
    try:
        s = b[13:13 + T].decode("ascii")
    except UnicodeDecodeError:
        return None
    if not s or not all(32 <= ord(c) <= 126 for c in s):
        return None
    return seq, total, s


def scan(buf, out):
    """Emit every decodable frame candidate in accumulated hex `buf`."""
    i = 14
    while True:
        j = buf.find(MAGIC.hex(), i)
        if j < 14:
            break
        d = decode(buf[j - MAGIC_CH:])
        if d:
            out.append(d)
            i = j + len(MAGIC) * 2
        else:
            i = j + 2


def main():
    seen = {}
    cur_total = None
    hexbuf = ""

    def emit(d):
        nonlocal seen, cur_total
        seq, total, text = d
        if cur_total is not None and total != cur_total:
            seen, cur_total = {}, None
        if seq in seen:
            if seen[seq] == text:
                return
            seen, cur_total = {}, None
        seen[seq] = text
        cur_total = total
        print(f"[frame {seq}/{total}] {text!r}", flush=True)
        if len(seen) == cur_total:
            full = "".join(seen[i] for i in sorted(seen))
            print(f"=== MESSAGE ({cur_total} frames): {full!r} ===", flush=True)
            seen, cur_total = {}, None

    for line in sys.stdin:
        line = line.rstrip("\n")
        if PURE_HEX.match(line):
            hexbuf += re.sub(r"[^0-9a-fA-F]", "", line).lower()
            found = []
            scan(hexbuf, found)
            for d in found:
                emit(d)
            if len(hexbuf) > 240:
                hexbuf = hexbuf[-64:]      # keep frame-start tail; dedupe covers repeats
        else:
            hexbuf = ""
            for m in HEXRUN.finditer(line):
                h = re.sub(r"[^0-9a-fA-F]", "", m.group(0)).lower()
                found = []
                scan(h, found)
                for d in found:
                    emit(d)
    return 0


if __name__ == "__main__":
    sys.exit(main())
