# FieldLink PLC

An **iPhone/iPad field commissioning app** designed to work with a compact FieldLink Ethernet Gateway. The gateway—not iOS—handles physical Ethernet discovery, BOOTP/DHCP, and other layer-2/protocol tasks. The SwiftUI app provides the technician workflow, review safeguards, device history, and audit visibility.

## Included now

- A real SwiftUI/Xcode iOS app target for iPhone and iPad (iOS 17+).
- **Simulator Mode** using `SimulatedGatewayClient`, with three realistic PLC/remote-I/O discovery records.
- Device identity, protocol evidence, active network profiles, and activity/audit views.
- Two-stage address-change confirmation (technician acknowledgement + final before/after review).
- Duplicate-IP and malformed IPv4 validation in the simulator gateway.
- XCTest coverage for discovery, address mutation, conflict rejection, and IPv4 validation.
- A gateway-session manager with physical pairing, Keychain-backed short-lived credentials, and leaf-certificate pinning.
- A production-oriented `HTTPGatewayClient` and documented gateway API/security contract.

## Run in Xcode Simulator

1. On a Mac with **Xcode 15+**, copy or clone this project.
2. Open `FieldLinkPLC.xcodeproj`.
3. Select the **FieldLink PLC** scheme.
4. Select an iPhone or iPad simulator running iOS 17 or later.
5. Press **Run**.

The app launches in Simulator Mode and automatically connects to **FieldLink Simulator**. Tap **Discover devices**, open a device, and use **Change IP address** to exercise the guarded commissioning flow. The simulator does not change any real network setting.

To execute tests: choose **Product → Test** or press `⌘U`.

## Project layout

```text
FieldLinkPLC/                  SwiftUI iOS source
  Models/                      PLC, profile, request, and audit data models
  Services/                    Gateway protocol, simulator, and hardware HTTP adapter
  ViewModels/                  App state / gateway orchestration
  Views/                       Technician-facing iPhone/iPad UI
  Resources/                   Info.plist and app resources
FieldLinkPLCTests/             XCTest simulator-contract tests
Docs/GATEWAY-CONTRACT.md       Firmware/API/security requirements for the physical gateway
```

## Hardware integration path

The `GatewayClient` protocol keeps the UI independent from the transport. In the app, open **Gateway → Manage gateway session** and pair only while physically connected to or standing at the FieldLink Gateway. The pairing QR/card provides an HTTPS URL, one-time code, and leaf-certificate pin. `GatewaySessionStore` verifies the pair response pin, stores only the resulting short-lived session credential in Keychain, then creates an authenticated, certificate-pinned `HTTPGatewayClient`.

Read [the gateway contract](Docs/GATEWAY-CONTRACT.md) before building firmware or exposing a gateway endpoint.

## Important commissioning boundary

This project intentionally does **not** claim that a normal iOS app can directly capture ARP/Profinet traffic or serve BOOTP/DHCP from the iPad/iPhone Ethernet adapter. Those functions belong to the FieldLink Gateway. Always validate protocol write operations on isolated non-production equipment before field use.

## Current sandbox validation limitation

This task runs in a Linux sandbox with no Xcode or iOS Simulator installed. The project has been structured as an Xcode project and includes XCTest sources, but it still needs its first compile/run on a Mac with Xcode. The included simulator gateway makes that validation independent of physical PLC hardware.
