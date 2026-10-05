from __future__ import annotations

import socket
import struct

from . import ipv4


EIP_PORT = 44818
REGISTER_SESSION = 0x0065
SEND_RR_DATA = 0x006F
CIP_SET_ATTRIBUTE_SINGLE = 0x10
CIP_RESET = 0x05
TCPIP_CLASS = 0xF5
IDENTITY_CLASS = 0x01
TCPIP_CONFIG_ATTRIBUTE = 5
TCPIP_CONTROL_ATTRIBUTE = 3
STATIC_CONTROL = 0


class CIPError(RuntimeError):
    pass


def set_static_address(host: str, ip_address: str, subnet_mask: str, gateway_address: str, timeout: float = 8.0) -> None:
    with socket.create_connection((host, EIP_PORT), timeout=timeout) as sock:
        session = _register_session(sock)
        _set_attribute(
            sock,
            session,
            class_id=TCPIP_CLASS,
            instance=1,
            attribute=TCPIP_CONFIG_ATTRIBUTE,
            data=_interface_configuration(ip_address, subnet_mask, gateway_address),
        )
        _set_attribute(
            sock,
            session,
            class_id=TCPIP_CLASS,
            instance=1,
            attribute=TCPIP_CONTROL_ATTRIBUTE,
            data=struct.pack("<I", STATIC_CONTROL),
        )


def reset_identity(host: str, timeout: float = 4.0) -> None:
    with socket.create_connection((host, EIP_PORT), timeout=timeout) as sock:
        session = _register_session(sock)
        path = bytes((0x20, IDENTITY_CLASS, 0x24, 0x01))
        _send_rr(sock, session, bytes((CIP_RESET, 2)) + path + bytes((0x00,)))


def _register_session(sock: socket.socket) -> int:
    payload = struct.pack("<HH", 1, 0)
    sock.sendall(_encapsulation(REGISTER_SESSION, payload, session=0))
    header, body = _recv_encapsulation(sock)
    if header[0] != REGISTER_SESSION or header[3] != 0:
        raise CIPError("EtherNet/IP RegisterSession failed.")
    return header[2]


def _set_attribute(sock: socket.socket, session: int, class_id: int, instance: int, attribute: int, data: bytes) -> None:
    path = bytes((0x20, class_id, 0x24, instance, 0x30, attribute))
    cip = bytes((CIP_SET_ATTRIBUTE_SINGLE, len(path) // 2)) + path + data
    _send_rr(sock, session, cip)


def _send_rr(sock: socket.socket, session: int, cip: bytes) -> bytes:
    body = struct.pack("<HH", 0, 0)  # interface handle, timeout ticks
    body += struct.pack("<H", 2)
    body += struct.pack("<HH", 0x0000, 0)  # null address item
    body += struct.pack("<HH", 0x00B2, len(cip))
    body += cip
    sock.sendall(_encapsulation(SEND_RR_DATA, body, session=session))
    header, response_body = _recv_encapsulation(sock)
    if header[0] != SEND_RR_DATA or header[3] != 0:
        raise CIPError("EtherNet/IP SendRRData failed.")
    status = _cip_status(response_body)
    if status != 0:
        raise CIPError(f"CIP service rejected the request (status 0x{status:02X}).")
    return response_body


def _cip_status(body: bytes) -> int:
    # CPF: skip interface/timeout (4), item count, null item, then unconnected data item.
    offset = 4
    if len(body) < offset + 2:
        return 0xFF
    item_count = struct.unpack_from("<H", body, offset)[0]
    offset += 2
    cip = b""
    for _ in range(item_count):
        if len(body) < offset + 4:
            return 0xFF
        type_id, length = struct.unpack_from("<HH", body, offset)
        offset += 4
        item = body[offset : offset + length]
        offset += length
        if type_id == 0x00B2:
            cip = item
    if len(cip) < 3:
        return 0xFF
    return cip[2]


def _interface_configuration(ip_address: str, subnet_mask: str, gateway_address: str) -> bytes:
    domain = b""
    payload = (
        struct.pack("!I", ipv4.to_uint32_be(ip_address))
        + struct.pack("!I", ipv4.to_uint32_be(subnet_mask))
        + struct.pack("!I", ipv4.to_uint32_be(gateway_address))
        + struct.pack("!I", 0)
        + struct.pack("!I", 0)
        + struct.pack("<H", len(domain))
        + domain
    )
    if len(payload) % 2:
        payload += b"\x00"
    return payload


def _encapsulation(command: int, payload: bytes, session: int) -> bytes:
    header = struct.pack(
        "<HHII8sI",
        command,
        len(payload),
        session,
        0,
        b"\x00" * 8,
        0,
    )
    return header + payload


def _recv_encapsulation(sock: socket.socket) -> tuple[tuple[int, int, int, int], bytes]:
    header = _recvexact(sock, 24)
    command, length, session, status = struct.unpack_from("<HHII", header, 0)
    body = _recvexact(sock, length) if length else b""
    return (command, length, session, status), body


def _recvexact(sock: socket.socket, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        piece = sock.recv(size - len(chunks))
        if not piece:
            raise CIPError("EtherNet/IP connection closed.")
        chunks.extend(piece)
    return bytes(chunks)
