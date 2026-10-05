import Foundation

/// Simulator-only gateway implementation. It allows the iOS Simulator to exercise
/// the same app workflow used by a physical FieldLink Ethernet Gateway.
actor SimulatedGatewayClient: GatewayClient {
    private var connected = false
    private var devices: [PLCDevice] = SampleGatewayData.devices
    private var auditTrail: [CommissioningEvent] = SampleGatewayData.events

    func connect() async throws -> GatewayStatus {
        try await Task.sleep(nanoseconds: 350_000_000)
        connected = true
        auditTrail.insert(
            CommissioningEvent(
                kind: .gatewayConnected,
                detail: "Simulator Gateway FL-SIM-001 established a local commissioning session."
            ),
            at: 0
        )
        return .ready
    }

    func gatewayInfo() async throws -> GatewayInfo {
        guard connected else { throw GatewayClientError.notConnected }
        return GatewayInfo(
            identifier: "FieldLink Simulator",
            firmwareVersion: "0.1.0-sim",
            serialNumber: "FL-SIM-001",
            linkSpeed: "100 Mbps full duplex",
            simulatorMode: true
        )
    }

    func startDiscovery(profile: NetworkProfile) async throws -> [PLCDevice] {
        guard connected else { throw GatewayClientError.notConnected }
        try await Task.sleep(nanoseconds: 900_000_000)

        devices = devices.map { device in
            var refreshed = device
            refreshed.lastSeen = Date()
            refreshed.linkStatus = .active
            return refreshed
        }
        auditTrail.insert(
            CommissioningEvent(
                kind: .discoveryCompleted,
                detail: "Found \(devices.count) devices using \(profile.name). No port scan was performed."
            ),
            at: 0
        )
        return devices
    }

    func applyAddressChange(_ request: AddressChangeRequest) async throws -> CommissioningEvent {
        guard connected else { throw GatewayClientError.notConnected }

        func reject(_ error: GatewayClientError, detail: String) throws -> Never {
            auditTrail.insert(
                CommissioningEvent(
                    kind: .addressAssigned,
                    deviceName: request.deviceName,
                    detail: detail,
                    successful: false
                ),
                at: 0
            )
            throw error
        }

        guard request.technicianAcknowledged else {
            try reject(.acknowledgementRequired, detail: "Rejected address change for \(request.deviceName): technician acknowledgement missing.")
        }
        guard IPv4Validator.isValid(request.newIPAddress) else {
            try reject(.invalidAddress(request.newIPAddress), detail: "Rejected \(request.newIPAddress) for \(request.deviceName): invalid IPv4 address.")
        }
        guard IPv4Validator.isValid(request.subnetMask) else {
            try reject(.invalidAddress(request.subnetMask), detail: "Rejected subnet mask \(request.subnetMask) for \(request.deviceName).")
        }
        guard IPv4Validator.isValid(request.gatewayAddress) else {
            try reject(.invalidAddress(request.gatewayAddress), detail: "Rejected gateway address \(request.gatewayAddress) for \(request.deviceName).")
        }
        guard let deviceIndex = devices.firstIndex(where: { $0.id == request.deviceID }) else {
            try reject(.deviceNotFound, detail: "Rejected address change: \(request.deviceName) is no longer in the discovery inventory.")
        }
        guard !devices.contains(where: { $0.id != request.deviceID && $0.ipAddress == request.newIPAddress }) else {
            try reject(.duplicateAddress(request.newIPAddress), detail: "Rejected \(request.newIPAddress) for \(request.deviceName): address is already in use.")
        }

        try await Task.sleep(nanoseconds: 700_000_000)

        var device = devices[deviceIndex]
        let oldAddress = device.ipAddress ?? "unassigned"
        device.ipAddress = request.newIPAddress
        device.subnetMask = request.subnetMask
        device.gatewayAddress = request.gatewayAddress
        device.addressingState = request.makeStatic ? .staticAddress : .dhcp
        device.lastSeen = Date()
        devices[deviceIndex] = device

        let event = CommissioningEvent(
            kind: request.makeStatic ? .staticEnabled : .addressAssigned,
            deviceName: device.name,
            detail: "Changed \(oldAddress) to \(request.newIPAddress) with profile \(request.profileName)."
        )
        auditTrail.insert(event, at: 0)
        return event
    }

    func fetchAuditTrail() async throws -> [CommissioningEvent] {
        guard connected else { throw GatewayClientError.notConnected }
        return auditTrail
    }

    func lastDiscoveryDebug() async -> DiscoveryDebugReport? {
        nil
    }
}

enum SampleGatewayData {
    static let devices: [PLCDevice] = [
        PLCDevice(
            id: UUID(uuidString: "E8C49641-31E4-4514-A4B4-6B35D785DBAA")!,
            name: "Filler Cell Controller",
            vendor: "Rockwell Automation",
            product: "CompactLogix 5380",
            revision: "34.011",
            serialNumber: "CF61A0B2",
            macAddress: "00:1D:9C:73:20:11",
            ipAddress: "192.168.1.10",
            subnetMask: "255.255.255.0",
            gatewayAddress: "192.168.1.1",
            discoveryProtocols: [.ethernetIP, .arp],
            addressingState: .staticAddress,
            linkStatus: .active,
            lastSeen: Date()
        ),
        PLCDevice(
            id: UUID(uuidString: "C9B94843-2045-427D-8A6E-9E9B1E1EB6EC")!,
            name: "Cartoner Remote I/O",
            vendor: "Rockwell Automation",
            product: "1734-AENTR POINT I/O",
            revision: "6.013",
            serialNumber: "E1F32017",
            macAddress: "00:00:BC:6F:21:90",
            ipAddress: "192.168.1.24",
            subnetMask: "255.255.255.0",
            gatewayAddress: "192.168.1.1",
            discoveryProtocols: [.ethernetIP, .dhcp, .arp],
            addressingState: .dhcp,
            linkStatus: .active,
            lastSeen: Date()
        ),
        PLCDevice(
            id: UUID(uuidString: "EA7800B0-27DE-460B-9D2E-A73178151804")!,
            name: "Conveyor Station PLC",
            vendor: "Siemens",
            product: "SIMATIC ET 200SP",
            revision: "4.5",
            serialNumber: "6ES7-155-6AU01",
            macAddress: "3C:7C:3F:14:09:B4",
            ipAddress: nil,
            subnetMask: nil,
            gatewayAddress: nil,
            discoveryProtocols: [.profinet, .bootp, .arp],
            addressingState: .unconfigured,
            linkStatus: .active,
            lastSeen: Date()
        )
    ]

    static let events: [CommissioningEvent] = [
        CommissioningEvent(
            kind: .validationCompleted,
            deviceName: "Filler Cell Controller",
            detail: "Identity response confirmed: CompactLogix 5380, serial CF61A0B2."
        )
    ]
}
