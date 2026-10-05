from __future__ import annotations

import unittest

from fieldlink_gateway.bootp import build_reply, format_mac, parse_request


def _request(mac: bytes = bytes.fromhex("001d9c732011"), xid: bytes = b"\x11\x22\x33\x44") -> bytes:
    packet = bytearray(300)
    packet[0] = 1
    packet[1] = 1
    packet[2] = 6
    packet[4:8] = xid
    packet[28:34] = mac
    return bytes(packet)


class BootpTests(unittest.TestCase):
    def test_parse_and_reply_binds_requested_mac(self):
        request = parse_request(_request())
        self.assertIsNotNone(request)
        self.assertEqual(request.mac_address, "00:1D:9C:73:20:11")
        reply = build_reply(
            request,
            yiaddr="192.168.1.40",
            siaddr="192.168.1.253",
            subnet_mask="255.255.255.0",
            router="192.168.1.1",
        )
        self.assertEqual(reply[0], 2)
        self.assertEqual(reply[16:20], bytes((192, 168, 1, 40)))
        self.assertEqual(reply[28:34], bytes.fromhex("001d9c732011"))
        self.assertEqual(format_mac(reply[28:34]), "00:1D:9C:73:20:11")
        self.assertEqual(reply[236:240], bytes((99, 130, 83, 99)))


if __name__ == "__main__":
    unittest.main()
