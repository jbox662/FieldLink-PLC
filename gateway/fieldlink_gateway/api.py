from __future__ import annotations

import json
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlparse

from .audit import AuditLog
from .commission import CommissioningEngine
from .identity import GatewayIdentity
from .models import AddressChangeRequest, CommissioningEvent, GatewayError, GatewayInfo, NetworkProfile
from .pairing import PairingState


class GatewayRuntime:
    def __init__(
        self,
        identity: GatewayIdentity,
        pairing: PairingState,
        audit: AuditLog,
        engine: CommissioningEngine,
        public_url: str,
    ):
        self.identity = identity
        self.pairing = pairing
        self.audit = audit
        self.engine = engine
        self.public_url = public_url
        self.state = "ready"
        self.message: str | None = None

    def info(self) -> GatewayInfo:
        return GatewayInfo(
            identifier=self.identity.identifier,
            firmware_version=self.identity.firmware_version,
            serial_number=self.identity.serial_number,
            link_speed=self.engine.plant.link_speed(),
            simulator_mode=False,
        )


def make_handler(runtime: GatewayRuntime):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format: str, *args: object) -> None:
            sys_stderr_write = super().log_message
            sys_stderr_write(format, *args)

        def do_GET(self) -> None:
            self._dispatch()

        def do_POST(self) -> None:
            self._dispatch()

        def _dispatch(self) -> None:
            path = urlparse(self.path).path.rstrip("/") or "/"
            try:
                if path == "/v1/status" and self.command == "GET":
                    self._require_auth()
                    self._json(200, {"state": runtime.state, "message": runtime.message})
                    return
                if path == "/v1/gateway" and self.command == "GET":
                    self._require_auth()
                    self._json(200, runtime.info().to_json())
                    return
                if path == "/v1/audit" and self.command == "GET":
                    self._require_auth()
                    self._json(200, [event.to_json() for event in runtime.audit.newest_first()])
                    return
                if path == "/v1/pair" and self.command == "POST":
                    self._pair()
                    return
                if path == "/v1/discovery" and self.command == "POST":
                    self._require_auth()
                    self._discover()
                    return
                if path == "/v1/address-changes" and self.command == "POST":
                    self._require_auth()
                    self._address_change()
                    return
                self._json(404, {"code": "not_found", "message": "Unknown gateway endpoint."})
            except PermissionError as error:
                self._json(401, {"code": "authentication_failed", "message": str(error)})
            except GatewayError as error:
                event = getattr(error, "audit_event", None)
                if event:
                    runtime.audit.record(event)
                self._json(error.status, error.to_json())
            except Exception as error:
                runtime.audit.record(
                    CommissioningEvent(
                        kind="Validation completed",
                        detail=f"Gateway fault: {error}",
                        successful=False,
                    )
                )
                self._json(500, {"code": "gateway_fault", "message": str(error)})

        def _pair(self) -> None:
            payload = self._read_json()
            token = runtime.pairing.pair(str(payload.get("pairingCode") or ""), runtime.identity.certificate_pin_base64)
            runtime.audit.record(
                CommissioningEvent(
                    kind="Gateway connected",
                    detail=f"Paired FieldLink Gateway {runtime.identity.serial_number} over the local control HTTPS API.",
                )
            )
            self._json(
                200,
                {
                    "gateway": runtime.info().to_json(),
                    "sessionToken": token,
                    "certificatePinBase64": runtime.identity.certificate_pin_base64,
                },
            )

        def _discover(self) -> None:
            profile = NetworkProfile.from_json(self._read_json())
            devices = runtime.engine.discover(profile)
            runtime.audit.record(
                CommissioningEvent(
                    kind="Discovery completed",
                    detail=f"Found {len(devices)} devices using {profile.name}. EtherNet/IP ListIdentity on the plant Ethernet port only.",
                )
            )
            self._json(200, [device.to_json() for device in devices])

        def _address_change(self) -> None:
            request = AddressChangeRequest.from_json(self._read_json())
            event = runtime.engine.apply_address_change(request)
            runtime.audit.record(event)
            self._json(200, event.to_json())

        def _require_auth(self) -> None:
            runtime.pairing.authenticate(self.headers.get("Authorization"))

        def _read_json(self) -> dict[str, Any]:
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b"{}"
            if not raw:
                return {}
            try:
                payload = json.loads(raw.decode("utf-8"))
            except json.JSONDecodeError as error:
                raise GatewayError(400, "invalid_json", "The gateway could not read the JSON body.") from error
            if not isinstance(payload, dict):
                raise GatewayError(400, "invalid_json", "Expected a JSON object.")
            return payload

        def _json(self, status: int, payload: Any) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

    return Handler


def serve(runtime: GatewayRuntime, host: str, port: int) -> ThreadingHTTPServer:
    httpd = ThreadingHTTPServer((host, port), make_handler(runtime))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(runtime.identity.certificate_path, runtime.identity.key_path)
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    return httpd
