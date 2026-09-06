# KB Recon Payloads — WiFi Pineapple Pager

Two original [WiFi Pineapple Pager](https://shop.hak5.org/products/wifi-pineapple-pager) payloads for authorized network reconnaissance, plus the test harness they were built with.

| Payload | Sends packets? | Answers |
|---|---|---|
| **KB NetRecon** | yes (nmap) | *who's home* — fast host + MAC discovery on the joined network |
| **KB GhostRecon** | **zero** | *who lives there and what are they* — passive ARP/mDNS/SSDP/NBNS device profiler |

Both target the network the Pager is currently joined to (its client mode connection), write append-only loot under `/root/loot/`, and handle user-cancel with a clean exit.

## KB NetRecon

v1.1. Discovery with `nmap -sn -PE -PS80,443 -T4` (measured ~11 s vs ~62 s for a plain `-sn` sweep of a /24 on-device), then a dedicated `-PR` ARP pass with `-oN` parsing for near-full MAC coverage. Two modes: full sweep or ARP-cache-only (fast, silent-ish). Loot header carries `net=/iface=/ssid=/mode=/up=/mac=/secs=`.

## KB GhostRecon

v1.0. `tcpdump -n -e -l -A` on the joined interface for 30/60/90 s filtering to `arp or (udp and (port 5353 or 1900 or 137 or 68))` — **nothing is ever transmitted.** Parses the ambient chatter into one row per MAC: `MAC | IP | vendor | class | instance-name | service-tokens`, resolved against the on-device `nmap-mac-prefixes` OUI table. Service classes currently recognized: Meta Quest VR, Chromecast/Google, Apple Mac/Catalyst, NVIDIA SHIELD, Android/Chrome, Xfinity/UPnP gateway, Smart TV/DIAL, Windows/SMB (NBNS).

Sample loot line:

```
192.168.99.22|5c:ff:35:...|Wistron|Meta Quest VR|testBox|oculusal_sp._tcp.local nvstream._tcp.local SSDP:dial
```

GhostRecon is the yin to NetRecon's yang: invisible to IDS/firewall logs, and it still identifies devices on guest networks with client isolation where active sweeps go half-blind.

## Install

Copy the payload directory to the Pager:

```sh
scp -r payloads/kb_ghostrecon root@172.16.42.1:/root/payloads/user/general/
ssh root@172.16.42.1 'ash -n /root/payloads/user/general/kb_ghostrecon/payload.sh'   # syntax gate
```

It appears in the Payloads menu under *general*. Loot: `/root/loot/kb_<name>.txt`.

## Test harness (`harness/`)

The payloads are DuckyScript-flavored BusyBox ash with Pager UI commands (`LOG`, `LIST_PICKER`, `ALERT`, `VIBRATE`, spinners). `harness/` runs the **actual payload files unmodified** under `busybox ash` with a shim for the UI layer and deterministic mocks for `nmap`/`ip`/`tcpdump`, driven by a fixture directory:

```sh
cd harness && ./test_all.sh
# 8/8 PASS expected: full-sweep, arp-mode, cancel, zero-hosts (netrecon)
#                  + full-listen, quiet-network, no-route, cancel (ghostrecon)
```

Every payload ships with four required green paths: happy path, cancel → exit 0, "not joined to a network", and zero-results stated explicitly (never a silent empty report).

Harness gotchas learned the hard way, encoded in the code:
- BusyBox applets shadow PATH mocks — `ip` must be mocked as a **shell function** (functions beat applets).
- `tcpdump` is *not* an applet, so its mock works via PATH normally.
- Picker answers are UI labels (`"60 s"`), not integers — strip before `$(( ))`.
- `VIBRATE` with no args exits 1 and the UI shows "experienced an error" — always pass a pattern.

`fixtures/gr/cap.txt` is a sanitized capture: real MACs replaced (OUI prefix kept), IPs moved to `192.168.99.0/24`, hostnames/IDs hashed. No real network data ships with this repo.

## Vantage discipline

Scan results depend on raw-socket privilege and network location. A sweep from a wired host, a WiFi client, and an unprivileged container over the same L2 will find different numbers of hosts — report *vantage* (privilege + location) alongside any finding. The Pager's own loot headers exist for exactly this reason.

## Disclaimer

These tools are for **education, authorized auditing, and analysis where permitted**, subject to local and international law. Get explicit written authorization before running either payload against any network you do not own. Users are solely responsible for compliance.

## Attribution

WiFi Pineapple Pager, DuckyScript, and the Pager firmware are intellectual property of Hak5 LLC. The harness UI shim derives from `pager_ducky_shim.sh` in [hak5/wifipineapplepager-payloads](https://github.com/hak5/wifipineapplepager-payloads); the payloads, mocks, fixtures, and testing methodology here are original. Not affiliated with or endorsed by Hak5.
