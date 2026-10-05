from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any
from uuid import uuid4


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def iso8601(value: datetime) -> str:
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    value = value.astimezone(timezone.utc)
    return value.strftime("%Y-%m-%dT%H:%M:%S.") + f"{int(value.microsecond / 1000):03d}Z"


@dataclass
class NetworkProfile:
    id: str
    name: str
    interface_ip_address: str
    subnet_mask: str
    gateway_address: str
    notes: str = ""

    @classmethod
    def from_json(cls, payload: dict[str, Any]) -> "NetworkProfile":
        return cls(
            id=str(payload.get("id") or uuid4()),
            name=str(payload.get("name") or ""),
            interface_ip_address=str(payload.get("interfaceIPAddress") or ""),
            subnet_mask=str(payload.get("subnetMask") or ""),
            gateway_address=str(payload.get("gatewayAddress") or ""),
            notes=str(payload.get("notes") or ""),
        )


@dataclass
class PLCDevice:
    id: str
    name: str
    vendor: str
    product: str
    revision: str
    serial_number: str
    mac_address: str
    ip_address: str | None
    subnet_mask: str | None
    gateway_address: str | None
    discovery_protocols: list[str]
    addressing_state: str
    link_status: str
    last_seen: datetime = field(default_factory=utcnow)

    @property
    def needs_bootp(self) -> bool:
        return self.ip_address is None or self.addressing_state in {"Unconfigured", "BOOTP"}

    def to_json(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "vendor": self.vendor,
            "product": self.product,
            "revision": self.revision,
            "serialNumber": self.serial_number,
            "macAddress": self.mac_address,
            "ipAddress": self.ip_address,
            "subnetMask": self.subnet_mask,
            "gatewayAddress": self.gateway_address,
            "discoveryProtocols": self.discovery_protocols,
            "addressingState": self.addressing_state,
            "linkStatus": self.link_status,
            "lastSeen": iso8601(self.last_seen),
        }


@dataclass
class AddressChangeRequest:
    id: str
    device_id: str
    device_name: str
    current_ip_address: str | None
    new_ip_address: str
    subnet_mask: str
    gateway_address: str
    profile_name: str
    make_static: bool
    technician_acknowledged: bool

    @classmethod
    def from_json(cls, payload: dict[str, Any]) -> "AddressChangeRequest":
        return cls(
            id=str(payload.get("id") or uuid4()),
            device_id=str(payload.get("deviceID") or ""),
            device_name=str(payload.get("deviceName") or ""),
            current_ip_address=payload.get("currentIPAddress"),
            new_ip_address=str(payload.get("newIPAddress") or ""),
            subnet_mask=str(payload.get("subnetMask") or ""),
            gateway_address=str(payload.get("gatewayAddress") or ""),
            profile_name=str(payload.get("profileName") or ""),
            make_static=bool(payload.get("makeStatic")),
            technician_acknowledged=bool(payload.get("technicianAcknowledged")),
        )


@dataclass
class CommissioningEvent:
    kind: str
    detail: str
    device_name: str | None = None
    successful: bool = True
    id: str = field(default_factory=lambda: str(uuid4()))
    timestamp: datetime = field(default_factory=utcnow)

    def to_json(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "timestamp": iso8601(self.timestamp),
            "kind": self.kind,
            "deviceName": self.device_name,
            "detail": self.detail,
            "successful": self.successful,
        }


@dataclass
class GatewayInfo:
    identifier: str
    firmware_version: str
    serial_number: str
    link_speed: str
    simulator_mode: bool = False

    def to_json(self) -> dict[str, Any]:
        return {
            "identifier": self.identifier,
            "firmwareVersion": self.firmware_version,
            "serialNumber": self.serial_number,
            "linkSpeed": self.link_speed,
            "simulatorMode": self.simulator_mode,
        }


class GatewayError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.audit_event: CommissioningEvent | None = None

    def to_json(self) -> dict[str, str]:
        return {"code": self.code, "message": self.message}


def as_public_dict(value: Any) -> dict[str, Any]:
    return asdict(value)
