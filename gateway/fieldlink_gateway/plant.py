from __future__ import annotations

import select
import socket
import struct
import subprocess
import sys
import time
from dataclasses import replace
from typing import Protocol

from . import bootp, ipv4, list_identity
from .interfaces import parse_arp_dash_a, resolve_plant
from .models import NetworkProfile, PLCDevice, utcnow


class PlantNetwork(Protocol):
    def link_speed(self) -> str: ...
    def discover(self, profile: NetworkProfile, timeout: float = 2.8) -> list[PLCDevice]: ...
    def arp_mac(self, ip_address: str, timeout: float = 0.6) -> str | None: ...
    def bootp_assign(
        self,
        mac_address: str,
        ip_address: str,
        subnet_mask: str,
        gateway_address: str,
        timeout: float = 45.0,
    ) -> bool: ...
    def cip_set_static(
        self,
        current_ip: str,
        ip_address: str,
        subnet_mask: str,
        gateway_address: str,
    ) -> None: ...
    def verify(self, ip_address: str, serial_number: str, timeout: float = 8.0) -> PLCDevice | None: ...


class RealPlant:
    def __init__(self, interface: str, interface_ip: str | None = None):
        name, address = resolve_plant(interface, interface_ip)
        self.interface = name
        self.interface_ip = address

    def link_speed(self) -> str:
        address = self.interface_ip or "no IPv4"
        return f"{self.interface} · {address}"

    def discover(self, profile: NetworkProfile, timeout: float = 5.0) -> list[PLCDevice]:
        interface_ip = profile.interface_ip_address or self.interface_ip
        if not interface_ip:
            raise RuntimeError("The plant Ethernet interface has no IPv4 address.")
        fd = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            fd.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            fd.settimeout(0.25)
            _bind_to_interface(fd, self.interface, interface_ip)
            packet = list_identity.request_packet()
            targets = ["255.255.255.255", ipv4.broadcast(interface_ip, profile.subnet_mask)]
            found: dict[str, PLCDevice] = {}
            deadline = time.time() + timeout
            next_retransmit = 0.0
            while time.time() < deadline:
                if time.time() >= next_retransmit:
                    for host in targets:
                        fd.sendto(packet, (host, list_identity.UDP_PORT))
                    next_retransmit = time.time() + 1.2
                ready, _, _ = select.select([fd], [], [], max(0.0, min(0.25, deadline - time.time())))
                if not ready:
                    continue
                data, address = fd.recvfrom(2048)
                source = address[0]
                mac = self.arp_mac(source) or "Unknown"
                device = list_identity.parse(data, source, mac)
                if device and device.ip_address:
                    found[f"{device.serial_number}|{device.ip_address}"] = device
            return sorted(found.values(), key=lambda item: item.ip_address or "")
        finally:
            fd.close()

    def arp_mac(self, ip_address: str, timeout: float = 0.6) -> str | None:
        table = _read_arp_table()
        if ip_address in table:
            return table[ip_address]
        _send_udp_ping(ip_address)
        time.sleep(min(timeout, 0.2))
        return _read_arp_table().get(ip_address)

    def bootp_assign(
        self,
        mac_address: str,
        ip_address: str,
        subnet_mask: str,
        gateway_address: str,
        timeout: float = 45.0,
    ) -> bool:
        if not self.interface_ip:
            raise RuntimeError("BOOTP requires an IPv4 address on the plant Ethernet interface.")
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            _bind_to_interface(sock, self.interface, "0.0.0.0", port=67)
            sock.settimeout(1.0)
            deadline = time.time() + timeout
            while time.time() < deadline:
                ready, _, _ = select.select([sock], [], [], max(0.0, min(1.0, deadline - time.time())))
                if not ready:
                    continue
                data, _address = sock.recvfrom(1024)
                request = bootp.parse_request(data)
                if request is None or not bootp.macs_equal(request.mac_address, mac_address):
                    continue
                reply = bootp.build_reply(
                    request,
                    yiaddr=ip_address,
                    siaddr=self.interface_ip,
                    subnet_mask=subnet_mask,
                    router=gateway_address,
                )
                sock.sendto(reply, ("255.255.255.255", 68))
                return True
            return False
        finally:
            sock.close()

    def cip_set_static(
        self,
        current_ip: str,
        ip_address: str,
        subnet_mask: str,
        gateway_address: str,
    ) -> None:
        from . import cip

        cip.set_static_address(current_ip, ip_address, subnet_mask, gateway_address)

    def verify(self, ip_address: str, serial_number: str, timeout: float = 8.0) -> PLCDevice | None:
        fd = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            fd.settimeout(0.4)
            if self.interface_ip:
                _bind_to_interface(fd, self.interface, self.interface_ip)
            packet = list_identity.request_packet()
            deadline = time.time() + timeout
            while time.time() < deadline:
                fd.sendto(packet, (ip_address, list_identity.UDP_PORT))
                ready, _, _ = select.select([fd], [], [], 0.5)
                if not ready:
                    continue
                data, address = fd.recvfrom(2048)
                device = list_identity.parse(data, address[0], self.arp_mac(address[0]) or "Unknown")
                if device and device.serial_number == serial_number:
                    device.last_seen = utcnow()
                    return device
            return None
        finally:
            fd.close()


