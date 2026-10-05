from __future__ import annotations

import unittest

from fieldlink_gateway.interfaces import parse_arp_dash_a, parse_ipconfig, resolve_plant


IPCONFIG = """
Windows IP Configuration

Ethernet adapter Ethernet:

   Connection-specific DNS Suffix  . : lan
   IPv4 Address. . . . . . . . . . . : 192.168.1.50
   Subnet Mask . . . . . . . . . . . : 255.255.255.0
   Default Gateway . . . . . . . . . : 192.168.1.1

Wireless LAN adapter Wi-Fi:

   Connection-specific DNS Suffix  . :
   IPv4 Address. . . . . . . . . . . : 10.0.0.12
   Subnet Mask . . . . . . . . . . . : 255.255.255.0
   Default Gateway . . . . . . . . . : 10.0.0.1
"""

ARP = """
Interface: 192.168.1.50 --- 0x5
  Internet Address      Physical Address      Type
  192.168.1.10          00-1d-9c-73-20-11     dynamic
  192.168.1.1           3c-7c-3f-14-09-b4     dynamic
  224.0.0.22            01-00-5e-00-00-16     static
"""


class InterfaceParserTests(unittest.TestCase):
    def test_parses_windows_ipconfig(self):
        adapters = parse_ipconfig(IPCONFIG)
        self.assertEqual(len(adapters), 2)
        self.assertEqual(adapters[0].name, "Ethernet")
        self.assertEqual(adapters[0].address, "192.168.1.50")
        self.assertEqual(adapters[0].subnet_mask, "255.255.255.0")
        self.assertEqual(adapters[1].name, "Wi-Fi")
        self.assertEqual(adapters[1].address, "10.0.0.12")

    def test_parses_windows_arp(self):
        table = parse_arp_dash_a(ARP)
        self.assertEqual(table["192.168.1.10"], "00:1D:9C:73:20:11")
        self.assertNotIn("224.0.0.22", table)

    def test_resolve_plant_from_ip(self):
        name, address = resolve_plant(None, "192.168.1.50")
        self.assertEqual(address, "192.168.1.50")
        self.assertTrue(name)


if __name__ == "__main__":
    unittest.main()
