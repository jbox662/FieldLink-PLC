import Foundation

enum DiscoveryProtocol: String, Codable, CaseIterable, Hashable, Identifiable {
    case ethernetIP = "EtherNet/IP"
    case arp = "ARP"
    case profinet = "Profinet"
    case dhcp = "DHCP"
    case bootp = "BOOTP"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .ethernetIP: "bolt.horizontal.circle"
        case .arp: "dot.radiowaves.left.and.right"
        case .profinet: "network"
        case .dhcp, .bootp: "arrow.triangle.2.circlepath"
        }
    }
}

enum AddressingState: String, Codable, CaseIterable, Hashable {
    case staticAddress = "Static"
    case dhcp = "DHCP"
    case bootp = "BOOTP"
    case unconfigured = "Unconfigured"

    var isWritable: Bool { self != .unconfigured }
}

enum LinkStatus: String, Codable, Hashable {
    case active = "Linked"
    case inactive = "No link"
    case unknown = "Unknown"
}

struct PLCDevice: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var vendor: String
    var product: String
    var revision: String
    var serialNumber: String
    var macAddress: String
    var ipAddress: String?
    var subnetMask: String?
    var gatewayAddress: String?
    var discoveryProtocols: [DiscoveryProtocol]
    var addressingState: AddressingState
    var linkStatus: LinkStatus
    var lastSeen: Date

    var displayedIPAddress: String { ipAddress ?? "Unassigned" }
    var primaryProtocol: DiscoveryProtocol { discoveryProtocols.first ?? .arp }
    var isAddressable: Bool { discoveryProtocols.contains(.ethernetIP) || discoveryProtocols.contains(.profinet) || discoveryProtocols.contains(.dhcp) || discoveryProtocols.contains(.bootp) }
    var needsAddressAssignment: Bool {
        ipAddress == nil || addressingState == .unconfigured || addressingState == .bootp
    }
}

struct AddressChangeRequest: Identifiable, Codable, Hashable {
    let id: UUID
    let deviceID: UUID
    let deviceName: String
    let currentIPAddress: String?
    let newIPAddress: String
    let subnetMask: String
    let gatewayAddress: String
    let profileName: String
    let makeStatic: Bool
    let technicianAcknowledged: Bool

    init(
        device: PLCDevice,
        newIPAddress: String,
        subnetMask: String,
        gatewayAddress: String,
        profileName: String,
        makeStatic: Bool,
        technicianAcknowledged: Bool
    ) {
        self.id = UUID()
        self.deviceID = device.id
        self.deviceName = device.name
        self.currentIPAddress = device.ipAddress
        self.newIPAddress = newIPAddress
        self.subnetMask = subnetMask
        self.gatewayAddress = gatewayAddress
        self.profileName = profileName
        self.makeStatic = makeStatic
        self.technicianAcknowledged = technicianAcknowledged
    }
}

enum IPv4Validator {
    static func isValid(_ address: String) -> Bool {
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }

        return octets.allSatisfy { octet in
            guard let value = Int(octet), value >= 0, value <= 255 else { return false }
            return !(octet.count > 1 && octet.first == "0")
        }
    }
}
