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
| **[KB Portal](#kb-portal)** | serves pages on its own AP | *what does a joined client reveal* — captive credential/DNS/fingerprint capture trio on the Pager's own access point |
| **[KB Tap](#kb-tap)** | passive pcap ring | *what do clients send unprotected* — cleartext credential harvest (HTTP POST/GET, Basic, FTP/telnet/mail AUTH) from the wire, with Start/Stop markers and offline extraction |
| **[KB Hijack](#kb-hijack)** | targeted DNS hijack + re-auth pages | *where would they actually type passwords* — operator-listed hostnames answered by the Pager, served an unbranded session-expired page that logs the intended target with every hit |
| **[KB Names](#kb-names)** | hostname harvest | *what should we hijack* — every name joined clients actually resolve (AP mode) fed straight into KB Hijack's target file |
| **[KB Loot](#kb-loot)** | rig-side collector (a `tools/` script, not a Pager payload) | *how does evidence get home* — one-command verified pull: device-side sha256 manifest, byte-exact verify, content-hash ledger dedupe, verified-clean of collected files only |

The recon payloads run against the network the Pager is currently joined to (client mode) or the RF environment around it, append loot to `/root/loot/`, and treat user-cancel as a first-class code path. None of them exfiltrates anything: results land on the Pager's own storage and you collect them yourself.

---

## Contents

```
payloads/kb_netrecon/       payload.sh + _hak5_manifest.json
payloads/kb_ghostrecon/     payload.sh + _hak5_manifest.json
tools/
  kb_loot.sh                rig-side verified loot collector (ssh pull + sha256 + ledger)
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

## KB Portal

**Version 1.0 · captive portal trio (Install / Start / Stop) · scope: clients that join the Pager's own `pager-open` AP**

The Flipper's "NFC tap-to-connect" fantasy made concrete: anything that joins the Pager's access point gets **all DNS resolved to the Pager** and served a login-style page. Not a brand clone — a generic, friendly "Guest Network Access" corporate sign-in page (unbranded on purpose; that's a deliberate design line, not a TODO).

Three payloads, one product:

- **KB Portal Install** (run once): `opkg install uhttpd` from OpenWrt repos, stop/disable the stock auto-enabled server (it steals :80 at boot otherwise), generate an **EC P-256** captive cert — RSA-2048 keygen takes *minutes* on this MIPS and hung a test session; EC is instant.
- **KB Portal Start**: two conf-dir drop-ins into the **dynamically discovered** dnsmasq conf-dir (`conf-dir=` line in the generated config, never hardcoded): `address=/#/172.16.52.1` (wildcard capture, ~2 s to bite) + `log-queries=extra` (the passive goldmine). Launches uhttpd on :80 (+https :8443) with captive-detect probes (`generate_204`, `hotspot-detect.html`, `ncsi.txt`, `connecttest.txt`) aliased straight to the portal.
- **KB Portal Stop**: kill server, remove **both** drops, restart dnsmasq, **verify** DNS really restored (answer-section check, not raw grep — the server's own `Address:` header made a naive check always-warn), archive both logs into `/root/loot/kb_portal/`, print counts.

### What a joined device gives up (all witnessed in the live cycle test)

| Channel | Captured | How |
|---|---|---|
| Credentials | user+pass, raw URL-encoded, with time/UA/host | POST to `login.cgi`, polite "couldn't verify" re-prompt loop |
| Identity on arrival | e-mail in `?Email=` query strings from link previews / captive redirects | `QUERY_STRING` logged on GET — **no interaction needed** |
| Device class | UA, screen, timezone, language, cores, touch | `fp.cgi` via same-origin inline script — zero third-party calls |
| Every hostname it knows | full DNS query log with source IP: telemetry domains (= what's installed), search suffixes (= where it comes from) | dnsmasq `log-queries=extra` |
| Request inventory | every hit incl. captive probes | GET lines in the capture log |

### The uhttpd flag triad (each bought by a live failure — the reason this README exists)

```
-c /dev/null      bypass stock /etc/httpd.conf (silently breaks CGI execution)
-i .cgi=/bin/sh   execute .cgi anywhere (default handler covers only /cgi-bin;
                  aliases to a .cgi serve it RAW - never exec)
-s 8443 -C crt -K key   split cert/key; -P is the TLS CIPHER LIST, not a pidfile
```

And the perms lesson that hid behind a green run: `/root` is `0700`, so CGI workers cannot write loot under it **no matter the file perms** — captures go to a world-writable `/tmp` sink, and **Stop archives them as root**. Same architecture as the DNS log; the pattern is "unprivileged sink, privileged collection."

Full cycle is **device-live-tested end-to-end** (Start → curl-client GET/POST/probes/DNS → Stop → verified clean), and the CGI paths run as CI unit tests (47/47 suite). Rogue-AP cloning is *not* part of this: fresh AP interfaces cannot be brought up on this firmware (device-proven), so KB Portal only ever serves its own AP.

---

## KB Tap

**Version 1.0 · passive cleartext-credential capture (Start / Stop) · zero-stock-image footprint: tcpdump, strings, base64, sha256sum all ship in the Flipper image**

The portal asks; the tap simply listens. `tcpdump -i br-lan -s0 -C 3 -W 8` writes a self-rotating 24 MB pcap ring into `/tmp` (tmpfs — rotation file naming `ring.pcap0..7` verified on device), and **extraction happens offline at Stop**, not with live grep pipelines: kill capture, `strings -n 4` the ring, grep for cleartext credential shapes (HTTP `POST` bodies with `pass=`/`user=`/`login=`, `Authorization: Basic/NTLM`, FTP/telnet `USER/PASS`, mail `AUTH LOGIN`), then **decode any Basic blobs found** (base64 ships in the image) into `user:pass` lines. Harvest gets a sha256 manifest; raw ring is archived into `/root/loot/kbtap/rings-<stamp>/` only when overlay headroom allows (>30 MB gate) — otherwise you're told to pull it over ssh before reboot.

Design properties, same discipline as the rest of the suite:

- **Marker + self-heal**: `Stop` without `Start` sweeps stray tcpdumps; `Start` on a crashed run harvests the dead ring before wiping it
- **No stacking**: refuses to start if any tcpdump already runs (one capture, one marker, no double-tap ambiguity)
- **Undo is the product**: Stop = kill, harvest, verify (tcpdump gone, ring+marker cleaned), counts + first-hits preview
- **No injection, no TLS interception**: the tap only ever takes what clients already send in the clear. It is a mirror of the operator's own network hygiene.

Live-witnessed cycle 2026-09-09 (device + devbox as the client): Start → bait POST creds + Basic auth + querystring creds across the AP link → Stop. Harvest caught **all three channels**, decoded `Authorization: Basic YWRtaW46…` → `admin:<password>` byte-exact, archived the 44 KB ring, wrote the sha256, cleaned everything. Two bugs found on the way (both mine, both in the *test*, not the payload: a planted-token mismatch, and a python heredoc that wrote a literal NUL into test_all.sh because `\0` inside a python string is not shell `\0` — binary test file, caught by grep, fixed with a byte-splice). Suite: 47/47.

---

## KB Hijack

**Version 1.0 · targeted DNS hijack pair (Start / Stop) · the escalation layer on the same device-proven mechanics as KB Portal**

Portal captures *everyone* with one generic page. Hijack answers **only the hostnames the operator lists** — `/root/portals/hijack_targets.txt`, one per line, validated shape, hard cap of 25 — each resolving to the Pager, served a clean, unbranded **"session expired — sign in to continue to `$HOST`"** page. The intended target *is* the lure: the page header, the button text, and the capture line all carry it (`tgt=hijackproof.test`), so the report reads "who tried to reach what, and what did they type for it." No logo cloning, no vendor impersonation — the standing design line holds; the operator's own target list supplies the context.

Capture record per hit: `GET`/`POST | timestamp | tgt | source IP | UA | user/pass (URL-encoded, field-variant tolerant) | referrer | raw-body fallback`. Parser accepts `user|username|email|login|account` × `pass|password|pwd|pin`, and **when no known field name matches, the full raw body is logged anyway** — a nonstandard form loses nothing. Stop removes the drop, restarts dnsmasq, **verifies the first hijacked name resolves for real again**, archives the capture with sha256, prints `N hits / M credential POSTs / K distinct targets`, and sweeps stray drops/canaries even with no marker present.

### The canary rule (this payload's real gift to the whole suite)

Every DNS-dropping payload now **proves its own effect before claiming LIVE**: a throwaway hostname (`kbpcanary-$$`) is deployed *with* the real drops, dnsmasq restarted, and the canary must actually resolve to the Pager or the payload reverts everything and refuses to run. This exists because three failure modes were witnessed on one device in one morning:

1. **`printf 'address=/$CANARY/$IP\n'`** — single quotes suppress expansion; the drop file contained the literal `$CANARY`. The *real* root cause of the first failed live cycles, found by `sh -x` xtrace after two wrong theories (dnsmasq timing, procd races).
2. **pid comparison lies** — procd respawn races mean "new pid" neither happens reliably nor means anything. The only truth is a canary query.
3. **procd crash-loop backoff** — rapid Start/Stop test cycles pushed dnsmasq into a "12 crashes" cooldown where `init.d start` became a no-op. The payload now escalates: procd start → wait → one cooldown retry → `manual_respawn` (bring dnsmasq up directly from the generated conf, bypassing the supervisor), and KB Portal inherited the same hardening.

**Never trust a config drop you haven't queried through.** Outcome verification, or the payload lies to the operator.

Live-witnessed cycle 2026-09-09: two targets listed → Start → canary verified → both names answered Pager-side and served their own-name re-auth pages (GET + POST + query-string), **unlisted names kept real resolution (NXDOMAIN — scope discipline proven in the same run)**, credential POST captured with `tgt=` + URL-encoded user/pass, Stop → DNS restored + verified, capture archived + hashed, port 80 freed, confdir zeroed. CI grew to 47/47 (ash parity, CGI unit paths incl. field-variant parsing and raw-body fallback).

---

## KB Names

**Version 1.0 · hostname harvest · the intelligence layer that feeds KB Hijack**

Hijack needs names to hijack. KB Names gets them. Two modes, auto-detected — the honest split was measured on-device, not assumed:

- **Mode B — own AP (the strong one):** on the Pager's own access point, **dnsmasq *is* the resolver for every joined client**, so a `log-queries=extra` drop captures *every hostname every client resolves*, attributed per client (`count client-ip|name`), plus `/tmp/dhcp.leases` for the joined clients' own hostnames (`Devbox2 172.16.52.133 00:13:37...` — seen live). Completeness comes from position, not effort.
- **Mode A — joined to a target network (the honest-poor one):** busybox tcpdump **cannot decode DNS** (measured: 0 summary lines) and busybox nslookup does no PTR (measured: nothing), so the best passive harvest is label-split ASCII fragments from `tcpdump -A` on cleartext DNS — clearly labeled partial, never oversold. mDNS/NBNS measured near-silent (0 pkt/5 s) and are not relied on.

**Output → pipeline:** after the listen, `LIST_PICKER` offers to **merge the harvested names into `/root/portals/hijack_targets.txt`** (dedup, shape-validated, cap 25, old file preserved as `.bak`) — GhostRecon → Names → Hijack becomes one intelligence loop: who's talking → what they trust → serve them their own names back.

**Self-verifying, per the canary rule:** the log drop is proven before the listen starts — a `kbn_selftest` query must actually land in the query log or the payload reverts and refuses. First live run proved the rule's worth *inverted*: self-test passed, harvest came back empty — three debug rounds later the culprit was **my awk expecting the classic `A?` log format while `log-queries=extra` switches dnsmasq to the verbose format** (`1 172.16.52.133/33736 query[A] name from client`). The lesson that outlives the bug: *sample the real output format before writing the parser* — a self-test can only prove what it actually tests. Second run, live-witnessed: five names fired from a joined client → **3 captured** (uniq-c dedup ate the two repeats, as designed), client hostname `Devbox2` from leases, target file seeded, confdir back to 0, DNS answering for real. CI 47/47 including a verbose-format extraction unit built from the real captured log lines.

---

## KB Loot

**Version 1.0 · rig-side verified collection (`tools/kb_loot.sh`) · the workflow's Phase 6 as one command**

Five payloads accumulate loot in `/root/loot/`; KB Loot is the tailgate. It is deliberately **not a Pager payload** — collection is the operator's rig's job, and keeping it there means a wiped or lost Pager never held the only copy of anything. The pipeline, in order:

1. **Device manifest first:** `sha256sum` of every file computed **on the Pager before transfer** — the authoritative hash list travels independently of the bytes.
2. **One-connection pull:** `tar | ssh` stream into `loot/pull-<UTC-stamp>/` (subdirectories preserved; `tar` ships in the stock image — verified).
3. **Byte-exact verify:** rig re-hashes every file against the device manifest. Any mismatch → retry via individual `scp`, and a still-bad file makes the run **exit 2 with `RESULT: INCOMPLETE — do not trust this pull`** printed. Silent partial collection is the failure mode this whole tool exists to kill.
4. **Ledger dedupe:** `collected.sha256` records every content-hash ever collected; re-runs report `dupes (already collected)` instead of double-storing the same loot twice, while still proving the device copy matches what you hold.
5. **`--clean-verified`:** deletes remote files **only** those transferred AND byte-exact verified this run (new or duped — RUNDIR provably holds an identical copy of each). Refused silently against unverified anything; the safe-by-construction rule: we delete only what we demonstrably have.
6. **`--drive`:** zips the engagement dir and pushes through `drive_push.sh` (Smaug Scripts lane) when available; left local with a WARN otherwise.
7. **`--local DIR`:** the same verify/dedupe/summary pipeline against a local tree — CI exercises the whole collector (fresh collect, rerun dedupe, corrupt-manifest → exit 2) with zero device time. Real-mode witnesses: 2-file ssh pull → `verified OK: 2  new: 2`, second run → `dupes: 2`, `--clean-verified` against a throwaway dir → 0 files left, **real `/root/loot` untouched throughout**.

Design debt honestly named: local mode computes its manifest *from* the staged tree, so it structurally cannot detect corruption — CI's BAD-path test uses the `KB_LOOT_FAKE_MANIFEST` hook to inject an external manifest instead. Local mode is for testing the pipeline, not for trusting evidence; only ssh mode carries evidence-grade meaning.

Usage: `./tools/kb_loot.sh root@172.16.52.1 -o engagement-2026-09-09 --clean-verified` (env: `KB_LOOT_DIR` to collect a non-default remote dir; `--drive` for the Drive lane).

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

## Operator workflow: step one to done

The training path — one engagement, start to finish, with the menu for every move. Two ground rules before step one: **you are only ever on networks your employer put you on in writing** (scope document named, date, allowed ranges), and **every Start has its Stop** — the suite is designed so the undo is always available and always verified. If a step's verification line doesn't match, stop there and fix it; don't stack the next payload on top of a broken state.

### Phase 0 — Deploy (once per Pager)

```sh
# from the repo, on your rig, Pager on USB/ethernet (172.16.42.1) or tunnel (172.16.52.1):
for d in payloads/*/; do
  cat=$(sed -n 's|^# Category: ||p' "$d/payload.sh")
  ssh root@172.16.42.1 "mkdir -p /root/payloads/user/$cat"
  scp -r "$d" root@172.16.42.1:/root/payloads/user/$cat/
done
ssh root@172.16.42.1 'for f in /root/payloads/user/*/*/payload.sh; do ash -n "$f" || echo "FAIL $f"; done'
```
One-time: **interception → KB Portal Install** (pulls uhttpd, generates the TLS cert, keeps the original dnsmasq init as `.orig` — that file is the recovery anchor for everything DNS).

### Phase 1 — Who is there (recon, passive first)

1. *general → KB NetRecon* (joined mode) — fast active sweep: hosts, MACs, open ports. Note the `vantage:` header it prints.
2. *general → KB GhostRecon* — 30–90 s of listening, zero packets: names, vendors, device classes from the chatter every LAN emits.
3. *reconnaissance → KB GhostBt / KB KickAudit* as scope allows.

Cross-check the counts (a passive-vs-active gap = filtered or quiet hosts — that IS a finding). All loot appends to `/root/loot/kb_<name>.txt` with the net/iface/ssid/mode header so every artifact says where it came from.

### Phase 2 — Move to the AP (elevation of vantage)

Join the Pager's own AP (`pager-open`) with your test client, or run the Pager in mode B where you can. This is where the interception trio lives — everything from here on affects **clients joined to the Pager**, never the upstream network.

### Phase 3 — What do they trust (KB Names)

*general → KB Names* → pick 30/120 s. On the AP this is the **complete** answer: every hostname every joined client resolves, per client, plus DHCP lease names. Accept the merge offer — it seeds `/root/portals/hijack_targets.txt` (deduped, capped, old file `.bak`'d). These names are your target list: things clients *actually depend on*, not guesses.

### Phase 4 — The engagement (interception trio, one at a time)

Order matters when two share a resource — KB Portal's wildcard DNS makes hijack targets unreachable, so **pick one DNS story at a time**:

- **Generic credential story:** *interception → KB Portal Start* → pick template → probe it once from your test client (captive portals announce themselves: `curl -s http://whatever/ | grep -c "Guest Network"`), let it run, **Stop**.
- **Targeted story:** write/seed the target list (Phase 3), *interception → KB Hijack Start* → both names resolve to the Pager, unlisted names keep real DNS (verify: one listed, one unlisted `nslookup`) → **Stop**.
- **Wire story (always safe to run alongside):** *interception → KB Tap Start* → br-lan → let clients work → **Stop** (harvest decodes Basic auth into plaintext user:pass with a sha256 manifest).

### Phase 5 — Undo, verified (the discipline, not the afterthought)

Every Stop verifies its own cleanup and prints the evidence — read it, don't assume it:

- Portal/Hijack Stop: `DNS verified restored (NXDOMAIN returned)` / first target resolves real again; port 80 = 0; confdir = 0 files.
- Tap Stop: `tcpdump gone`, ring + marker cleaned, harvest line counts printed.
- If a Stop ever claims a failure (`DNS still hijacked!`): restart dnsmasq by hand (`/etc/init.d/dnsmasq.hak5 restart`) and re-check with `nslookup <name> 127.0.0.1` — the payload already tries hard (kill → procd start → cooldown retry → manual respawn from the generated conf) but a human confirms the state before you walk away.

### Phase 6 — Collect, chain, close

Loot lives on the Pager (`/root/loot/`); **KB Loot** brings it home verified — device-side manifest, byte-exact check, ledger dedupe, and removal only of what provably arrived:

```sh
./tools/kb_loot.sh root@172.16.52.1 -o engagement-$(date +%Y%m%d) --clean-verified --drive
# trust the last line: RESULT: CLEAN or RESULT: INCOMPLETE (exit 2) - never eyeball it
```
`--clean-verified` empties the device as evidence lands verified ( Pager lost in the field = nothing on it but config ); drop it if your scope says leave everything. The Pager is the acquisition layer, your rig is the evidence layer — never invert that.

Then the report loop: **evidence → finding → fix**. Every credential captured is a finding that ends in one of three sentences for the client: "TLS was missing on X, here's the fix", "hosts still speak HTTP Basic on X, here's the fix", "users type passwords into a page that wasn't their IdP — here's the phishing-detection training they need." We do not ship a problem we cannot name the cure for.

### Menu map (where everything lives)

- **general:** KB NetRecon · KB GhostRecon · KB Names
- **reconnaissance:** KB GhostBt · KB KickAudit
- **interception:** KB Portal Install/Start/Stop · KB Tap Start/Stop · KB Hijack Start/Stop
- **games:** KB Hoard Hopper · KB Beacon (yes, the pager has a roguelite; long stakeouts are stakeouts)

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
== kb_portal ==      PASS CGI unit paths incl. qs/POST/fp capture | ash -n trio
== kb_tap ==         PASS ash -n pair | harvest POST | basic decode
== kb_hijack ==      PASS ash -n pair | CGI target-context + variant parsing |
                     raw fallback
== result: 47 pass, 0 fail ==
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
