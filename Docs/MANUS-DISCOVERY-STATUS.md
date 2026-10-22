# FieldLink PLC — current discovery status for Manus

**Date:** 9 Oct 2026  
**App:** FieldLink PLC (`com.johnnybox.fieldlinkplc`, team `6MGV2KJVCV`)  
**Repo:** https://github.com/jbox662/FieldLink-PLC  
**Primary code:** `FieldLinkPLC/Services/LocalNetworkGatewayClient.swift`  
**Debug UI:** Gateway → Discovery debug  
**Older Oct 5 brief (pre-multicast):** `Docs/IOS-ETHERNET-DISCOVERY-ISSUE.md`

Please read this file as the current truth. The Oct 5 brief is historical.

---

## 1. What the technician actually needs

The owner uses a handheld (TW Controls [SIM-IPE](https://twcontrols.com/plc-trainers-all/p/sim-ipe) class) like this:

> Sometimes I do not know the PLC IP. I plug the tool into the Ethernet cable and it reads the IP.

That is the success bar. Not a full port scanner. Not Wi-Fi. Not “type the IP first.”

If the PLC already has an IPv4 address and speaks EtherNet/IP, the iPhone should list **name + IP**.  
If the PLC has **no IP** (BOOTP/silent), the handheld can still hear BOOTP/DCP. A normal iOS app cannot.

---

## 2. What we have built (working)

### Product split

| Piece | Role |
|---|---|
| iPhone app | Technician UI, audit, USB-C Ethernet discovery controller |
| FieldLink Gateway (`gateway/`, Windows/Linux) | BOOTP, CIP address writes, raw/L2 work iOS cannot do |
| Live path under test | **No gateway.** Xcode debug install on a physical iPhone. USB-C Ethernet dongle = `en5`. |

### Apple / signing

- Multicast Networking **is now approved** for this App ID.
- `FieldLinkPLC/FieldLinkPLC.entitlements` has `com.apple.developer.networking.multicast`.
- Xcode automatic signing pulled a development profile **with** that entitlement (`True`).
- Runtime check `MulticastNetworkingCapability` reads the signed entitlement (SecTask via `dlsym`, plus embedded profile fallback). Discovery refuses to pretend it can broadcast if the entitlement is missing.
- TestFlight upload was **stopped on purpose** so the owner can debug from Xcode.

### USB-C Ethernet (fixed earlier)

- Cheap USB LAN often shows as `NWInterface.type = .other`, not `.wiredEthernet`.
- Scanner treats `en1+` as plant Ethernet and **never** uses `en0` Wi-Fi.
- Binds discovery with `IP_BOUND_IF` to `en5`.
- Local Network prompt via Bonjour browse `_fieldlink-gateway._tcp`.
- Dark/light theme, discovery debug screen, Xcode `Logger` category `discovery`.

### Current scanner (what the phone runs today)

After multicast approval, discovery does:

1. Require multicast entitlement at runtime.
2. BSD UDP socket: `SO_BROADCAST`, `SO_REUSEADDR`, large `SO_RCVBUF`.
3. Bind **UDP 44818** (many stacks reply to 44818, not an ephemeral port). Fall back to port 0 if bind fails.
4. Send EtherNet/IP **ListIdentity** (`0x0063`, 24-byte header) to:
   - `255.255.255.255` (limited broadcast), repeated for ~5s
   - Directed subnet broadcast only if prefix ≥ /24 (iOS often cannot send `192.168.71.255` on a /22)
   - Unicast to a **bounded** host range: if the interface is wider than /22, clamp to the /22 that contains the phone (max 1022 hosts). Skip off-link addresses (`ENETUNREACH`).
5. Ignore our own 24-byte probes echoing back from the phone IP.
6. Parse CIP identity item `0x000C`.
7. Extra host discovery (same job as consumer **IP Scanner**):
   - ICMP echo on `en5` — **works**. Last run: **ICMP=27**.
   - Non-blocking TCP connect to **80 / 443 / 44818**; `connected` or `ECONNREFUSED` = host up. Last run: **TCP=4**.
   - Live hosts with no ListIdentity are listed separately from EtherNet/IP identities.
8. Live-host identification **proven on device** 9 Oct evening:
   - Reverse DNS / `.local` via `getnameinfo` (0.45s cap)
   - Open-port fingerprint: 22, 80, 443, 445, 502, 554, 8080, 9100, 44818
   - If TCP 80 is open: bound HTTP `GET /` for `Server` header and `<title>`
   - Named hits so far: `.1` = Router/gateway (TCP 80); `.75` = **espresense-entrance** (home BLE presence, TCP 80); `.84` = TCP **554 RTSP** (camera). Many others are TCP 80 with no title, or ICMP-only.

Address writes from the phone are still refused. That stays on the gateway.

### What already works on the physical iPhone

ListIdentity **and** LAN host discovery work on USB-C Ethernet `en5 192.168.68.72/22`:

```
Host probe ICMP=32 TCP=4 unique=32
EtherNet/IP ListIdentity on en5 192.168.68.72/22 · link up.
found 1 EtherNet/IP device(s). plus 31 live IPv4 host(s).
unicast probes 1021. broadcasts 5. recv 4.
UDP source port 44818. targets 255.255.255.255.
Found JOHNNY-PC 192.168.68.87 vendor=HMS / Softing / PC adapter
Found Router / gateway 192.168.68.1 vendor=HTTP device
Found espresense-entrance 192.168.68.75 vendor=HTTP device
```

This `en5` cable is the **house/shop 192.168.68.0/22 LAN**, not an isolated PLC drop. The only CIP/ListIdentity node is JOHNNY-PC. Named non-PLC gear includes the router, ESPresense, and an RTSP camera. **No bench PLC answered EtherNet/IP.**

---

## 3. What we are stuck on

### 3.1 Only one EtherNet/IP device

Owner’s job is “read the unknown PLC IP.”  
Every good run still finds **only JOHNNY-PC**.

We do **not** know if the bench PLC:

- is on this Ethernet segment,
- has an IP,
- speaks EtherNet/IP (vs Profinet / no stack),
- or is silent/BOOTP.

Please do not assume CompactLogix vs Siemens.

### 3.2 Live LAN hosts are found; they are not PLCs

This is **solved for “what IPs are alive.”** FieldLink now matches (and exceeds) the IP Scanner list.

Last identified FieldLink run on `192.168.68.72/22` (`ICMP=32`, `plus 31 live IPv4`):

| IP | What we could read |
|---|---|
| `192.168.68.87` | **JOHNNY-PC** — only EtherNet/IP ListIdentity (Windows / HMS-class adapter) |
| `192.168.68.1` | Router / gateway, TCP 80 |
| `192.168.68.75` | **espresense-entrance** — ESPresense BLE node, TCP 80 |
| `192.168.68.84` | TCP **554** — RTSP camera |
| `192.168.68.53/.56/.57/.58/.61/.65/.66/.67/.74/.77/.78/.82/.89` | Something with a web UI (TCP 80), no CIP |
| Remaining `.50`–`.90` | ICMP reachable only (phones/IoT/PCs). `.50` was IP Scanner’s own Wi-Fi address earlier |

`en5` `.72` is skipped (self). None of these 31 live hosts answered ListIdentity. This is not a PLC-only cable.

**Implication for the handheld job:** plug the dongle into the **PLC Ethernet**, not this LAN. A Rockwell/Omron/etc. PLC would show an EtherNet/IP product name, not “HTTP device” or ESPresense.

### 3.3 Interface mask mistakes

| Phone Ethernet | Result |
|---|---|
| `192.168.68.253/16` | **1021 send failures**, `No route to host`, unicast probes 0. iOS USB Ethernet does not route that /16 sweep. |
| `192.168.68.72/22` | Unicast works. Directed broadcast `192.168.71.255` often `Network is unreachable`. Limited broadcast `255.255.255.255` works. |

Ask the owner to keep Ethernet at a real /22 or /24 on `192.168.68.x`. Do not use /16.

### 3.4 iPhone ≠ handheld

SIM-IPE-style tools **sniff L2** (ARP, Profinet DCP `0x8892`, BOOTP/DHCP UDP/67) and do not need the tool IP to match the PLC.

A normal App Store iOS app **cannot**:

- promiscuous / BPF / raw Ethernet,
- bind UDP/67,
- see a factory-default PLC that never talks EtherNet/IP.

Apple multicast approval solved **UDP broadcast ListIdentity**. It did **not** make iOS into SIM-IPE.

The Windows/Linux **FieldLink Gateway** is the intended path for no-IP / BOOTP / DCP / address writes. See `gateway/DIRECT-CABLE-SETUP.md`. It is not what the owner is running in this bench test.

### 3.5 Noise that is not a discovery bug

Xcode console spam to ignore:

- `No symbol named 'radar'` — fixed (use `antenna.radiowaves.left.and.right`); rebuild if it still appears
- `cannot add handler to 0 from 0 - dropping`
- `PointerUI.pointeruid`
- empty dSYM / keyboard / UAF / Auto Layout keyboard warnings
- Debugger **SIGSTOP** / `mach_msg2_trap` — app was **paused**, not crashed

Filter logs on `discovery` / `EtherNet/IP` / `Found` / `Live IPv4` / `Host probe`.

---

## 4. Latest raw discovery logs (9 Oct 2026)

**Best run** (`192.168.68.72/22`, ICMP+TCP live hosts proven):

```
Host probe ICMP=27 TCP=4 unique=27
EtherNet/IP ListIdentity on en5 192.168.68.72/22 · link up.
found 1 EtherNet/IP device(s). plus 26 live IPv4 host(s).
unicast probes 1021. broadcasts 5. recv 4.
UDP source port 44818. targets 255.255.255.255. Wi-Fi was not used.
Found JOHNNY-PC 192.168.68.87 vendor=HMS / Softing / PC adapter
Found Live IPv4 host 192.168.68.1  …  192.168.68.90 vendor=Live IPv4
```

**Broken mask** (`192.168.68.253/16`):

```
unicast probes 0. send failures 1021 (192.168.71.254: No route to host).
Found JOHNNY-PC 192.168.68.87
```

**Earlier /22 before live-host probe:**

```
unicast probes 1021. broadcasts 6. recv 3.
send failures 4 (192.168.71.255: Network is unreachable).
Found JOHNNY-PC 192.168.68.87
```

**Own-echo (fixed):** `Unparsed UDP 24B from 192.168.68.72:44818` was our ListIdentity request; those are ignored now.

---

## 5. Hardware / topology (do not invent a switch)

| Item | Current observed value |
|---|---|
| Phone | Physical iPhone, Xcode Run (not TestFlight for these logs) |
| Dongle | Settings → Ethernet → USB 10/100/1000 LAN |
| iOS iface | `en5`, link up |
| Working IPv4 | Manual **`192.168.68.72/22`** (`255.255.252.0`) |
| Broken IPv4 | `192.168.68.253/16` |
| What answered EIP | **JOHNNY-PC `192.168.68.87`** (Windows EtherNet/IP / RSLinx-class stack) |
| Wi-Fi | On, but app must stay on `en5` |
| PLC | Bench unit. Brand / IP / BOOTP vs static **still unknown** |
| Gateway process | **Not used** in this test |

Older Oct 5 tests used `192.168.1.253/24` **direct RJ45 into the PLC** and `recv 0` (before multicast). Tonight’s LAN looks like a **shared 192.168.68.0/22** that also has the Windows PC. Confirm whether the dongle is on the PLC cable or on the house/shop LAN.

---

## 6. What we need from you

**Primary:** On this `192.168.68.0/22` cable we can already list live IPs and one EtherNet/IP node (JOHNNY-PC). The remaining gap is the handheld job: **read the bench PLC’s IP**. If none of the 26 live IPs is that PLC (none answered ListIdentity), how should we tell — and what should the technician plug into?

**Secondary:** Live-host identification just landed (`LiveHostIdentifier`: DNS, TCP fingerprint, HTTP title). Review whether that is the right iOS way to label `.1` / phones / printers, and whether ARP/neighbor MAC is possible on `en5`.

**Tertiary:** For a PLC with **no IP**, confirm there is no App Store-legal iOS path except a second box (FieldLink Gateway) on UDP/67 / DCP. If there is a path, specify APIs and entitlements.

**Please do not**

- Tell us to use Wi-Fi for PLC discovery.
- Tell us we must put a switch in the middle (owner has used a **direct** PLC cable before).
- Recommend a huge off-subnet RFC1918 sweep. iOS returns `ENETUNREACH` / `No route to host` without a route (1779 failures on Oct 5; 1021 on /16 tonight).
- Treat Xcode `cannot add handler` / pointeruid as the bug.
- Assume the one found device (JOHNNY-PC) is the bench PLC.

---

## 7. Success criteria

On the physical iPhone, dongle in the phone, RJ45 on the same Ethernet as the PLC:

1. Discover lists the PLC **name + IP** without the technician typing the IP first, when the PLC has IPv4 and EtherNet/IP.
2. Other live LAN hosts appear as live IPv4 (now proven: 26 hosts) and must not be confused with a PLC / EtherNet/IP identity. After the latest code, they should show hostname / open ports / HTTP title when available.
3. If nothing EtherNet/IP answers except a PC adapter, the UI/debug log must make that obvious (`recv`, hex, device name).
4. Silent/no-IP PLCs are an explicit “use FieldLink Gateway / handheld” result, not a fake empty success.

---

## 8. Repo pointers

| Path | What |
|---|---|
| `FieldLinkPLC/Services/LocalNetworkGatewayClient.swift` | Live USB-C scanner, ListIdentity, ICMP/TCP probe, `LiveHostIdentifier`, multicast check |
| `FieldLinkPLC/Views/GatewayView.swift` | `DiscoveryDebugView` |
| `FieldLinkPLC/FieldLinkPLC.entitlements` | `com.apple.developer.networking.multicast` |
| `FieldLinkPLC/Resources/Info.plist` | Local Network usage string + Bonjour |
| `gateway/` | Windows/Linux gateway (BOOTP/CIP writes) |
| `gateway/DIRECT-CABLE-SETUP.md` | Intended two-NIC gateway bench |
| `Docs/IOS-ETHERNET-DISCOVERY-ISSUE.md` | Oct 5 pre-multicast evidence |
