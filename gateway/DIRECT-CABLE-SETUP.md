# FieldLink Gateway: Direct-Cable Bench Setup

This procedure provides the practical **SIM-IPE-style gateway path** when the iPhone app alone cannot determine an unknown PLC’s address or protocol. It uses **two independent Ethernet links**—not a switch, not Wi-Fi discovery, and not a bridge.

> Perform this only on an isolated, authorized bench PLC. Do not run a BOOTP/DHCP responder on a production network.

## Hardware topology

Use a Windows/Linux PC or industrial computer with **two physical Ethernet NICs**. A built-in Ethernet adapter plus a USB Ethernet adapter is sufficient.

```text
[iPhone USB-C Ethernet]
          |
          | direct RJ45 cable
          |
       eth_ui / Ethernet UI  [ FieldLink Gateway PC ]  Ethernet PLC / eth_plc
                                                          |
                                                          | direct RJ45 cable
                                                          |
                                                        [ Bench PLC ]
```

| Link | Purpose | Example static IPv4 configuration |
|---|---|---|
| `eth_ui` / **Ethernet UI** | iPhone-to-gateway HTTPS control plane | Gateway `172.31.254.1/30`; iPhone `172.31.254.2/30`; no router/gateway |
| `eth_plc` / **Ethernet PLC** | PLC-facing discovery and commissioning plane | Assign a temporary documented bench address only if required by the OS/tool; do not assume it matches the PLC subnet |

## Network isolation requirements

Before starting the FieldLink Gateway:

1. **Do not create a Network Bridge** between the two NICs.
2. Disable **Internet Connection Sharing**, NAT, and IP forwarding between the NICs.
3. Do not attach either port to the plant LAN, a Wi-Fi access point, router, or Ethernet switch for this test.
4. Set the UI NIC and iPhone Ethernet adapter to the static `/30` addresses above. Leave router/gateway blank on the iPhone.
5. Confirm the PLC-facing NIC is physically linked to the PLC, then power-cycle the authorized bench PLC while the gateway is ready to observe it.

The gateway’s PLC interface is the only interface that may send EtherNet/IP probes, observe BOOTP/DHCP, resolve ARP, or later run a protocol-specific commissioning operation. The iPhone remains only an authenticated UI.

## Windows: start a direct-link gateway

1. Copy the repository’s `gateway` directory to the Windows PC and open Command Prompt in that directory.
2. Install dependencies once:

   ```bat
   py -3 -m pip install -r requirements.txt
   ```

3. List the Ethernet interfaces and identify the **PLC-facing** adapter name:

   ```bat
   py -3 run.py --list-ifaces
   ```

4. Start the gateway, binding its HTTPS API specifically to the UI NIC address. Substitute the exact PLC-facing adapter name:

   ```bat
   py -3 run.py --plant-iface "Ethernet PLC" --listen 172.31.254.1:8443 --public-url https://172.31.254.1:8443/ --open-pairing
   ```

5. If Windows Firewall asks, permit only **Private-network TCP 8443** for this isolated UI link. Do not create a public firewall rule.
6. Record the URL, one-time pairing code, and certificate pin printed on the pairing card.
7. On the iPhone, choose **Gateway → Manage gateway session → Pair a physical FieldLink Gateway**, then enter exactly those three values.

For BOOTP address assignment, start Command Prompt as Administrator. The gateway’s normal discovery is read-only; do not approve an address change until the PLC identity/MAC and proposed address are reviewed.

## Linux: start a direct-link gateway

With `eth_plc` connected directly to the PLC and `eth_ui` statically configured as `172.31.254.1/30`:

```bash
cd gateway
python3 -m pip install -r requirements.txt
sudo python3 run.py --plant-iface eth_plc --listen 172.31.254.1:8443 --public-url https://172.31.254.1:8443/ --open-pairing
```

`sudo` (or `CAP_NET_BIND_SERVICE`) is required only if you intentionally enable BOOTP assignment on UDP/67.

## What to expect

| Gateway observation | Interpretation | Next action |
|---|---|---|
| No Ethernet carrier on `eth_plc` | Cable, PLC port, or physical link issue | Correct the physical layer before protocol testing. |
| BOOTP/DHCP request after PLC power-up | Likely unconfigured/no-IP device | Record MAC; use one MAC-reserved, operator-approved assignment window only. |
| EtherNet/IP `ListIdentity` reply | Responsive EtherNet/IP device | Show identity; use read-only confirmation before any write operation. |
| PROFINET DCP or other raw-L2 evidence | The target uses another protocol path | Classify it accurately; use a protocol-specific gateway module. |
| No relevant packets or replies | **Undetermined**, not “not a PLC” | Preserve gateway evidence and use the vendor-specific commissioning method. |

## Why this replaces the current iPhone-only bench path

An iPhone may use direct USB-C Ethernet for known-address traffic. However, unknown-IP EtherNet/IP broadcast requires Apple’s approved multicast capability, and normal iOS apps cannot access raw Ethernet required for PROFINET DCP or passive packet observation. The two-NIC gateway keeps those PLC-facing functions on a capable system while retaining a direct wired iPhone interface.
