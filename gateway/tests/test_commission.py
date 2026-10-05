from __future__ import annotations

import unittest
from uuid import uuid4

from fieldlink_gateway.commission import CommissioningEngine
from fieldlink_gateway.models import AddressChangeRequest, GatewayError, NetworkProfile, PLCDevice, utcnow
from fieldlink_gateway.plant import FakePlant


def _device(**overrides) -> PLCDevice:
    values = dict(
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
    )
    values.update(overrides)
    return PLCDevice(**values)


def _profile() -> NetworkProfile:
    return NetworkProfile(
        id=str(uuid4()),
        name="Commissioning Lab",
        interface_ip_address="192.168.1.253",
        subnet_mask="255.255.255.0",
        gateway_address="192.168.1.1",
    )


def _request(device: PLCDevice, **overrides) -> AddressChangeRequest:
    values = dict(
        id=str(uuid4()),
        device_id=device.id,
        device_name=device.name,
        current_ip_address=device.ip_address,
        new_ip_address="192.168.1.40",
        subnet_mask="255.255.255.0",
        gateway_address="192.168.1.1",
        profile_name="Commissioning Lab",
        make_static=True,
        technician_acknowledged=True,
    )
    values.update(overrides)
    return AddressChangeRequest(**values)


class CommissionTests(unittest.TestCase):
    def setUp(self):
        self.configured = _device()
        self.unconfigured = _device(
            id="ea7800b0-27de-460b-9d2e-a73178151804",
            name="Conveyor Station PLC",
            serial_number="6ES7-155-6AU01",
            mac_address="3C:7C:3F:14:09:B4",
            ip_address=None,
            subnet_mask=None,
            gateway_address=None,
            discovery_protocols=["Profinet", "BOOTP", "ARP"],
            addressing_state="Unconfigured",
        )
        self.plant = FakePlant([self.configured, self.unconfigured])
        self.engine = CommissioningEngine(self.plant)
        self.engine.discover(_profile())

    def test_cip_write_updates_configured_device(self):
        event = self.engine.apply_address_change(_request(self.configured))
        self.assertTrue(event.successful)
        self.assertEqual(event.kind, "Static mode enabled")
        self.assertEqual(self.plant.cip_writes, [("192.168.1.10", "192.168.1.40")])
        self.assertEqual(self.engine.devices[0].ip_address, "192.168.1.40")

    def test_bootp_assigns_unconfigured_device(self):
        event = self.engine.apply_address_change(_request(self.unconfigured, new_ip_address="192.168.1.55"))
        self.assertTrue(event.successful)
        assigned = next(device for device in self.engine.devices if device.serial_number == "6ES7-155-6AU01")
        self.assertEqual(assigned.ip_address, "192.168.1.55")
        self.assertEqual(self.plant.cip_writes, [])

    def test_duplicate_address_is_conflict(self):
        with self.assertRaises(GatewayError) as raised:
            self.engine.apply_address_change(_request(self.unconfigured, new_ip_address="192.168.1.10"))
        self.assertEqual(raised.exception.status, 409)

    def test_missing_acknowledgement_is_rejected(self):
        with self.assertRaises(GatewayError) as raised:
            self.engine.apply_address_change(_request(self.configured, technician_acknowledged=False))
        self.assertEqual(raised.exception.status, 422)

    def test_invalid_address_is_rejected(self):
        with self.assertRaises(GatewayError) as raised:
            self.engine.apply_address_change(_request(self.configured, new_ip_address="192.168.1"))
        self.assertEqual(raised.exception.status, 422)


if __name__ == "__main__":
    unittest.main()
