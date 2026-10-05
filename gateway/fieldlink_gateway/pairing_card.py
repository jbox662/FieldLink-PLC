from __future__ import annotations

import json
from pathlib import Path


def write_pairing_files(data_dir: Path, url: str, identity) -> Path:
    card_path = data_dir / "pairing-card.txt"
    card_path.write_text(identity.pairing_card(url) + "\n")
    (data_dir / "pairing.json").write_text(
        json.dumps(
            {
                "url": url,
                "pairingCode": identity.pairing_code,
                "certificatePinBase64": identity.certificate_pin_base64,
                "serialNumber": identity.serial_number,
            },
            indent=2,
        )
        + "\n"
    )
    return card_path
