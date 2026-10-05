from __future__ import annotations

import json
import ssl
import tempfile
import threading
import unittest
from http.client import HTTPSConnection
from pathlib import Path

from fieldlink_gateway.api import GatewayRuntime, serve
from fieldlink_gateway.audit import AuditLog
from fieldlink_gateway.commission import CommissioningEngine
from fieldlink_gateway.identity import load_or_create
from fieldlink_gateway.pairing import PairingState
from fieldlink_gateway.plant import FakePlant
from fieldlink_gateway.models import PLCDevice, utcnow


class _TLSConnection(HTTPSConnection):
    def __init__(self, host: str, port: int):
        context = ssl._create_unverified_context()
        super().__init__(host, port=port, context=context)


class APIContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        data_dir = Path(self.temp.name)
        identity = load_or_create(data_dir, hostname="localhost")
        plant = FakePlant(
            [
                PLCDevice(
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
            ]
        )
        self.identity = identity
        self.runtime = GatewayRuntime(
            identity=identity,
            pairing=PairingState(identity.pairing_code),
            audit=AuditLog(data_dir / "audit.json"),
            engine=CommissioningEngine(plant),
            public_url="https://127.0.0.1:8443/",
        )
        self.httpd = serve(self.runtime, "127.0.0.1", 0)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.temp.cleanup()

    def _request(self, method: str, path: str, body: dict | None = None, token: str | None = None) -> tuple[int, dict | list]:
        connection = _TLSConnection("127.0.0.1", self.port)
        headers = {"Accept": "application/json", "Content-Type": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        payload = json.dumps(body).encode("utf-8") if body is not None else None
        connection.request(method, path, body=payload, headers=headers)
        response = connection.getresponse()
        raw = response.read()
        connection.close()
        return response.status, json.loads(raw.decode("utf-8")) if raw else {}

    def test_pairing_discovery_and_address_change(self):
        status, _ = self._request("GET", "/v1/status")
        self.assertEqual(status, 401)

        status, payload = self._request("POST", "/v1/pair", {"pairingCode": "nope"})
        self.assertEqual(status, 401)

        status, payload = self._request("POST", "/v1/pair", {"pairingCode": self.identity.pairing_code})
        self.assertEqual(status, 200)
        self.assertEqual(payload["certificatePinBase64"], self.identity.certificate_pin_base64)
        self.assertEqual(payload["gateway"]["simulatorMode"], False)
        token = payload["sessionToken"]

        status, payload = self._request("GET", "/v1/status", token=token)
        self.assertEqual(status, 200)
        self.assertEqual(payload["state"], "ready")

        status, devices = self._request(
            "POST",
            "/v1/discovery",
            {
                "id": "7B50D809-6408-4C9B-9F74-06D495C98B31",
                "name": "Commissioning Lab",
                "interfaceIPAddress": "192.168.1.253",
                "subnetMask": "255.255.255.0",
                "gatewayAddress": "192.168.1.1",
                "notes": "",
            },
            token=token,
        )
        self.assertEqual(status, 200)
        self.assertEqual(devices[0]["name"], "Filler Cell Controller")
        self.assertIn("lastSeen", devices[0])

        status, event = self._request(
            "POST",
            "/v1/address-changes",
            {
                "id": "11111111-1111-1111-1111-111111111111",
                "deviceID": devices[0]["id"],
                "deviceName": devices[0]["name"],
                "currentIPAddress": "192.168.1.10",
                "newIPAddress": "192.168.1.40",
                "subnetMask": "255.255.255.0",
                "gatewayAddress": "192.168.1.1",
                "profileName": "Commissioning Lab",
                "makeStatic": True,
                "technicianAcknowledged": True,
            },
            token=token,
        )
        self.assertEqual(status, 200)
        self.assertTrue(event["successful"])
        self.assertEqual(event["kind"], "Static mode enabled")

        status, audit = self._request("GET", "/v1/audit", token=token)
        self.assertEqual(status, 200)
        self.assertGreaterEqual(len(audit), 3)


if __name__ == "__main__":
    unittest.main()
