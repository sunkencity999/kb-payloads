#!/bin/bash
# Title: KB Portal Install
# Description: One-time setup for KB Portal: installs uhttpd from the OpenWrt repo, generates a captive TLS cert, prepares portal/loot directories. No prompts - safe headless.
# Author: Smaug <smaug@devbox2>
# Category: interception
# Version: 1.0

# Device facts (measured 2026-09-06/07): no web server in stock image; uhttpd IS
# in OpenWrt 24.10.1 repos; opkg install AUTO-ENABLES stock uhttpd on :80 at boot -
# we stop+disable it, the portal payload owns the server. openssl present: cert gen OK.

LOG green "KB Portal Install v1.0"

command -v opkg >/dev/null 2>&1 || { LOG red "opkg missing - cannot install"; ALERT "No opkg"; exit 0; }

ROOTP=${KBP_ROOT:-/root/portals}
NEED_WORK=1
command -v uhttpd >/dev/null 2>&1 && [ -f "$ROOTP/kb_portal.crt" ] && [ -f "$ROOTP/kb_portal.key" ] && NEED_WORK=0

if command -v uhttpd >/dev/null 2>&1; then
  LOG yellow "uhttpd already installed"
else
  LOG cyan "refreshing package lists (~1 min on the NINA link)..."
  SPIN=$(START_SPINNER "opkg update")
  timeout 120 opkg update >/dev/null 2>&1
  STOP_SPINNER "$SPIN"
  if ! opkg info uhttpd >/dev/null 2>&1; then
    LOG red "uhttpd not in repos - check internet (WiFi client mode up?)"
    ALERT "Repo unreachable"
    exit 0
  fi
  LOG cyan "installing uhttpd..."
  opkg install uhttpd >/dev/null 2>&1
  command -v uhttpd >/dev/null 2>&1 || { LOG red "install failed"; ALERT "Install failed"; exit 0; }
fi

# the auto-enabled stock server must NOT boot on its own (device-verified trap)
if [ -x /etc/init.d/uhttpd ]; then
  /etc/init.d/uhttpd stop >/dev/null 2>&1
  /etc/init.d/uhttpd disable >/dev/null 2>&1
  rm -f /etc/rc.d/S50uhttpd /etc/rc.d/K* uhttpd 2>/dev/null
  LOG "stock uhttpd service stopped+disabled (portal payload owns :80)"
fi

mkdir -p "$ROOTP" /root/loot/kb_portal
if [ ! -f "$ROOTP/kb_portal.crt" ] || [ ! -f "$ROOTP/kb_portal.key" ]; then
  LOG cyan "generating captive TLS cert (EC P-256, self-signed, 1 year)..."
  # EC prime256v1: RSA-2048 keygen on this MIPS takes MINUTES (witnessed - hung a
  # test session); EC is instant and uhttpd serves it fine (device-verified 8443=200).
  if command -v openssl >/dev/null 2>&1; then
    timeout 60 openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$ROOTP/kb_portal.key" -out "$ROOTP/kb_portal.crt" -days 365 -nodes \
      -subj "/CN=portal-gateway" >/dev/null 2>&1 \
      && { chmod 600 "$ROOTP/kb_portal.key"; LOG green "cert+key written ($ROOTP/kb_portal.crt)"; } \
      || LOG yellow "cert generation failed - https portal disabled"
  else
    LOG yellow "openssl missing - https portal disabled"
  fi
fi
rm -f "$ROOTP/kb_portal.pem" 2>/dev/null   # old combined-pem layout, obsolete

[ -x /etc/init.d/dnsmasq.hak5 ] || LOG yellow "WARN: /etc/init.d/dnsmasq.hak5 absent - DNS toggle may not work"

LOG green "install complete: $(command -v uhttpd)"
LOG "templates dir: /root/portals   loot: /root/loot/kb_portal"
ALERT "Portal prereqs ready"
exit 0
