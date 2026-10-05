import Foundation

enum GatewayStatus: Equatable {
    case offline
    case connecting
    case ready
    case fault(String)

    var title: String {
        switch self {
        case .offline: "Gateway offline"
        case .connecting: "Connecting"
        case .ready: "Gateway ready"
        case .fault: "Gateway needs attention"
        }
    }

    var detail: String {
        switch self {
        case .offline: "USB-C Ethernet needs a link and an IPv4 address in Settings → Ethernet."
        case .connecting: "Looking for USB-C Ethernet with an IPv4 address."
        case .ready: "Discovery is using the USB-C Ethernet adapter only. Wi-Fi is ignored."
        case let .fault(message): message
        }
    }
}

struct GatewayInfo: Codable, Hashable {
    let identifier: String
    let firmwareVersion: String
    let serialNumber: String
    let linkSpeed: String
    let simulatorMode: Bool
}

enum GatewayCapability: String, CaseIterable, Identifiable {
    case passiveDiscovery = "Passive ARP / EtherNet/IP / Profinet discovery"
    case bootpDhcp = "Technician-approved BOOTP / DHCP service"
    case explicitMessaging = "EtherNet/IP identity and configuration operations"
    case auditLog = "Local commissioning audit log"

    var id: String { rawValue }
}

enum GatewayClientError: LocalizedError {
    case notConnected
    case invalidAddress(String)
    case duplicateAddress(String)
    case conflict(String)
    case deviceNotFound
    case acknowledgementRequired
    case unsupportedOperation(String = "This gateway firmware does not support that action.")
    case authenticationFailed(String)
    case gatewayFault(String)
    case invalidGatewayURL
    case pairingRequired
    case invalidCertificatePin
    case keychainUnavailable
    case invalidResponse
    case noLocalNetwork
    case ethernetHasNoAddress(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Connect a FieldLink Gateway before running this operation."
        case let .invalidAddress(address): "\(address) is not a valid IPv4 address."
        case let .duplicateAddress(address): "\(address) is already in use by a discovered device."
        case let .conflict(message), let .authenticationFailed(message), let .gatewayFault(message): message
        case .deviceNotFound: "The selected device is no longer available from the gateway."
        case .acknowledgementRequired: "The safety acknowledgement is required before changing a device address."
        case let .unsupportedOperation(message): message
        case .invalidGatewayURL: "Enter a valid HTTPS gateway URL supplied by the physical pairing card or QR code."
        case .pairingRequired: "Enter the one-time pairing code supplied by the physical gateway."
        case .invalidCertificatePin: "The gateway certificate pin is invalid or does not match the pairing response."
        case .keychainUnavailable: "The secure gateway credential could not be stored or retrieved from Keychain."
        case .invalidResponse: "The gateway returned an unreadable response."
        case .noLocalNetwork: "This iPhone does not see a USB-C Ethernet adapter. Plug the adapter into the phone (not the Windows PC), then open Settings → Ethernet. If Ethernet is missing, the dongle is not talking Ethernet to iOS."
        case let .ethernetHasNoAddress(name): "USB-C Ethernet (\(name)) is plugged in but has no IPv4 address. Open Settings → Ethernet, set Configure IP to Manual, and give it an address on the PLC subnet — for example 192.168.1.50 / 255.255.255.0. Automatic will sit at none if the bench has no DHCP."
        }
    }
}

protocol GatewayClient {
    func connect() async throws -> GatewayStatus
    func gatewayInfo() async throws -> GatewayInfo
    func startDiscovery(profile: NetworkProfile) async throws -> [PLCDevice]
    func applyAddressChange(_ request: AddressChangeRequest) async throws -> CommissioningEvent
    func fetchAuditTrail() async throws -> [CommissioningEvent]
    func lastDiscoveryDebug() async -> DiscoveryDebugReport?
}

struct DiscoveryDebugPacket: Identifiable, Hashable, Sendable {
    let id: UUID
    let source: String
    let byteCount: Int
    let hexPrefix: String
    let parsedName: String?

    init(source: String, byteCount: Int, hexPrefix: String, parsedName: String?) {
        self.id = UUID()
        self.source = source
        self.byteCount = byteCount
        self.hexPrefix = hexPrefix
        self.parsedName = parsedName
    }
}

struct DiscoveryDebugReport: Hashable, Sendable {
    var capturedAt: Date
    var interfaceName: String
    var interfaceAddress: String
    var netmask: String
    var linkDescription: String
    var unicastsSent: Int
    var broadcastsSent: Int
    var sendFailures: Int
    var datagramsReceived: Int
    var lastSendError: String?
    var packets: [DiscoveryDebugPacket]
    var deviceNames: [String]

    var shareText: String {
        var lines = [
            "FieldLink PLC discovery debug",
            capturedAt.formatted(date: .abbreviated, time: .standard),
            "Interface: \(interfaceName) \(interfaceAddress) \(netmask)\(linkDescription)",
            "Unicast sent: \(unicastsSent)",
            "Broadcast sent: \(broadcastsSent)",
            "Send failures: \(sendFailures)",
            "Datagrams received: \(datagramsReceived)",
            "Devices: \(deviceNames.isEmpty ? "none" : deviceNames.joined(separator: ", "))"
        ]
        if let lastSendError {
            lines.append("Last send error: \(lastSendError)")
        }
        if packets.isEmpty {
            lines.append("No UDP replies were received on port 44818.")
        } else {
            lines.append("Received packets:")
            for packet in packets {
                let parsed = packet.parsedName ?? "not a ListIdentity body"
                lines.append("  \(packet.source)  \(packet.byteCount)B  \(parsed)  \(packet.hexPrefix)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
