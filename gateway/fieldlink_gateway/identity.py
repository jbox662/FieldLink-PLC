from __future__ import annotations

import ipaddress
import json
import os
import secrets
import shutil
import subprocess
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import __version__


@dataclass(frozen=True)
class GatewayIdentity:
    serial_number: str
    identifier: str
    firmware_version: str
    pairing_code: str
    certificate_path: Path
    key_path: Path
    der_path: Path
    certificate_pin_base64: str

    def pairing_card(self, url: str) -> str:
        return "\n".join(
            [
                "FieldLink Gateway pairing card",
                "--------------------------------",
                f"URL:    {url}",
                f"Code:   {self.pairing_code}",
                f"Serial: {self.serial_number}",
                f"Pin:    {self.certificate_pin_base64}",
                "",
                "Enter these values in FieldLink PLC → Gateway → Pair a physical FieldLink Gateway.",
                "Pairing is only accepted while the gateway pairing window is open.",
            ]
        )


def load_or_create(data_dir: Path, hostname: str = "fieldlink-gateway.local") -> GatewayIdentity:
    data_dir.mkdir(parents=True, exist_ok=True)
    meta_path = data_dir / "identity.json"
    certificate_path = data_dir / "tls.crt"
    key_path = data_dir / "tls.key"
    der_path = data_dir / "tls.der"

    if not all(path.exists() for path in (meta_path, certificate_path, key_path, der_path)):
        _generate_tls(certificate_path, key_path, der_path, hostname)
        meta = {
            "serialNumber": f"FL-{secrets.token_hex(4).upper()}",
            "identifier": "FieldLink Gateway",
            "firmwareVersion": __version__,
            "pairingCode": f"{secrets.randbelow(100_000_000):08d}",
        }
        meta_path.write_text(json.dumps(meta, indent=2) + "\n")

    meta = json.loads(meta_path.read_text())
    pin = _der_base64(der_path)
    return GatewayIdentity(
        serial_number=meta["serialNumber"],
        identifier=meta.get("identifier", "FieldLink Gateway"),
        firmware_version=meta.get("firmwareVersion", __version__),
        pairing_code=str(meta["pairingCode"]),
        certificate_path=certificate_path,
        key_path=key_path,
        der_path=der_path,
        certificate_pin_base64=pin,
    )


def rotate_pairing_code(data_dir: Path, identity: GatewayIdentity) -> GatewayIdentity:
    meta_path = data_dir / "identity.json"
    meta = json.loads(meta_path.read_text())
    meta["pairingCode"] = f"{secrets.randbelow(100_000_000):08d}"
    meta_path.write_text(json.dumps(meta, indent=2) + "\n")
    return load_or_create(data_dir)


def _generate_tls(certificate_path: Path, key_path: Path, der_path: Path, hostname: str) -> None:
    if shutil.which("openssl"):
        _generate_tls_openssl(certificate_path, key_path, der_path, hostname)
        return
    try:
        _generate_tls_cryptography(certificate_path, key_path, der_path, hostname)
        return
    except ImportError:
        pass
    raise RuntimeError(
        "Could not create a TLS certificate. On Windows install Python from python.org, then run: "
        "py -3 -m pip install cryptography"
    )


def _generate_tls_openssl(certificate_path: Path, key_path: Path, der_path: Path, hostname: str) -> None:
    env = os.environ.copy()
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-sha256",
            "-days",
            "3650",
            "-nodes",
            "-keyout",
            str(key_path),
            "-out",
            str(certificate_path),
            "-subj",
            f"/CN={hostname}",
            "-addext",
            f"subjectAltName=DNS:{hostname},DNS:localhost,IP:127.0.0.1",
        ],
        check=True,
        capture_output=True,
        env=env,
    )
    subprocess.run(
        [
            "openssl",
            "x509",
            "-in",
            str(certificate_path),
            "-outform",
            "DER",
            "-out",
            str(der_path),
        ],
        check=True,
        capture_output=True,
        env=env,
    )
    _restrict_key(key_path)


def _generate_tls_cryptography(certificate_path: Path, key_path: Path, der_path: Path, hostname: str) -> None:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, hostname)])
    alt_names = [x509.DNSName(hostname), x509.DNSName("localhost"), x509.IPAddress(ipaddress.IPv4Address("127.0.0.1"))]
    now = datetime.now(timezone.utc)
    certificate = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=1))
        .not_valid_after(now + timedelta(days=3650))
        .add_extension(x509.SubjectAlternativeName(alt_names), critical=False)
        .sign(key, hashes.SHA256())
    )
    key_path.write_bytes(
        key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )
    certificate_path.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
    der_path.write_bytes(certificate.public_bytes(serialization.Encoding.DER))
    _restrict_key(key_path)


def _restrict_key(key_path: Path) -> None:
    try:
        os.chmod(key_path, 0o600)
    except OSError:
        pass


def _der_base64(der_path: Path) -> str:
    import base64

    return base64.b64encode(der_path.read_bytes()).decode("ascii")
