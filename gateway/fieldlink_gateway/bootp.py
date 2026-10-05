from __future__ import annotations

import socket
import struct
from dataclasses import dataclass

from . import ipv4


BOOTP_REQUEST = 1
BOOTP_REPLY = 2
BOOTP_MAGIC = bytes((99, 130, 83, 99))


@dataclass
class BootpRequest:
    xid: bytes
    chaddr: bytes
    mac_address: str
    giaddr: str
    flags: int


def parse_request(packet: bytes) -> BootpRequest | None:
    if len(packet) < 236:
        return None
    op, htype, hlen = packet[0], packet[1], packet[2]
    if op != BOOTP_REQUEST or htype != 1 or hlen != 6:
        return None
    xid = packet[4:8]
    flags = struct.unpack_from("!H", packet, 10)[0]
    giaddr = ipv4.from_packed(packet[24:28])
    chaddr = packet[28:34]
    return BootpRequest(
        xid=xid,
        chaddr=chaddr,
        mac_address=format_mac(chaddr),
        giaddr=giaddr,
        flags=flags,
    )


def build_reply(
    request: BootpRequest,
    yiaddr: str,
    siaddr: str,
    subnet_mask: str,
    router: str,
) -> bytes:
    packet = bytearray(300)
    packet[0] = BOOTP_REPLY
    packet[1] = 1
    packet[2] = 6
    packet[4:8] = request.xid
    struct.pack_into("!H", packet, 10, request.flags)
    packet[16:20] = ipv4.packed(yiaddr)
    packet[20:24] = ipv4.packed(siaddr)
    packet[24:28] = ipv4.packed(request.giaddr)
    packet[28:34] = request.chaddr
    packet[236:240] = BOOTP_MAGIC
    options = bytearray()
    options += bytes((1, 4)) + ipv4.packed(subnet_mask)
    options += bytes((3, 4)) + ipv4.packed(router)
    options += bytes((54, 4)) + ipv4.packed(siaddr)
    options.append(255)
    packet[240 : 240 + len(options)] = options
    return bytes(packet)


def format_mac(raw: bytes) -> str:
    return ":".join(f"{byte:02X}" for byte in raw[:6])


def parse_mac(value: str) -> bytes:
    parts = value.replace("-", ":").split(":")
    if len(parts) != 6:
        raise ValueError(f"Invalid MAC address: {value}")
    return bytes(int(part, 16) for part in parts)


def macs_equal(left: str, right: str) -> bool:
    try:
        return parse_mac(left) == parse_mac(right)
    except ValueError:
        return False


def sockaddr_broadcast() -> tuple:
    return ("255.255.255.255", 68)
