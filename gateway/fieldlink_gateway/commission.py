from __future__ import annotations

from dataclasses import replace

from . import ipv4
from .bootp import macs_equal
from .models import AddressChangeRequest, CommissioningEvent, GatewayError, NetworkProfile, PLCDevice
from .plant import PlantNetwork


class CommissioningEngine:
    def __init__(self, plant: PlantNetwork):
        self.plant = plant
        self.devices: list[PLCDevice] = []
        self.active_profile: NetworkProfile | None = None

    def discover(self, profile: NetworkProfile) -> list[PLCDevice]:
        if not ipv4.is_valid(profile.interface_ip_address):
            raise GatewayError(422, "invalid_profile", "The selected network profile has an invalid interface IPv4 address.")
        if not ipv4.is_valid(profile.subnet_mask):
            raise GatewayError(422, "invalid_profile", "The selected network profile has an invalid subnet mask.")
        if not ipv4.is_valid(profile.gateway_address):
            raise GatewayError(422, "invalid_profile", "The selected network profile has an invalid gateway address.")
        self.active_profile = profile
        self.devices = self.plant.discover(profile)
        return self.devices

    def apply_address_change(self, request: AddressChangeRequest) -> CommissioningEvent:
        if not request.technician_acknowledged:
            raise self._reject(
                request,
                GatewayError(422, "acknowledgement_required", "The safety acknowledgement is required before changing a device address."),
                f"Rejected address change for {request.device_name}: technician acknowledgement missing.",
            )
        for field_name, value in (
            ("IPv4 address", request.new_ip_address),
            ("subnet mask", request.subnet_mask),
            ("gateway address", request.gateway_address),
        ):
            if not ipv4.is_valid(value):
                raise self._reject(
                    request,
                    GatewayError(422, "invalid_address", f"{value} is not a valid {field_name}."),
                    f"Rejected {value} for {request.device_name}: invalid {field_name}.",
                )
        if self.active_profile and request.profile_name and request.profile_name != self.active_profile.name:
            raise self._reject(
                request,
                GatewayError(422, "profile_mismatch", "The address change profile does not match the profile used for discovery."),
                f"Rejected {request.new_ip_address} for {request.device_name}: profile mismatch.",
            )
        device = next((item for item in self.devices if item.id == request.device_id), None)
        if device is None:
            raise self._reject(
                request,
                GatewayError(422, "device_not_found", "The selected device is no longer available from the gateway."),
                f"Rejected address change: {request.device_name} is no longer in the discovery inventory.",
            )
        if ipv4.in_use(request.new_ip_address, self.devices, skip_id=device.id):
            raise self._reject(
                request,
                GatewayError(409, "duplicate_address", f"{request.new_ip_address} is already in use by a discovered device."),
                f"Rejected {request.new_ip_address} for {request.device_name}: address is already in use.",
            )
        occupant = self.plant.arp_mac(request.new_ip_address)
        if occupant and not macs_equal(occupant, device.mac_address):
            raise self._reject(
                request,
                GatewayError(409, "duplicate_address", f"{request.new_ip_address} is already answering ARP."),
                f"Rejected {request.new_ip_address} for {request.device_name}: ARP conflict with {occupant}.",
            )

        old_address = device.ip_address or "unassigned"
        try:
            if device.needs_bootp:
                self._assign_via_bootp(device, request)
            else:
                self._assign_via_cip(device, request)
        except GatewayError as error:
            raise self._reject(request, error, error.message) from error
        except Exception as error:
            raise self._reject(
                request,
                GatewayError(422, "write_failed", str(error) or "The gateway could not complete the address write."),
                f"Failed to change {request.device_name} from {old_address} to {request.new_ip_address}: {error}",
            ) from error

        verified = self.plant.verify(request.new_ip_address, device.serial_number)
        if verified is None:
            raise self._reject(
                request,
                GatewayError(422, "unacknowledged", "The gateway wrote the address but the device did not acknowledge on the new IP."),
                f"Did not confirm {request.new_ip_address} for {request.device_name} after the write.",
            )

        self.devices = [
            replace(
                verified,
                subnet_mask=request.subnet_mask,
                gateway_address=request.gateway_address,
                addressing_state="Static" if request.make_static else "DHCP",
            )
            if item.id == device.id or item.serial_number == device.serial_number
            else item
            for item in self.devices
        ]
        kind = "Static mode enabled" if request.make_static else "Address assigned"
        return CommissioningEvent(
            kind=kind,
            device_name=device.name,
            detail=f"Changed {old_address} to {request.new_ip_address} with profile {request.profile_name}.",
        )

    def _assign_via_bootp(self, device: PLCDevice, request: AddressChangeRequest) -> None:
        if not device.mac_address or device.mac_address in {"Unknown", "From identity response"}:
            raise GatewayError(422, "mac_required", "BOOTP assignment needs a MAC address for the selected device.")
        assigned = self.plant.bootp_assign(
            device.mac_address,
            request.new_ip_address,
            request.subnet_mask,
            request.gateway_address,
        )
        if not assigned:
            raise GatewayError(422, "bootp_timeout", "No matching BOOTP request arrived during the assignment window.")

    def _assign_via_cip(self, device: PLCDevice, request: AddressChangeRequest) -> None:
        if not device.ip_address:
            raise GatewayError(422, "cip_requires_ip", "CIP TCP/IP configuration requires the device to already have an IP address.")
        self.plant.cip_set_static(
            device.ip_address,
            request.new_ip_address,
            request.subnet_mask,
            request.gateway_address,
        )

    def _reject(self, request: AddressChangeRequest, error: GatewayError, detail: str) -> GatewayError:
        error.audit_event = CommissioningEvent(
            kind="Address assigned",
            device_name=request.device_name,
            detail=detail,
            successful=False,
        )
        return error
