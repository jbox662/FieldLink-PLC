# FieldLink Gateway Integration Contract

## Purpose

The **FieldLink Gateway** is the trusted network boundary between the iPhone/iPad app and an industrial Ethernet segment. It owns raw frame handling, passive discovery, BOOTP/DHCP, and protocol-specific commissioning behavior that cannot be responsibly implemented by a normal iOS app alone.

The SwiftUI application uses the `GatewayClient` protocol. The included `SimulatedGatewayClient` runs entirely inside the iOS Simulator. `HTTPGatewayClient` is the production integration point.

> The app is intentionally a controller and audit surface; it does not capture raw Ethernet frames, manage the iPad’s Ethernet interface, or silently modify PLC networking.

## Required gateway behavior

| Function | Gateway responsibility | App responsibility |
|---|---|---|
| Device discovery | Passively listen for ARP, EtherNet/IP ListIdentity, Profinet DCP, and approved discoverable traffic | Start/stop discovery, show protocol evidence and results |
| BOOTP/DHCP assignment | Bind the requested target identity/MAC to an operator-approved proposed address and respond on the industrial segment | Collect and review parameters; enforce technician confirmation |
| Ethernet/IP configuration | Carry out only model-validated CIP configuration actions | Display controller identity and supported operations |
| Network profile | Configure its commissioning NIC with stored profile settings | Select profile and show its values |
| Audit | Persist append-only device/action/result records locally | Display/export records |
| Security | Verify pairing, require authenticated API calls, sign firmware, and expire session credentials | Store session credentials in Keychain, clearly identify paired gateway |

## Local API v1

The gateway should expose the API only on the paired local control channel (wired USB accessory, mutually authenticated Wi-Fi, or BLE-assisted Wi-Fi setup). A gateway must not expose the industrial control port directly to the public internet.

All responses use JSON. Date values use ISO 8601 timestamps; the app accepts standard and fractional-second ISO 8601 variants. Each mutation must include a gateway-side audit record.

### `GET /v1/status`

```json
{
  "state": "ready",
  "message": null
}
```

Valid states: `ready`, `busy`, `fault`.

### `GET /v1/gateway`

```json
{
  "identifier": "FieldLink Gateway",
  "firmwareVersion": "1.0.0",
  "serialNumber": "FL-0001",
  "linkSpeed": "100 Mbps full duplex",
  "simulatorMode": false
}
```

### `POST /v1/pair`

This endpoint may be used only during a short pairing window created by a physical gateway action (button press, USB session confirmation, or QR-mediated setup).

```json
{ "pairingCode": "one-time-code" }
```

```json
{
  "gateway": {
    "identifier": "FieldLink Gateway",
    "firmwareVersion": "1.0.0",
    "serialNumber": "FL-0001",
    "linkSpeed": "100 Mbps full duplex",
    "simulatorMode": false
  },
  "sessionToken": "short-lived-session-token",
  "certificatePinBase64": "base64-encoded-leaf-certificate-DER"
}
```

The response certificate pin must exactly match the pairing QR/card pin entered or scanned in the app. The app retains only the short-lived `sessionToken` in Keychain; it does not retain the one-time pairing code.

### `POST /v1/discovery`

Request body is the selected `NetworkProfile`.

The gateway must:

1. authenticate the caller;
2. configure/use the approved network profile;
3. perform time-bounded, read-only discovery; and
4. return device identities including MAC address and source protocol evidence.

The device result shape follows `PLCDevice` in `FieldLinkPLC/Models/PLCDevice.swift`.

### `POST /v1/address-changes`

Request body follows `AddressChangeRequest`.

Gateway safeguards, in addition to app safeguards:

1. reject an unpaired/unauthenticated caller;
2. require `technicianAcknowledged: true`;
3. re-check the device identity/MAC immediately before the write;
4. perform an address conflict check appropriate to the target protocol;
5. use the gateway’s stored profile only if it matches the request profile; and
6. record request, source identity, old/new address, protocol action, response, and result in the audit log.

The gateway should return HTTP `409` for detected conflicts and HTTP `422` for unsupported/protocol-invalid changes. Never report success until the gateway has an explicit target acknowledgement or a documented non-acknowledgement outcome.

### `GET /v1/audit`

Returns newest-first `CommissioningEvent` records. Production firmware should support a signed/exportable audit report with operator, gateway serial, profile, device identity, before/after values, timestamps, and outcomes.

## Pairing and credential requirements

- Pairing must require a deliberate physical/user action: QR code, button press, or USB session confirmation.
- Derive a distinct per-gateway credential; do not use a factory-default shared password.
- Store app credentials in the iOS Keychain, never in `UserDefaults` or source code.
- Require TLS when the control link uses IP. The current app pins the gateway leaf certificate DER supplied as Base64 by the pairing QR/card and response; the firmware must keep that pairing material synchronized.
- Expire short-lived access tokens and require re-pairing after a factory reset.
- Disable BOOTP/DHCP responder functionality unless an authenticated app begins an explicitly approved assignment window.
- Use signed firmware and a secure update rollback policy.

## Protocol support boundary

The initial pilot should validate **one PLC family at a time**. Device protocol actions must be declared by the gateway based on observed identity and tested firmware compatibility; no screen should claim universal Allen-Bradley, Siemens, or Profinet configuration support.

## Simulator mode

Simulator Mode is the default session mode. It lets Xcode Simulator users test:

- gateway connection state;
- passive-discovery result presentation;
- controller identity details;
- profile selection;
- address-change review gates;
- duplicate-address rejection; and
- audit log behavior.

Simulator mode performs no real network activity. On a physical device, **Gateway → Manage gateway session** pairs a physical gateway, stores its short-lived token in Keychain, creates the pinned `HTTPGatewayClient`, and injects it into `CommissioningViewModel`.
