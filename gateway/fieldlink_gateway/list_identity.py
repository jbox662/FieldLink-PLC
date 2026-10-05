from __future__ import annotations

import struct
from dataclasses import dataclass

from .models import PLCDevice, utcnow
from .pairing import stable_device_id


LIST_IDENTITY_COMMAND = 0x0063
IDENTITY_ITEM = 0x000C
UDP_PORT = 44818


VENDOR_NAMES = {
    1: "Rockwell Automation",
    11: "Bosch",
    48: "Eaton",
    168: "WAGO",
    343: "Omron",
    419: "Siemens",
    806: "Phoenix Contact",
}


def request_packet() -> bytes:
    packet = bytearray(24)
    packet[0] = 0x63
    packet[1] = 0x00
    return bytes(packet)


def parse(response: bytes, source_address: str, mac_address: str = "Unknown") -> PLCDevice | None:
    if len(response) < 26:
        return None
    command = _u16le(response, 0)
    status = _u32le(response, 8)
    if command != LIST_IDENTITY_COMMAND or status != 0:
        return None
    payload_length = _u16le(response, 2)
    if len(response) < 24 + payload_length or payload_length < 2:
        return None
    payload = response[24 : 24 + payload_length]
    item_count = _u16le(payload, 0)
    offset = 2
    for _ in range(item_count):
        if len(payload) < offset + 4:
            return None
        type_id = _u16le(payload, offset)
        length = _u16le(payload, offset + 2)
        offset += 4
        if len(payload) < offset + length:
            return None
        item = payload[offset : offset + length]
        offset += length
        if type_id != IDENTITY_ITEM:
            continue
        return _identity_device(item, source_address, mac_address)
    return None


def _identity_device(item: bytes, source_address: str, mac_address: str) -> PLCDevice | None:
    if len(item) < 33:
        return None
    cursor = 2
    socket_ip = _socket_ip(item, cursor) or source_address
    cursor += 16
    if len(item) < cursor + 15:
        return None
    vendor_id = _u16le(item, cursor)
    device_type = _u16le(item, cursor + 2)
    product_code = _u16le(item, cursor + 4)
    major = item[cursor + 6]
    minor = item[cursor + 7]
    serial = _u32le(item, cursor + 10)
    cursor += 14
    if len(item) <= cursor:
        return None
    name_length = item[cursor]
    cursor += 1
    if len(item) < cursor + name_length:
        return None
    product_name = item[cursor : cursor + name_length].decode("latin-1", errors="replace").strip()
    display_name = product_name or "EtherNet/IP device"
    serial_text = f"{serial:08X}"
    ip_address = socket_ip or source_address
    return PLCDevice(
        id=stable_device_id(serial_text, ip_address, mac_address),
        name=display_name,
        vendor=VENDOR_NAMES.get(vendor_id, f"ODVA vendor {vendor_id}"),
        product=f"Code {product_code} · type {device_type}",
        revision=f"{major}.{minor}",
        serial_number=serial_text,
        mac_address=mac_address,
        ip_address=ip_address,
        subnet_mask=None,
        gateway_address=None,
        discovery_protocols=["EtherNet/IP"],
        addressing_state="Static",
        link_status="Linked",
        last_seen=utcnow(),
    )


def _socket_ip(data: bytes, offset: int) -> str | None:
    if len(data) < offset + 8:
        return None
    address = struct.unpack_from("!I", data, offset + 4)[0]
    if address == 0:
        return None
    return ".".join(str((address >> shift) & 0xFF) for shift in (24, 16, 8, 0))


def _u16le(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def _u32le(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


@dataclass
class EncapsulationHeader:
    command: int
    length: int
    session: int
    status: int
    context: bytes
    options: int

    @classmethod
    def parse(cls, data: bytes) -> "EncapsulationHeader":
        command, length, session, status = struct.unpack_from("<HHII", data, 0)
        context = data[12:20]
        options = struct.unpack_from("<I", data, 20)[0]
        return cls(command, length, session, status, context, options)
