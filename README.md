# KB Recon Payloads — WiFi Pineapple Pager

Original [WiFi Pineapple Pager](https://shop.hak5.org/products/wifi-pineapple-pager) payloads for **authorized** network reconnaissance (plus one game), built and verified with a BusyBox-ash test harness.

| Payload | Transmits? | Question it answers |
|---|---|---|
| **[KB NetRecon](#kb-netrecon)** | yes (nmap probes) | *who's home* — fast host + MAC discovery on the joined network |
| **[KB GhostRecon](#kb-ghostrecon)** | **zero packets** | *who lives there, and what are they* — passive device profiler |
| **[KB GhostBt](#kb-ghostbt)** | **zero packets** | *what BLE is broadcasting around this room* — passive Bluetooth LE wardrive |
| **[KB KickAudit](#kb-kickaudit)** | **zero packets** | *who keeps getting kicked off Wi-Fi, and by whom* — passive 802.11 deauth audit |
| **[KB Hoard Hopper](#games)** | no | a roguelite text crawler (yes, a game ships with the recon) |
| **[KB Beacon](#kb-beacon)** | BLE advertise only | BLE name chameleon with guaranteed identity restore — the one non-passive payload, and it undoes itself |

The recon payloads run against the network the Pager is currently joined to (client mode) or the RF environment around it, append loot to `/root/loot/`, and treat user-cancel as a first-class code path. None of them exfiltrates anything: results land on the Pager's own storage and you collect them yourself.

---

## Contents

```
payloads/kb_netrecon/       payload.sh + _hak5_manifest.json
payloads/kb_ghostrecon/     payload.sh + _hak5_manifest.json
harness/
  run_payload.sh            runs a real payload file under busybox ash + shim
  pager_shim.sh             simulated Pager UI (LOG/pickers/spinner/vibrate)
  test_all.sh               every payload, every path, one command
  mocks/netrecon/bin/       deterministic nmap / ip / iwinfo mocks
  mocks/ghostrecon/bin/     deterministic tcpdump / ip mocks
  fixtures/nr/              netrecon fixture set (up.txt, macmap.txt, neigh.txt)
  fixtures/gr/cap.txt       sanitized tcpdump capture fixture
.github/workflows/test.yml  CI: runs test_all.sh on every push
```

---

## KB NetRecon

**Version 1.1 · active discovery · ~15–20 s per /24**

Two-stage design, each stage tuned against on-device measurements rather than assumptions:

1. **Discovery** — `nmap -sn -n -PE -PS80,443 -T4 $NET -oG -`. ICMP echo plus SYN probes on 80/443 catches hosts that drop ICMP *and* hosts that only answer TCP. Measured on-device: **28 hosts in 11 s** versus **~62 s** for a plain `-sn -T4` sweep of the same /24, same host count. Parsing is `grep "Status: Up" | awk` on `-oG` (greppable) output.
2. **MAC resolution** — a dedicated second pass, `nmap -sn -n -PR <discovered IPs> -oN -`. `-PR` forces ARP resolution; `-oN` (normal) output carries `MAC Address:` lines while `-oG` does **not** — verified on-device, and the reason for the two different output flags. The parsed map is merged with the discovered-IP list, and the now-warmed `ip neigh` table is appended as a fallback for anything the ARP pass missed.

**Modes:**
- *Full sweep (nmap)* — both stages. Finds hosts the ARP cache has never seen.
- *ARP cache (fast)* — reads `ip neigh` only. Sub-second, sends nothing new, useful as a quick look or when you want minimal noise.

**Loot format** (append-only, `/root/loot/kb_netrecon.txt`):

```
=== 2026-09-05T16:11:46Z | v1.1 net=192.168.99.0/24 iface=wlan0cli ssid=<ssid> mode=Full sweep (nmap) up=28 mac=26 secs=19 ===
192.168.99.1 00:11:22:33:44:01
192.168.99.22 00:11:22:33:44:02
...
```

Every run self-documents its vantage in the header: network, interface, SSID, mode, counts, and wall-clock seconds. Compare runs, or runs from different networks, without guessing.

**Measured failure modes this design avoids:**
- Unprivileged `nmap -sn` on Linux silently falls back from ARP to TCP probes and **misses ICMP-only hosts**. Observed as 11 hosts found versus 28 from a privileged vantage. The fix in the companion scanner (`netscan.py`) is to union a ping sweep into the results; on the Pager this is moot since payloads run as root, but the vantage line in the header exists because it *was* observed.
- `ip neigh` alone resolves only a fraction of MACs after a sweep (async fill — 5/28 observed). Hence the explicit ARP pass.

---

## KB GhostRecon

**Version 1.0 · passive profiling · 30/60/90 s listen · zero packets transmitted**

The complement to active sweeping. It **sends nothing** — no probe, no ARP request, no SYN — and still builds a named inventory.

### Why passive is strictly better on some networks

- **No signature.** Nothing hits an IDS, nothing lands in a client firewall log, nothing trips NAC "rogue scanner" detection.
- **Client isolation doesn't blind it.** Guest/hotel/office WiFi that blocks *your* traffic still lets broadcast/multicast through — and broadcasts are the whole input. Active sweeps lose the wired side of the same L2 entirely; passive listens receive its traffic regardless.
- **It gets data active scanning can't get.** Hostnames, service instance names, and device classes are *volunteered* by mDNS/SSDP/NetBIOS. An nmap sweep never learns a device is a Quest.

### Mechanics

```sh
timeout $((SECS+10)) tcpdump -i $IFACE -n -e -l -A \
  '( arp or ( udp and ( port 5353 or port 1900 or port 137 or port 68 ) ) )'
```

- `-e` puts the **source MAC on every decoded header line** — the join key.
- `-l` line-buffers so a SIGTERM from `timeout` still flushes everything captured.
- `-A` prints packet payloads as ASCII, which lands mDNS service names and SSDP headers as plain text — no hex parsing needed.
- Filter covers ARP, mDNS (5353), SSDP (1900), NetBIOS (137), DHCP client traffic (68).

Everything downstream is two `awk` passes and a vendor lookup:

1. **Emit pass** — per line, track the current source MAC; extract source IPv4 (first `a.b.c.d.port >` token in the decoded header, with multicast/link-local discarded); harvest mDNS instance names, SSDP device classes, DIAL announcements, ARP `who-has`/`is-at` IP↔MAC pairs, NetBIOS `<name>` records.
2. **Merge pass** — one row per MAC, first observed IP, de-duplicated service tokens.
3. **Enrich** — vendor from the Pager's own `/usr/share/nmap/nmap-mac-prefixes` (46k OUI lines, no network needed), and a class table.

### Classification table

| Evidence | Classified as |
|---|---|
| `oculusal_sp._tcp.local` | Meta Quest VR |
| `companion-link` / `rdlink` | Apple Mac / Catalyst |
| `googlecast._tcp.local` | Chromecast / Google TV |
| `airplay` | AirPlay device |
| `nvstream._tcp.local` | NVIDIA SHIELD |
| `nearbypresence` | Android / Chrome |
| `SSDP:X1*` | Xfinity gateway |
| `SSDP:dial` | Smart TV / Chromecast (DIAL) |
| `SSDP:BasicDevice`, `M-SEARCH` | UPnP device / probing client |
| NetBIOS `<00>`/`<20>` | Windows / SMB host |

**Loot format** (`/root/loot/kb_ghostrecon.txt`):

```
=== 2026-09-06T16:44:22Z | v1.0 GHOST iface=wlan0cli ssid=<ssid> listen=60s devs=7 ident=7 secs=61 ===
192.168.99.49|10:ff:e0:...|Espressif|Meta Quest VR|testBox|oculusal_sp_v2._tcp.local nvstream._tcp.local SSDP:dial
192.168.99.22|11:22:33:44:55:04|Wistron|Meta Quest VR|testBox|oculusal_sp._tcp.local nvstream._tcp.local
|5c:7d:7d:...|Technicolor CH USA|Xfinity gateway||SSDP:X1VideoGateway SSDP:X1Renderer SSDP:BasicDevice
```

Fields: `IP | MAC | vendor | class | instance name | raw service tokens`. Devices seen but silent about their IP (pure L2 chatter) legitimately have an empty IP field — that's a real finding, not a gap.

### What one 60-second listen learns on a home LAN

Real fixture from development, seven devices, all classified, from ambient traffic alone: two Meta Quest headsets (instance name recovered), two Chromecasts, an Xfinity gateway, an Apple Mac, an Android/Chrome client. Nothing was sent to obtain it.

### Honest limitations

- **A quiet network yields nothing.** The payload says so explicitly rather than reporting a false zero-hosts-as-success. Deep-sleep phones advertise on wake; longer listens catch more.
- **IPv6-only mDNS speakers** appear with MAC + services but no v4 address.
- **VLANs and wired-only hosts that never broadcast** stay invisible; that's L2 physics, not a bug. Run NetRecon from the wired side for that.
- `-A` payload dumps contain binary padding that fuses into parsed tokens as dot-runs. The emit pass strips through the last dot-run to recover the real tail — see harness gotchas below, because this one cost two devices before it was caught.

---

## KB GhostBt

**Version 1.0 · passive Bluetooth LE wardrive · 30/60/90 s listen · zero connections**

Flipper Zero's BadBluetooth tier, on hardware you already carry. The Pager's BT adapter (`hci0`, BR/EDR + LE via BlueZ 5.72) runs LE discovery — pure receive of advertisement packets. No page, no connection, no pairing attempt; a phone cannot detect it happened.

- Input: `bluetoothctl --timeout N scan on` → `[NEW] Device MAC NAME` + `[CHG] Device MAC RSSI: ... (-NN)` lines.
- The hci cache persists across boots, so GhostBt snapshots a **baseline** first and only loot-diffs devices seen **this run** — otherwise every result would be padded with last week's sightings.
- Enrichment: RSSI-sorted (closest first), OUI vendor from the on-device nmap table, name-pattern classes (Govee plug, Vive basestation, Apple device, car key...). MAC-randomized devices honestly show `?` — no invented heuristics.

```
=== 2026-09-07T04:12:17Z | v1.0 GHOSTBT listen=30s devs=4 ident=2 secs=31 ===
11:22:33:44:55:03|Govee_H8000_0000|-53|Shenzhen Worldisland|Govee smart plug/light
11:22:33:44:55:04|HTC BS 00AA|-83|HTC|HTC Vive basestation
```

## KB KickAudit

**Version 1.0 · passive 802.11 management-frame audit · 2/5/10 min · sends nothing**

The defensive half of the deauth story. Listens on the Pager's monitor interface (`wlan0mon`, 2.4 GHz) for `DeAuthentication`/`Disassociation` frames and answers the question that keeps wardrivers humble: *is someone kicking devices off this network, or is the router just flaking?*

- Attribution model: `SA` (frame sender) vs `BSSID` (network). Sender = BSSID → **AP-originated** (reboot, driver hiccup, client steering). Foreign sender on your BSSID → **someone is kicking you**. `DA:ff:ff:...` → broadcast, every device on the channel gets deauthed — the classic evil-twin signature.
- Context included: rejoin counts (AUTH/ASSOC) per client, because a kick nobody rejoins is a different story than a kick-rejoin-kick loop.
- One parse subtlety the fixture caught: tcpdump's *reason text* for a Disassociation frame can literally contain the word "Deauth" ("reason 3: Deauth coming from AP..."). Classify on the frame-type token (`DeAuthentication`/`Disassociation`), never loose substrings — otherwise disassoc gets mislabeled as deauth.

```
c8:...|BROADCAST|DEAUTH|from aa:bb:cc:dd:ee:01      <- broadcast deauth by a foreign MAC
30:...|30:...|DISASSOC|from 30:...                  <- client leaving voluntarily
-- rejoin context (count SA) --  2 00:11:22:33:44:02     <- and right back on
```

## KB Beacon

**Version 1.0 · BLE name chameleon · the one payload that transmits — and guarantees undo**

Makes the Pager advertise as `Pixel 8 Pro`, `Kitchen Scale`, or `John's iPhone` for 2–10 minutes: pranks, decoys, wardriving bait, testing which of your colleagues walk past a fake printer. Verified end-to-end by witnessing the spoofed name from a *second, independent* Bluetooth adapter during development.

The engineering here is not the spoof — it's the **guarantee that it undoes itself**, because a recon tool that leaves your device advertising "Pixel 8 Pro" at a client site is a burned asset:

1. Original alias + discoverable state captured before any change.
2. On natural end, user cancel (SIGTERM), or crash: restore runs via EXIT + INT/TERM/HUP traps.
3. The Pager's BlueZ stack can refuse `discoverable off` (`org.bluez.Error.Failed` — device-verified). The payload's recovery ladder **power-cycles the adapter via `btmgmt power off/on`**, which does clear it. Ladder outcome is verified by re-reading state, not assumed.
4. `SIGKILL` is uncatchable — so a marker file makes the *next* launch self-heal a dead run's leftovers before doing anything else.

All of that machinery is harness-tested, including the stubborn-stack path and a real SIGTERM fired at the payload mid-hold (`harness/test_beacon_term.sh`).

## Games

**KB Hoard Hopper** (v1.1) — a 12-room roguelite text crawl: doors hint their contents (`SHIMMER/WARM/WHISPER/HOLLOW/SULFUR`), traps/mimics/merchants/vault-spirits decide your purse, and gold carried to room 12 joins a permanent hoard you spend on stacking upgrades (VIGOR/SENSE/CHARM/POUCH). Save state in `/root/loot/kb_hoard_hopper/save`. It earned a full comprehension pass: every rule the game enforces, it states in plain words before you can trip on it — the same "communicate or it doesn't exist" discipline as the recon loot.

---

## Install

Copy a payload directory onto the Pager and syntax-check it in place:

```sh
scp -r payloads/kb_ghostrecon root@172.16.42.1:/root/payloads/user/general/
ssh root@172.16.42.1 'ash -n /root/payloads/user/general/kb_ghostrecon/payload.sh && echo OK'
```

(Use your Pager's IP; `172.16.42.1` is the USB/ethernet default, `172.16.52.1` over Mark VII tunnel.) Each payload installs under its own category directory: `general` for NetRecon/GhostRecon, `reconnaissance` for GhostBt/KickAudit, `games` for Hoard Hopper/Beacon. Loot: `/root/loot/kb_<name>.txt`.

Requires `nmap` (NetRecon), `tcpdump` (GhostRecon/KickAudit), or `bluetoothctl` (GhostBt/Beacon) — all ship in current Pager firmware. Every payload checks for its dependency and exits cleanly if absent.

---

## Test harness (`harness/`)

Pager payloads are DuckyScript-flavored **BusyBox ash** with UI commands the rest of the world doesn't have. The harness runs the **actual payload files, unmodified**, under `busybox ash` with a shim for the UI layer and deterministic mocks for the heavy binaries — so logic bugs surface on the workstation, not on the device.

```sh
cd harness && ./test_all.sh
```

```
== kb_netrecon ==     PASS full sweep | arp-cache mode | cancel | zero hosts
== kb_ghostrecon ==   PASS full listen | quiet network | no route | cancel
== kb_ghostbt ==      PASS BLE scan | cancel | no adapter | BLE silence
== kb_kickaudit ==    PASS kick patterns | cancel | no monitor | dead channel
== kb_beacon ==       PASS natural end + restore | cancel keeps identity
                        restore-on-SIGTERM (dedicated signal test)
== result: 19 pass, 0 fail ==
```

### The four-path contract

Every payload here ships green on all four, and any payload you write should too:

1. **Happy path** — real fixture in, correct inventory out, counts asserted.
2. **Cancel** — user presses BACK on the picker → clean `exit 0`. This is the most commonly broken path in real payloads; the shim makes cancel the *default* when a picker answer isn't scripted, so a payload that ignores cancel fails the suite immediately.
3. **Not joined to a network** — no default route → explicit red error, not a crash and not an empty success.
4. **Zero results** — the payload states "0 hosts responded" / "network too quiet" out loud. A scanner that silently returns nothing is indistinguishable from a scanner that didn't run.

### Scripting pickers

```sh
GR_MOCK_DIR=$PWD/fixtures/gr PATH="$PWD/mocks/ghostrecon/bin:$PATH" \
  ./run_payload.sh ../payloads/kb_ghostrecon/payload.sh --answers 'LIST_PICKER=60 s'
./run_payload.sh <payload> --cancel-first        # BACK pressed on first picker
```

Answers live in **files**, not shell variables: payloads call `X=$(LIST_PICKER ...)`, which runs in a subshell, so any variable the mock mutated would be lost and every picker would return the same first answer forever. A file survives the subshell and the queue actually advances.

### Gotchas learned the hard way (all encoded in this code)

| Gotcha | Fix in harness |
|---|---|
| BusyBox **applets shadow PATH mocks** — a mock `ip` on PATH is never reached, ash runs the applet | mock `ip` as a **shell function**; functions beat applets |
| `tcpdump` is **not** an applet | PATH mock works normally — but check `busybox --list` before assuming either way |
| Picker answers are **UI labels** (`"60 s"`), not integers | strip to digits before `$(( ))`; ash errors on `"60 s"` |
| `VIBRATE` with no arguments prints usage and **exits 1**, so it becomes the payload's exit code and the UI shows "experienced an error" | always pass an RTTL pattern; the shim reproduces the exit-1 trap |
| Greedy `[^>]*` in awk grabbed the **destination** IP from tcpdump's `src > dst` header, so every parsed IP was wrong/empty | match the **first** occurrence, then strip the `.port` suffix |
| Binary `-A` padding fuses into mDNS names as dot-runs (`1.........1......_oculusal_sp`) | strip through the last dot-run to recover the tail; **discarding** such tokens silently deleted two real devices — caught only because the harness asserted device count 7 and got 5 |

That last row is the argument for the whole harness: an over-aggressive cleanup passed visual inspection and failed an assertion.

### Fixtures

`fixtures/gr/cap.txt` is a **sanitized** real capture: MACs remapped deterministically with OUI prefixes preserved (so vendor lookups still exercise), IPv4 moved to `192.168.99.0/24`, IPv6 interface IDs and device identifiers hashed, owner names replaced. No real network data ships with this repo; re-running the sanitized fixture through the harness reproduces the identical 7-device / 7-identified result.

---

## Vantage discipline

Every finding here is vantage-dependent. Raw-socket privilege and physical network location change what a scan can see — the same /24 yielded **11 hosts unprivileged** and **28 hosts** from a root vantage on the joined WiFi. So:

- Report privilege and location with any result (`vantage:` line in `netscan.py`, `net=/iface=/ssid=/mode=` header in Pager loot).
- Treat differing counts between vantages as information about the network (ACLs, client isolation, ICMP-drop policy), not as a tool bug.
- Cross-check a passive run against an active run when both are authorized — disagreement tells you which hosts are quiet and which are filtered.

## Companion scanner

`netscan.py` (Python 3, stdlib-only, cross-platform) is the workstation-side equivalent of KB NetRecon: unions a ping sweep into nmap results when running unprivileged, and prints its vantage. Available on request / in the author's toolchain; not included here because it isn't a Pager payload.

## Disclaimer

These tools are for **education, authorized auditing, and analysis where permitted**, subject to local and international law. Get **explicit written authorization** from the network owner before running either payload against any network you do not own or operate. Users are solely responsible for compliance. The authors claim no responsibility for unauthorized or unlawful use.

Both payloads are **reconnaissance-only**: they observe and enumerate. Neither exfiltrates off-device, disrupts service, nor modifies any system.

## Attribution

WiFi Pineapple, Pager, DuckyScript, and Pager firmware are intellectual property of **Hak5 LLC**. `harness/pager_shim.sh` derives from `pager_ducky_shim.sh` in [hak5/wifipineapplepager-payloads](https://github.com/hak5/wifipineapplepager-payloads), used under the terms referenced there. The payloads, mocks, fixtures, four-path methodology, and measurements in this repository are original work. Not affiliated with or endorsed by Hak5.
