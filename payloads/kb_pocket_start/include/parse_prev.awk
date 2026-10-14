# parse_prev.awk — extract the wlan0mgmt Management-AP state from
# /etc/config/wireless into 3 lines: ssid / enc / key (blank blanks when off).
# "off" first line = no enabled management AP. Run:
#   awk -F"'" -f parse_prev.awk /etc/config/wireless
# Order-INDEPENDENT: buffers each config wifi-iface block and commits it when
# the NEXT block (or EOF) arrives, so `option ifname 'wlan0mgmt'` may appear
# anywhere in the block (device config witnessed 2026-10-14 has it before the
# ssid; Settings-panel-written blocks differ from hand-written ones — don't
# assume field order ever). Values reach callers as VARIABLES via cut/sed,
# never as composed literals: a key containing " $ ` \ can't corrupt anything.
# Known edge (documented, accepted): a config key containing a literal
# newline cannot exist inside the single quotes of the config format.
function commit() {
  if (hasmgmt) {
    if (dis || ssid == "") { print "off"; print ""; print "" }
    else { print ssid; print enc; print key }
  }
}
/^config wifi-iface/ { commit(); ssid=""; enc=""; key=""; dis=""; hasmgmt=0; next }
/option ifname/ && $2 ~ /wlan0mgmt/ { hasmgmt=1 }
$1 ~ /option ssid/        { ssid=$2 }
$1 ~ /option encryption/  { enc=$2 }
$1 ~ /option key/         { key=$2 }
$1 ~ /option disabled/ && $2 == "1" { dis=1 }
END { commit() }
