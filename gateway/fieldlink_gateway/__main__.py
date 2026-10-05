from __future__ import annotations

import argparse
import os
import signal
import socket
import sys
import threading
from pathlib import Path

from .audit import AuditLog
from .commission import CommissioningEngine
from .identity import load_or_create
from .interfaces import list_ipv4_interfaces, resolve_plant
from .pairing import PairingState
from .plant import FakePlant, RealPlant
from .api import GatewayRuntime, serve
from .models import CommissioningEvent, PLCDevice, utcnow
from .pairing_card import write_pairing_files


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="FieldLink Gateway — industrial Ethernet commissioning boundary.")
    parser.add_argument("--data-dir", default=str(Path.home() / ".fieldlink-gateway"))
    parser.add_argument("--listen", default="0.0.0.0:8443", help="Control-plane bind address, host:port.")
    parser.add_argument("--public-url", default="", help="HTTPS URL printed on the pairing card.")
    parser.add_argument("--plant-iface", default=os.environ.get("FIELDLINK_PLANT_IFACE", ""))
    parser.add_argument("--plant-ip", default=os.environ.get("FIELDLINK_PLANT_IP", ""), help="Plant NIC IPv4 if you would rather not pass the adapter name.")
    parser.add_argument("--list-ifaces", action="store_true", help="Print IPv4 adapters and exit.")
    parser.add_argument("--hostname", default="fieldlink-gateway.local")
    parser.add_argument("--demo", action="store_true", help="Serve the API against an in-process fake plant (no Ethernet writes).")
    parser.add_argument("--open-pairing", action="store_true", help="Keep the pairing window open after start.")
    args = parser.parse_args(argv)

    if args.list_ifaces:
        adapters = list_ipv4_interfaces()
        if not adapters:
            print("No IPv4 adapters found.")
            return 1
        for adapter in adapters:
            print(adapter.summary)
        return 0

    data_dir = Path(args.data_dir).expanduser()
    identity = load_or_create(data_dir, hostname=args.hostname)
    pairing = PairingState(identity.pairing_code)
    if args.open_pairing:
        pairing.open_window()

    host, port = _parse_listen(args.listen)
    public_url = args.public_url or f"https://{_guess_reachable_ip(host)}:{port}/"

    if args.demo:
        plant = FakePlant(_demo_devices())
    else:
        try:
            name, address = resolve_plant(args.plant_iface or None, args.plant_ip or None)
        except RuntimeError as error:
            print(str(error), file=sys.stderr)
            print("Run with --list-ifaces to see adapters, or --demo to pair without a PLC.", file=sys.stderr)
            return 2
        plant = RealPlant(name, address)

    runtime = GatewayRuntime(
        identity=identity,
        pairing=pairing,
        audit=AuditLog(data_dir / "audit.json"),
        engine=CommissioningEngine(plant),
        public_url=public_url,
    )
    runtime.audit.record(
        CommissioningEvent(
            kind="Gateway connected",
            detail=f"FieldLink Gateway {identity.serial_number} started. Pairing window is open. Plant interface: {plant.link_speed()}.",
        )
    )

    card_path = write_pairing_files(data_dir, public_url, identity)
    print(identity.pairing_card(public_url))
    print(f"\nPairing card also written to {card_path}")
    if sys.platform == "win32":
        print("Allow TCP 8443 in Windows Firewall if the iPhone cannot connect.")
        print("For real BOOTP writes, run this Command Prompt as Administrator.")
    elif not args.demo:
        print("BOOTP assignment requires root or CAP_NET_BIND_SERVICE on UDP/67.")

    httpd = serve(runtime, host, port)

    def reopen_pairing(_signum, _frame):
        until = pairing.open_window()
        print(f"Pairing window reopened until {until:.0f} (unix time). Code: {identity.pairing_code}")

    if hasattr(signal, "SIGUSR1"):
        signal.signal(signal.SIGUSR1, reopen_pairing)

    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    print(f"Listening on https://{host}:{port}/  (stop with Ctrl-C)")
    try:
        thread.join()
    except KeyboardInterrupt:
        httpd.shutdown()
    return 0


def _parse_listen(value: str) -> tuple[str, int]:
    if ":" not in value:
        return value, 8443
    host, port = value.rsplit(":", 1)
    return host, int(port)


def _guess_reachable_ip(bind_host: str) -> str:
    if bind_host not in {"0.0.0.0", "::", ""}:
        return bind_host
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("1.1.1.1", 80))
        return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()


def _demo_devices() -> list[PLCDevice]:
    return [
        PLCDevice(
            id="e8c49641-31e4-4514-a4b4-6b35d785dbaa",
            name="Filler Cell Controller",
            vendor="Rockwell Automation",
            product="CompactLogix 5380",
            revision="34.011",
            serial_number="CF61A0B2",
            mac_address="00:1D:9C:73:20:11",
            ip_address="192.168.1.10",
            subnet_mask="255.255.255.0",
            gateway_address="192.168.1.1",
            discovery_protocols=["EtherNet/IP", "ARP"],
            addressing_state="Static",
            link_status="Linked",
            last_seen=utcnow(),
        ),
        PLCDevice(
            id="c9b94843-2045-427d-8a6e-9e9b1e1eb6ec",
            name="Cartoner Remote I/O",
            vendor="Rockwell Automation",
            product="1734-AENTR POINT I/O",
            revision="6.013",
            serial_number="E1F32017",
            mac_address="00:00:BC:6F:21:90",
            ip_address="192.168.1.24",
            subnet_mask="255.255.255.0",
            gateway_address="192.168.1.1",
            discovery_protocols=["EtherNet/IP", "DHCP", "ARP"],
            addressing_state="DHCP",
            link_status="Linked",
            last_seen=utcnow(),
        ),
        PLCDevice(
            id="ea7800b0-27de-460b-9d2e-a73178151804",
            name="Conveyor Station PLC",
            vendor="Siemens",
            product="SIMATIC ET 200SP",
            revision="4.5",
            serial_number="6ES7-155-6AU01",
            mac_address="3C:7C:3F:14:09:B4",
            ip_address=None,
            subnet_mask=None,
            gateway_address=None,
            discovery_protocols=["Profinet", "BOOTP", "ARP"],
            addressing_state="Unconfigured",
            link_status="Linked",
            last_seen=utcnow(),
        ),
    ]


if __name__ == "__main__":
    raise SystemExit(main())
