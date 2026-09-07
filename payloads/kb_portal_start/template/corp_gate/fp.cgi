#!/bin/sh
# fp.cgi - passive browser fingerprint sink for KB Portal.
# login.cgi posts navigator/screen/locale data here; it is appended to the same
# loot log with source IP. No third-party calls - everything stays on the portal.
LOOTLOG="${LOOTLOG:-/tmp/kbportal_capture.log}"   # /tmp 666 sink: CGI uid cannot traverse /root (700) - Stop archives
B=""
[ "$REQUEST_METHOD" = POST ] && B=$(dd bs=1 count="${CONTENT_LENGTH:-0}" 2>/dev/null)
TS=$(date -u +%FT%TZ)
echo "FP |$TS|ra=$REMOTE_ADDR|ua=${HTTP_USER_AGENT:-}|$B" >> "$LOOTLOG" 2>/dev/null
echo "Content-Type: text/plain"
echo ""
echo ok