class FakePlant:
    """In-process plant used by contract tests. No sockets, no hardware."""

    def __init__(self, devices: list[PLCDevice] | None = None):
        self.devices = list(devices or [])
        self.bootp_pending: dict[str, PLCDevice] = {}
        self.cip_writes: list[tuple[str, str]] = []
        self.fail_cip = False
        self.fail_bootp = False

    def link_speed(self) -> str:
        return "fake0 · 192.168.1.253"

    def discover(self, profile: NetworkProfile, timeout: float = 2.8) -> list[PLCDevice]:
        now = utcnow()
        self.devices = [replace(device, last_seen=now, link_status="Linked") for device in self.devices]
        return list(self.devices)

    def arp_mac(self, ip_address: str, timeout: float = 0.6) -> str | None:
        for device in self.devices:
            if device.ip_address == ip_address:
                return device.mac_address
        return None

    def bootp_assign(
        self,
        mac_address: str,
        ip_address: str,
        subnet_mask: str,
        gateway_address: str,
        timeout: float = 45.0,
    ) -> bool:
        if self.fail_bootp:
            return False
        for index, device in enumerate(self.devices):
            if bootp.macs_equal(device.mac_address, mac_address):
                self.devices[index] = replace(
                    device,
                    ip_address=ip_address,
                    subnet_mask=subnet_mask,
                    gateway_address=gateway_address,
                    addressing_state="Static",
                    last_seen=utcnow(),
                )
                return True
        return False

    def cip_set_static(
        self,
        current_ip: str,
        ip_address: str,
        subnet_mask: str,
        gateway_address: str,
    ) -> None:
        from .cip import CIPError

        if self.fail_cip:
            raise CIPError("CIP write failed.")
        self.cip_writes.append((current_ip, ip_address))
        for index, device in enumerate(self.devices):
            if device.ip_address == current_ip:
                self.devices[index] = replace(
                    device,
                    ip_address=ip_address,
                    subnet_mask=subnet_mask,
                    gateway_address=gateway_address,
                    addressing_state="Static",
                    last_seen=utcnow(),
                )
                return
        raise CIPError("Device did not accept the CIP TCP/IP write.")

    def verify(self, ip_address: str, serial_number: str, timeout: float = 8.0) -> PLCDevice | None:
        for device in self.devices:
            if device.ip_address == ip_address and device.serial_number == serial_number:
                return device
        return None


def _bind_to_interface(sock: socket.socket, interface: str, address: str, port: int = 0) -> None:
    if sys.platform == "linux":
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, interface.encode("ascii") + b"\x00")
        except (OSError, AttributeError):
            pass
    elif sys.platform == "darwin":
        try:
            index = socket.if_nametoindex(interface)
            sock.setsockopt(socket.IPPROTO_IP, 25, struct.pack("I", index))  # IP_BOUND_IF
        except OSError:
            pass
    sock.bind((address, port))


def _read_arp_table() -> dict[str, str]:
    if sys.platform == "win32":
        try:
            completed = subprocess.run(
                ["arp", "-a"],
                capture_output=True,
                text=True,
                check=False,
                encoding="oem",
                errors="replace",
            )
            return parse_arp_dash_a(completed.stdout or "")
        except OSError:
            return {}
    table: dict[str, str] = {}
    try:
        with open("/proc/net/arp", encoding="utf-8") as handle:
            next(handle, None)
            for line in handle:
                parts = line.split()
                if len(parts) >= 4 and parts[3] != "00:00:00:00:00:00":
                    table[parts[0]] = parts[3].upper()
    except OSError:
        pass
    return table


def _send_udp_ping(ip_address: str) -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.settimeout(0.1)
        sock.sendto(b"\x00", (ip_address, 9))
    except OSError:
        pass
    finally:
        sock.close()
