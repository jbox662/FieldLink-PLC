import Foundation

struct NetworkProfile: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var interfaceIPAddress: String
    var subnetMask: String
    var gatewayAddress: String
    var notes: String

    var summary: String { "\(interfaceIPAddress) / \(subnetMask)" }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && IPv4Validator.isValid(interfaceIPAddress)
            && IPv4Validator.isValid(subnetMask)
            && IPv4Validator.isValid(gatewayAddress)
    }

    init(
        id: UUID = UUID(),
        name: String,
        interfaceIPAddress: String,
        subnetMask: String,
        gatewayAddress: String,
        notes: String
    ) {
        self.id = id
        self.name = name
        self.interfaceIPAddress = interfaceIPAddress
        self.subnetMask = subnetMask
        self.gatewayAddress = gatewayAddress
        self.notes = notes
    }

    static let commissioningLab = NetworkProfile(
        id: UUID(uuidString: "7B50D809-6408-4C9B-9F74-06D495C98B31")!,
        name: "Commissioning Lab",
        interfaceIPAddress: "192.168.1.253",
        subnetMask: "255.255.255.0",
        gatewayAddress: "192.168.1.1",
        notes: "Isolated EtherNet/IP commissioning segment."
    )

    static let lineTwo = NetworkProfile(
        id: UUID(uuidString: "B5A6D7D6-E9C0-4EFA-9C75-2C2C62780AA1")!,
        name: "Line 2 — Packaging",
        interfaceIPAddress: "10.42.8.253",
        subnetMask: "255.255.255.0",
        gatewayAddress: "10.42.8.1",
        notes: "Use only during planned Line 2 maintenance windows."
    )
}
