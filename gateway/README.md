# FieldLink Gateway

This is the plant-side box that pairs with the FieldLink PLC iPhone app. The phone stays the technician controller. This process owns industrial Ethernet: EtherNet/IP ListIdentity, BOOTP assignment, and CIP TCP/IP address writes.

Requires **Python 3.9+**. On Windows also run `py -3 -m pip install cryptography` if `openssl` is not installed.

Do not expose the HTTPS API on the public internet.

## Windows PC

1. Copy the `gateway` folder onto the PC.
2. Install Python from https://www.python.org/downloads/ and check **Add python.exe to PATH**.
3. Open Command Prompt in the `gateway` folder and install the TLS helper:

```bat
py -3 -m pip install -r requirements.txt
```

4. Pair without a PLC first. Double-click `run-demo.bat`, or:

```bat
py -3 run.py --demo --listen 0.0.0.0:8443
```

5. Copy the printed **URL**, **Code**, and **Pin**.
6. Put the iPhone on the same Wi-Fi as the PC.
7. If Windows asks, allow FieldLink on a **Private** network. Also allow TCP **8443** in Windows Firewall.
8. In the iPhone app: **Gateway → Pair a physical FieldLink Gateway**.

For real PLC discovery, plug the PC Ethernet into the PLC switch, then:

```bat
py -3 run.py --list-ifaces
py -3 run.py --plant-iface Ethernet --listen 0.0.0.0:8443
```

If the adapter name has a space, quote it (`"Ethernet 2"`) or pass `--plant-ip 192.168.1.50` instead. Run Command Prompt as Administrator if you need BOOTP address assignment.

If the PC only has one Ethernet port, plug that into the PLC switch and plug the iPhone USB-C Ethernet into the same switch. Use the PC’s Ethernet IP as the pairing URL.

## Raspberry Pi / Linux

```bash
python3 run.py --demo --listen 0.0.0.0:8443
sudo python3 run.py --plant-iface eth0 --listen 0.0.0.0:8443
```

## What the gateway does

1. Listens for HTTPS on port 8443 (control plane)
2. Opens a pairing window for 15 minutes at start
3. Discovers EtherNet/IP devices on the plant interface only
4. Changes addresses only after the phone sends `technicianAcknowledged: true`
5. Uses BOOTP for unconfigured devices and CIP TCP/IP object writes for devices that already have an IP
6. Does not report success until the device answers ListIdentity on the new address

## Tests

```bash
python3 -m unittest discover -s tests -v
```

Validate BOOTP and CIP writes on isolated, non-production equipment before field use.
