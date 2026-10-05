from __future__ import annotations

import ipaddress
import re
import socket
import struct
from typing import Iterable


_OCTET = re.compile(r"^(0|[1-9]\d{0,2})$")


def is_valid(address: str) -> bool:
    octets = address.split(".")
    if len(octets) != 4:
        return False
    for octet in octets:
        if not _OCTET.fullmatch(octet):
            return False
        value = int(octet)
        if value < 0 or value > 255:
            return False
        if len(octet) > 1 and octet.startswith("0"):
            return False
    return True


def packed(address: str) -> bytes:
    return socket.inet_aton(address)


def from_packed(data: bytes) -> str:
    return socket.inet_ntoa(data)


def from_uint32_be(value: int) -> str:
    return from_packed(struct.pack("!I", value))


def to_uint32_be(address: str) -> int:
    return struct.unpack("!I", packed(address))[0]


def subnet_hosts(interface_ip: str, subnet_mask: str) -> list[str]:
    network = ipaddress.IPv4Network(f"{interface_ip}/{subnet_mask}", strict=False)
    if network.num_addresses > 256:
        return []
    return [str(host) for host in network.hosts()]


def broadcast(interface_ip: str, subnet_mask: str) -> str:
    network = ipaddress.IPv4Network(f"{interface_ip}/{subnet_mask}", strict=False)
    return str(network.broadcast_address)


def in_use(address: str, devices: Iterable[object], skip_id: str | None = None) -> bool:
    for device in devices:
        if skip_id and getattr(device, "id", None) == skip_id:
            continue
        if getattr(device, "ip_address", None) == address:
            return True
    return False
