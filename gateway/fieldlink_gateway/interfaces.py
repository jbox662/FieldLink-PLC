from __future__ import annotations

import re
import socket
import subprocess
import sys
from dataclasses import dataclass

from . import ipv4


@dataclass(frozen=True)
class NetworkInterface:
    name: str
    address: str
    subnet_mask: str | None = None
    kind: str = ""

    @property
    def summary(self) -> str:
        kind = f" ({self.kind})" if self.kind else ""
        mask = f" / {self.subnet_mask}" if self.subnet_mask else ""
        return f"{self.name}{kind}  {self.address}{mask}"


def list_ipv4_interfaces() -> list[NetworkInterface]:
    if sys.platform == "win32":
        return _windows_interfaces()
    return _posix_interfaces()


def resolve_plant(interface: str | None, plant_ip: str | None) -> tuple[str, str]:
    """Return (interface name, IPv4) for the plant Ethernet port."""
    if plant_ip:
        if not ipv4.is_valid(plant_ip):
            raise RuntimeError(f"{plant_ip} is not a valid IPv4 address.")
        match = next((item for item in list_ipv4_interfaces() if item.address == plant_ip), None)
        return (match.name if match else plant_ip, plant_ip)

    if not interface:
        raise RuntimeError("Pass --plant-iface or --plant-ip. Use --list-ifaces to see adapters.")

    if ipv4.is_valid(interface):
        return resolve_plant(None, interface)

    adapters = list_ipv4_interfaces()
    wanted = interface.strip().lower()
    exact = [item for item in adapters if item.name.lower() == wanted]
    if exact:
        return exact[0].name, exact[0].address
    partial = [item for item in adapters if wanted in item.name.lower()]
    if len(partial) == 1:
        return partial[0].name, partial[0].address
    if partial:
        names = ", ".join(item.name for item in partial)
        raise RuntimeError(f"Several adapters match {interface!r}: {names}")
    available = ", ".join(item.summary for item in adapters) or "none"
    raise RuntimeError(f"No IPv4 adapter named {interface!r}. Available: {available}")


def parse_ipconfig(text: str) -> list[NetworkInterface]:
    adapters: list[NetworkInterface] = []
    current_name = None
    current_kind = ""
    current_ip = None
    current_mask = None

    header = re.compile(r"^(?P<kind>.+?) adapter (?P<name>.+):\s*$", re.IGNORECASE)

    def flush() -> None:
        nonlocal current_name, current_kind, current_ip, current_mask
        if current_name and current_ip:
            adapters.append(
                NetworkInterface(
                    name=current_name,
                    address=current_ip,
                    subnet_mask=current_mask,
                    kind=current_kind,
                )
            )
        current_name = None
        current_kind = ""
        current_ip = None
        current_mask = None

    for raw in text.splitlines():
        line = raw.rstrip()
        matched = header.match(line)
        if matched:
            flush()
            current_kind = matched.group("kind").strip()
            current_name = matched.group("name").strip()
            continue
        if current_name is None:
            continue
        lowered = line.lower()
        if "ipv4 address" in lowered or "ip address" in lowered:
            current_ip = _after_colon(line)
            if current_ip:
                current_ip = current_ip.split("(")[0].strip()
        elif "subnet mask" in lowered:
            current_mask = _after_colon(line)
    flush()
    return adapters


def parse_arp_dash_a(text: str) -> dict[str, str]:
    table: dict[str, str] = {}
    row = re.compile(
        r"^\s*(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F]{2}(?:[-:][0-9a-fA-F]{2}){5})\s+"
    )
    for line in text.splitlines():
        matched = row.match(line)
        if not matched:
            continue
        mac = matched.group(2).replace("-", ":").upper()
        ip_address = matched.group(1)
        if mac in {"00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF"}:
            continue
        if mac.startswith("01:") or ip_address.startswith(("224.", "239.")):
            continue
        table[ip_address] = mac
    return table


def _after_colon(line: str) -> str | None:
    if ":" not in line:
        return None
    value = line.split(":", 1)[1].strip()
    return value or None


def _windows_interfaces() -> list[NetworkInterface]:
    try:
        completed = subprocess.run(
            ["ipconfig"],
            capture_output=True,
            text=True,
            check=False,
            encoding="oem",
            errors="replace",
        )
        text = completed.stdout or ""
        if not text.strip():
            completed = subprocess.run(["ipconfig"], capture_output=True, text=True, check=False)
            text = completed.stdout or ""
        return parse_ipconfig(text)
    except OSError:
        return _posix_interfaces()


def _posix_interfaces() -> list[NetworkInterface]:
    adapters: list[NetworkInterface] = []
    try:
        for info in socket.if_nameindex():
            name = info[1]
            address = _posix_ipv4(name)
            if address:
                adapters.append(NetworkInterface(name=name, address=address))
    except (OSError, AttributeError):
        pass
    return adapters


def _posix_ipv4(name: str) -> str | None:
    try:
        import fcntl
        import struct as structlib

        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            ifreq = structlib.pack("256s", name[:15].encode("ascii", errors="ignore"))
            result = fcntl.ioctl(sock.fileno(), 0x8915, ifreq)
            return socket.inet_ntoa(result[20:24])
        finally:
            sock.close()
    except Exception:
        return None
