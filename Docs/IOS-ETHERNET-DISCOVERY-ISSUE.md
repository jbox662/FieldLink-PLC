# FieldLink PLC — iOS USB-C Ethernet discovery cannot find a PLC

**Date:** 5 Oct 2026  
**App:** FieldLink PLC (`com.johnnybox.fieldlinkplc`, team `6MGV2KJVCV`)  
**Goal:** Match [TW Controls SIM-IPE](https://twcontrols.com/plc-trainers-all/p/sim-ipe) behavior: find EtherNet/IP devices on a live Ethernet cable **without the phone being on the same IP/subnet**, then read identity.

> **Implementation update:** This file preserves the original bench evidence. The iPhone scanner no longer performs the broad off-subnet unicast sweep described below. It now stops with an explicit diagnostic when the signed app lacks Apple-approved Multicast Networking, and the post-approval path uses only interface-bound, bounded broadcast probes. The immediate unknown/no-IP direct-cable workflow is documented in [`gateway/DIRECT-CABLE-SETUP.md`](../gateway/DIRECT-CABLE-SETUP.md).

This brief is for another engineer/agent (Manus). Please propose a **working iOS approach** (or a hard no with Apple-documented reasons) for discovery on a **direct iPhone USB-C Ethernet ↔ PLC** cable.

---

## 1. What we are building

Technician iPhone app for industrial commissioning.

- **Phone** = UI, audit, discovery controller.
- **Physical FieldLink Gateway** (Linux/Windows process) = BOOTP, CIP address writes, L2 work iOS cannot do.
- **Current test path** = no gateway. iPhone USB-C Ethernet dongle plugged **directly into the PLC**. No switch. No Windows PC in the path.

Desired discovery (from SIM-IPE product behavior):

- Not a port scan that “chokes” the network.
- Listen / probe on the wire for EtherNet/IP, ARP, Profinet, BOOTP/DHCP, etc.
- Devices **do not** need to share the tool’s IP or subnet.
- If a device sits silent (no IP, never talks), SIM-IPE also will not see it — except it **does** hear BOOTP/DHCP requests.

---

## 2. Hardware / network as tested (do not assume a switch)

| Item | Value |
|---|---|
| Phone | iPhone, USB-C, TestFlight |
| Dongle | Settings shows **Ethernet** → **USB 10/100/1000 LAN** |
| iOS interface | `en5` |
| Phone IPv4 | Manual `192.168.1.253` / `255.255.255.0` (Commissioning Lab profile) |
| Topology | **Dongle RJ45 plugged straight into the PLC Ethernet port** |
| Wi-Fi | On (`YokohamaMM`) but app binds discovery to `en5` via `IP_BOUND_IF` and does not intend to use Wi-Fi |
| PLC | Bench unit. Brand / current IP / BOOTP vs static **unknown to us**. User says it should be found without matching subnet. |

Link is real: later logs show `en5` **link up**.

---

## 3. What the app does today (live USB-C mode)

Code: `FieldLinkPLC/Services/LocalNetworkGatewayClient.swift`

1. Detect USB Ethernet (`en1+`, not `en0` Wi-Fi). Avoid relying only on `NWPathMonitor(.wiredEthernet)` — cheap USB LAN often types as `.other`.
2. Prompt Local Network via Bonjour browse `_fieldlink-gateway._tcp`.
3. Open UDP socket:
   - `SO_BROADCAST`, `SO_REUSEADDR`
   - Bind **`192.168.1.253:44818`**
   - `IP_BOUND_IF` = `en5`
4. Send EtherNet/IP **ListIdentity** (encapsulation command `0x0063`, 24-byte header, UDP **44818**).
5. Send:
   - `255.255.255.255` (limited broadcast)
   - subnet directed broadcast (`192.168.1.255`)
   - unicast ListIdentity to common industrial `/24`s:  
     `192.168.0/1/2/10/100`, `10.0.0`, `10.10.10`, `172.16.0` (hosts `.1–.254`, skip self)
6. Listen ~4s for replies; parse CIP identity item `0x000C`.

**Not implemented on iOS (and likely impossible in a normal App Store app):**

- Promiscuous L2 sniff (ARP/Profinet DCP EtherType `0x8892`)
- Bind UDP/67 BOOTP server
- Raw Ethernet frames

A Python **FieldLink Gateway** exists under `gateway/` for Windows/Linux (HTTPS pairing API, ListIdentity, BOOTP, CIP TCP/IP writes). That is **not** what is running in this test.

---

## 4. Evidence from the phone (activity export)

**2:12 PM, 5 Oct 2026** — live USB-C session, profile Commissioning Lab `192.168.1.253/24`:

```
EtherNet/IP ListIdentity on en5 192.168.1.253/24 · link up.
found 0 device(s).
unicast probes 253.
broadcasts 1.
recv 0.
send failures 1779 (172.16.0.254: No route to host).
No UDP 44818 replies.
```

Interpretation:

| Observation | Meaning |
|---|---|
| `link up` | PHY is up. Direct cable to PLC is not “unplugged.” |
| `unicast probes 253` | Only the **on-subnet** `/24` (~253 hosts) actually sent. That is `192.168.1.1–254` minus the phone. |
| `send failures 1779` + `No route to host` | iOS **will not ARP/send unicast** to `10.x`, `172.16.x`, other `192.168.x` from `192.168.1.253/24`. No default router on this Ethernet. Off-subnet unicast is dead. |
| `broadcasts 1` | Almost certainly **only** `192.168.1.255`. Limited broadcast `255.255.255.255` is dropped or fails (see §5). |
| `recv 0` | **Zero** UDP datagrams came back on 44818. Either the PLC is not `192.168.1.x`, it has **no IP** (BOOTP/0.0.0.0), or it does not answer ListIdentity. |

Earlier builds:

- Adapter not seen until detection treated USB LAN as Ethernet (`en5`).
- After IP was set, discovery still **0 devices**.
- Broadcast-only build (no host sweep) also **0 devices**.

---

## 5. Apple platform constraint (confirmed)

Archive with entitlement `com.apple.developer.networking.multicast` **failed**:

```
Provisioning profile "iOS Team Provisioning Profile: com.johnnybox.fieldlinkplc"
doesn't include the Multicast Networking capability.

Entitlement com.apple.developer.networking.multicast requires approval from Apple.
```

Apple docs / FAQ:

- Sending or receiving **UDP broadcast** (`255.255.255.255`) and **multicast** on iOS **requires** that restricted entitlement.
- Sending **UDP unicast** does **not**.
- Enforced on iOS 16+.
- Request form: https://developer.apple.com/contact/request/networking-multicast  
  Bundle ID `com.johnnybox.fieldlinkplc`. **Submitted; not approved yet.**

Without it, SIM-IPE-style “any IP on this cable” via limited broadcast **cannot work on a physical iPhone**.

Simulator does not enforce this the same way; we are testing **TestFlight on device**.

---

## 6. Why “just don’t require same subnet” is hard on iOS

On a **direct Ethernet cable**, L2 reaches the PLC regardless of IP.

| Method | Reaches PLC on unknown/wrong subnet? | iOS app? |
|---|---|---|
| UDP `255.255.255.255:44818` ListIdentity | Yes (limited broadcast, L2 flood) | **Blocked** until multicast entitlement |
| Directed broadcast `192.168.1.255` | Only if PLC is on that prefix | Maybe; still “broadcast”; PLC on `10.x` will ignore |
| Unicast ListIdentity to `192.168.1.x` | Only if PLC IP is in that `/24` | Works (253 sends succeeded) — **recv 0** |
| Unicast to other RFC1918 prefixes | Need a route; iOS sends to gateway | **ENETUNREACH** — 1779 failures |
| ARP / Profinet DCP / sniff | Yes (L2) | **No** raw sockets / BPF |
| Listen BOOTP UDP/67 | Finds unconfigured devices | **No** (privileged port + not a BOOTP server in sandbox) |

SIM-IPE is a dedicated Ethernet gadget that sniffs and serves BOOTP. The iPhone is not.

---

## 7. What we need Manus to answer

**Primary:** On a **physical iPhone**, USB-C Ethernet **directly** to a PLC, **how** can we discover EtherNet/IP identity when:

1. The PLC IP is unknown / different subnet, and  
2. Multicast entitlement is **not yet** granted?

If the honest answer is “you cannot until Apple grants multicast, and even then BOOTP-silent devices need a gateway,” say that clearly.

**Secondary (after entitlement is granted):**

- Correct socket setup for limited broadcast on a **specific interface** (`en5`) so it does **not** leak to Wi-Fi: `IP_BOUND_IF` vs `NWMulticastGroup` vs BSD `sendto(255.255.255.255)`.
- Whether we must bind `0.0.0.0:44818` vs interface IP to receive replies from “wrong” subnets.
- Whether ListIdentity requests must originate from source port 44818 (we already bind 44818).
- Any entitlement + `NSLocalNetworkUsageDescription` + Local Network permission gotchas.

**Tertiary:** If the PLC has **no IP** (factory BOOTP), is there **any** legal iOS path to see it without a second box listening on UDP/67? We believe no.

---

## 8. Packet we send (ListIdentity)

24-byte EtherNet/IP encapsulation, little-endian command `0x0063`, length 0, rest zeros. UDP dest port **44818**. This matches Rockwell/ODVA List Identity and our XCTest fixture parser.

---

## 9. Please do not

- Do not tell us to put a switch in the middle (user already has **direct** PLC cable).
- Do not tell us to “use Wi-Fi.”
- Do not suggest a full TCP port scan of the internet.
- Do not assume CompactLogix vs Siemens — brand is unconfirmed. If the device is Profinet-only, ListIdentity will never answer; say how iOS could do DCP if at all (we believe it cannot).

---

## 10. Success criteria

On TestFlight, dongle in phone, RJ45 in PLC, phone at `192.168.1.253/24`:

- If the PLC **already has some IPv4** (any subnet) and speaks EtherNet/IP, Discover lists it (name, vendor, IP from identity).
- If the PLC **has no IP**, the UI can say “silent / BOOTP” rather than a fake empty success — if iOS can know that at all.
- Debug screen already exists (**Gateway → Discovery debug**) showing interface, send/recv counts, send errno, hex of any RX datagrams. Next experiment should use that export.

---

## 11. Repo pointers

- iOS scanner: `FieldLinkPLC/Services/LocalNetworkGatewayClient.swift`
- Debug UI: `FieldLinkPLC/Views/GatewayView.swift` (`DiscoveryDebugView`)
- Entitlement file (not signed into TestFlight yet): `FieldLinkPLC/FieldLinkPLC.entitlements`
- Gateway (Windows/Linux, not used in this test): `gateway/`
