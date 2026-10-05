from __future__ import annotations

import unittest

from fieldlink_gateway.list_identity import parse, request_packet


class ListIdentityTests(unittest.TestCase):
    def test_request_is_24_byte_list_identity(self):
        packet = request_packet()
        self.assertEqual(len(packet), 24)
        self.assertEqual(packet[0], 0x63)
        self.assertEqual(packet[1], 0x00)

    def test_parses_rockwell_identity_fixture(self):
        response = bytearray(24)
        response[0] = 0x63
        response[1] = 0x00

        item = bytearray()
        item.extend([0x01, 0x00])
        item.extend([0x00, 0x02, 0x00, 0x00, 192, 168, 1, 10, 0, 0, 0, 0, 0, 0, 0, 0])
        item.extend([0x01, 0x00])
        item.extend([0x0E, 0x00])
        item.extend([0x4D, 0x00])
        item.extend([34, 11])
        item.extend([0x00, 0x00])
        item.extend([0xB2, 0xA0, 0x61, 0xCF])
        name = b"CompactLogix"
        item.append(len(name))
        item.extend(name)
        item.append(0x00)

        payload = bytearray()
        payload.extend([0x01, 0x00])
        payload.extend([0x0C, 0x00])
        payload.extend([len(item) & 0xFF, len(item) >> 8])
        payload.extend(item)

        response[2] = len(payload) & 0xFF
        response[3] = len(payload) >> 8
        response.extend(payload)

        device = parse(bytes(response), "192.168.1.10", "00:1D:9C:73:20:11")
        self.assertIsNotNone(device)
        self.assertEqual(device.vendor, "Rockwell Automation")
        self.assertEqual(device.name, "CompactLogix")
        self.assertEqual(device.ip_address, "192.168.1.10")
        self.assertEqual(device.serial_number, "CF61A0B2")
        self.assertEqual(device.discovery_protocols, ["EtherNet/IP"])
        self.assertEqual(device.mac_address, "00:1D:9C:73:20:11")


if __name__ == "__main__":
    unittest.main()
