#!/bin/sh
# kbproto.sh — KBP v1 frame encoder (pure functions; no UI, no side effects).
# Sourceable by the rotator, testable standalone in the harness and on-device.
#
# KBP v1 = "KB Page" manufacturer-specific advertising frame:
#   adv_data = 020106 <len> ff ffff 4b4250 01 <seq> <total> <text...>
#   | 020106  = standard Flags AD (LE general discoverable, BR/EDR unsupported)
#   | <len>   = AD length: 9 + T (bytes after the length byte)
#   | ff      = AD type 0xFF (manufacturer specific data)
#   | ffff    = company id 0xFFFF — BT SIG reserved/test, our non-colliding lane
#   | 4b4250  = magic "KBP" + 01 = protocol version 1
#   | seq     = frame index 0..255 (wraps), total = frames per message cycle
#   | text    = T printable ASCII chars (sanitized upstream: tr -cd ' -~')
# Budget: 3 + 1 + (9+T) <= 31 -> T <= 18 chars/frame (36 hex chars).
#
# usage (pure): KBP_SEQ=0 KBP_TOTAL=1 kbp_encode "HELLO" -> adv_data hex on stdout

KBP_MAGIC="4b425001"        # "KBP" + version 1
KBP_PREFIX="020106"          # flags AD
KBP_CID="ffff"               # company id 0xFFFF (reserved test lane), little-endian
KBP_MAXCHARS=18              # payload chars per frame

kbp_hex() { # text -> lowercase hex of its bytes.
  # NO od/xxd ON DEVICE (false-clean catch 2026-10-10: my probe pipe-masked
  # od's failure behind head; host has od, musl image does NOT). Uses only
  # primitives verified present+working on-device: ash ${#var}, cut -c N,
  # printf '%02x' "'C" char-numeric quoting (proven: 'A -> 41, 'S -> 53).
  _s=$1; _h=""; _i=1
  while [ "$_i" -le ${#_s} ]; do
    _c=$(printf '%s' "$_s" | cut -c"$_i")
    _h=$_h$(printf '%02x' "'$_c")
    _i=$((_i+1))
  done
  printf '%s' "$_h"
}

kbp_encode() { # $1=text-fragment  env KBP_SEQ KBP_TOTAL -> adv hex ("" if bad input)
  _t=$1
  _seq=${KBP_SEQ:-0}
  _tot=${KBP_TOTAL:-1}
  _th=$(kbp_hex "$_t")
  _T=$(( ${#_th} / 2 ))
  [ "$_T" -ge 1 ] || return 1
  _T=$(( _T > KBP_MAXCHARS ? KBP_MAXCHARS : _T ))
  _th=$(printf '%s' "$_th" | cut -c1-$((_T * 2)))
  _len=$(printf '%02x' $(( 9 + _T )))
  _seqh=$(printf '%02x' $(( _seq % 256 )))
  _toth=$(printf '%02x' $(( _tot % 256 )))
  printf '%s%sff%s%s%s%s%s\n' "$KBP_PREFIX" "$_len" "$KBP_CID" "$KBP_MAGIC" "$_seqh" "$_toth" "$_th"
}
