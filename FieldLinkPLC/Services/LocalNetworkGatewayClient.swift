import CryptoKit
import Darwin
import Foundation
import Network
import Security

/// Discovers real EtherNet/IP devices from this iPhone’s USB-C Ethernet adapter.
/// Wi-Fi is never used. Address writes stay on a physical FieldLink Gateway.
actor LocalNetworkGatewayClient: GatewayClient {
    private var connected = false
    private var interfaceSummary = "No link"
    private var devices: [PLCDevice] = []
    private var auditTrail: [CommissioningEvent] = []
    private var lastDebug: DiscoveryDebugReport?

    func connect() async throws -> GatewayStatus {
        await LocalNetworkAuthorization.promptIfNeeded()
        switch await IPv4Interface.plantEthernet() {
        case let .ready(network):
            connected = true
            interfaceSummary = "\(network.address) / \(network.prefixLength)"
            auditTrail.insert(
                CommissioningEvent(
                    kind: .gatewayConnected,
                    detail: "This iPhone is using live EtherNet/IP ListIdentity on USB-C Ethernet \(interfaceSummary)\(network.linkDescription)."
                ),
                at: 0
            )
            return .ready
        case let .linkWithoutAddress(name):
            connected = false
            throw GatewayClientError.ethernetHasNoAddress(name)
        case .none:
            connected = false
            throw GatewayClientError.noLocalNetwork
        }
    }

    func gatewayInfo() async throws -> GatewayInfo {
        guard connected else { throw GatewayClientError.notConnected }
        return GatewayInfo(
            identifier: "USB-C Ethernet",
            firmwareVersion: "0.1.0-live",
            serialNumber: "USB-C-ETHERNET",
            linkSpeed: "USB-C Ethernet · \(interfaceSummary)",
            simulatorMode: false
        )
    }

    func startDiscovery(profile: NetworkProfile) async throws -> [PLCDevice] {
        guard connected else { throw GatewayClientError.notConnected }
        switch await IPv4Interface.plantEthernet() {
        case let .ready(network):
            interfaceSummary = "\(network.address) / \(network.prefixLength)"
            guard MulticastNetworkingCapability.isPresent else {
                let blocked = EtherNetIPScanner.blockedResult(interface: network)
                devices = []
                lastDebug = blocked.debugReport
                auditTrail.insert(
                    CommissioningEvent(
                        kind: .discoveryCompleted,
                        detail: blocked.summary,
                        successful: false
                    ),
                    at: 0
                )
                throw GatewayClientError.broadcastCapabilityUnavailable
            }
            lastDebug = nil
            let found = await Task.detached(priority: .userInitiated) {
                EtherNetIPScanner.scan(interface: network)
            }.value
            devices = found.devices
            lastDebug = found.debugReport
            if let socketError = found.socketSetupErrors.first {
                auditTrail.insert(
                    CommissioningEvent(
                        kind: .discoveryCompleted,
                        detail: found.summary,
                        successful: false
                    ),
                    at: 0
                )
                throw GatewayClientError.gatewayFault(socketError)
            }
            auditTrail.insert(
                CommissioningEvent(
                    kind: .discoveryCompleted,
                    detail: found.summary
                ),
                at: 0
            )
            return devices
        case let .linkWithoutAddress(name):
            throw GatewayClientError.ethernetHasNoAddress(name)
        case .none:
            throw GatewayClientError.noLocalNetwork
        }
    }

    func applyAddressChange(_ request: AddressChangeRequest) async throws -> CommissioningEvent {
        guard connected else { throw GatewayClientError.notConnected }
        let event = CommissioningEvent(
            kind: .addressAssigned,
            deviceName: request.deviceName,
            detail: "Live iPhone discovery is read-only. Address changes require a FieldLink Gateway on the industrial Ethernet segment.",
            successful: false
        )
        auditTrail.insert(event, at: 0)
        throw GatewayClientError.unsupportedOperation("This iPhone can discover EtherNet/IP devices, but it cannot write addresses. That still requires a FieldLink Gateway.")
    }

    func fetchAuditTrail() async throws -> [CommissioningEvent] {
        guard connected else { throw GatewayClientError.notConnected }
        return auditTrail
    }

    func lastDiscoveryDebug() async -> DiscoveryDebugReport? {
        lastDebug
    }
}

enum EtherNetIPListIdentity {
    static let udpPort: UInt16 = 44818

    static var request: Data {
        var data = Data(count: 24)
        data[0] = 0x63
        data[1] = 0x00
        return data
    }

    static func parse(response: Data, sourceAddress: String) -> PLCDevice? {
        guard response.count >= 26 else { return nil }

        let command = readUInt16LE(response, 0)
        let status = readUInt32LE(response, 8)
        guard command == 0x0063, status == 0 else { return nil }

        let payloadLength = Int(readUInt16LE(response, 2))
        guard response.count >= 24 + payloadLength, payloadLength >= 2 else { return nil }

        let payload = response.subdata(in: 24 ..< 24 + payloadLength)
        let itemCount = Int(readUInt16LE(payload, 0))
        var offset = 2

        for _ in 0 ..< itemCount {
            guard payload.count >= offset + 4 else { return nil }
            let typeID = readUInt16LE(payload, offset)
            let length = Int(readUInt16LE(payload, offset + 2))
            offset += 4
            guard payload.count >= offset + length else { return nil }
            let item = payload.subdata(in: offset ..< offset + length)
            offset += length
            guard typeID == 0x000C else { continue }
            return identityDevice(from: item, sourceAddress: sourceAddress)
        }
        return nil
    }

    private static func identityDevice(from item: Data, sourceAddress: String) -> PLCDevice? {
        guard item.count >= 33 else { return nil }

        var cursor = 0
        cursor += 2
        let socketIP = socketAddressIP(item, offset: cursor) ?? sourceAddress
        cursor += 16

        guard item.count >= cursor + 15 else { return nil }
        let vendorID = readUInt16LE(item, cursor)
        let deviceType = readUInt16LE(item, cursor + 2)
        let productCode = readUInt16LE(item, cursor + 4)
        let major = item[cursor + 6]
        let minor = item[cursor + 7]
        let serial = readUInt32LE(item, cursor + 10)
        cursor += 14

        guard item.count > cursor else { return nil }
        let nameLength = Int(item[cursor])
        cursor += 1
        guard item.count >= cursor + nameLength else { return nil }
        let productName = String(bytes: item[cursor ..< cursor + nameLength], encoding: .isoLatin1)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (productName?.isEmpty == false ? productName! : "EtherNet/IP device")
        let serialText = String(format: "%08X", serial)
        let ip = socketIP.isEmpty ? sourceAddress : socketIP

        return PLCDevice(
            id: stableID(serial: serialText, ip: ip),
            name: displayName,
            vendor: vendorName(vendorID),
            product: "Code \(productCode) · type \(deviceType)",
            revision: "\(major).\(minor)",
            serialNumber: serialText,
            macAddress: "From identity response",
            ipAddress: ip,
            subnetMask: nil,
            gatewayAddress: nil,
            discoveryProtocols: [.ethernetIP],
            addressingState: .staticAddress,
            linkStatus: .active,
            lastSeen: Date()
        )
    }

    static func stableID(serial: String, ip: String) -> UUID {
        let digest = Insecure.MD5.hash(data: Data("\(serial)|\(ip)".utf8))
        return digest.withUnsafeBytes { pointer in
            UUID(uuid: pointer.load(as: uuid_t.self))
        }
    }

    private static func vendorName(_ id: UInt16) -> String {
        switch id {
        case 1: "Rockwell Automation"
        case 11: "Bosch"
        case 48: "Eaton"
        case 168: "WAGO"
        case 343: "Omron"
        case 419: "Siemens"
        case 806: "Phoenix Contact"
        default: "ODVA vendor \(id)"
        }
    }

    private static func socketAddressIP(_ data: Data, offset: Int) -> String? {
        guard data.count >= offset + 8 else { return nil }
        let address = readUInt32BE(data, offset + 4)
        guard address != 0 else { return nil }
        return [
            (address >> 24) & 0xff,
            (address >> 16) & 0xff,
            (address >> 8) & 0xff,
            address & 0xff
        ].map(String.init).joined(separator: ".")
    }
}

enum EtherNetIPScanner {
    struct Result {
        var devices: [PLCDevice]
        var unicastsSent: Int
        var broadcastsSent: Int
        var sendFailures: Int
        var datagramsReceived: Int
        var lastSendError: String?
        var interface: IPv4Interface
        var packets: [DiscoveryDebugPacket] = []
        var sourcePort: UInt16? = nil
        var broadcastTargets: [String] = []
        var socketSetupErrors: [String] = []
        var blockedReason: String? = nil
        var multicastEntitlementPresent = true

        var summary: String {
            if let blockedReason {
                return "EtherNet/IP discovery on \(interface.name) is blocked. \(blockedReason) Wi-Fi was not used."
            }
            var parts = [
                "EtherNet/IP ListIdentity on \(interface.name) \(interface.address)/\(interface.prefixLength)\(interface.linkDescription)",
                "found \(devices.count) device(s)",
                "unicast probes \(unicastsSent)",
                "broadcasts \(broadcastsSent)",
                "recv \(datagramsReceived)"
            ]
            if let sourcePort {
                parts.append("UDP source port \(sourcePort)")
            }
            if !broadcastTargets.isEmpty {
                parts.append("targets \(broadcastTargets.joined(separator: ", "))")
            }
            if sendFailures > 0 {
                parts.append("send failures \(sendFailures)\(lastSendError.map { " (\($0))" } ?? "")")
            }
            if !socketSetupErrors.isEmpty {
                parts.append("socket setup errors \(socketSetupErrors.joined(separator: " | "))")
            }
            if datagramsReceived == 0 {
                parts.append("No EtherNet/IP identity reply. Result is inconclusive: the PLC may have no IP, use another protocol, be silent, or have a link/configuration problem.")
            }
            parts.append("Wi-Fi was not used.")
            return parts.joined(separator: ". ")
        }

        var debugReport: DiscoveryDebugReport {
            DiscoveryDebugReport(
                capturedAt: Date(),
                interfaceName: interface.name,
                interfaceAddress: interface.address,
                netmask: interface.netmask,
                linkDescription: interface.linkDescription,
                unicastsSent: unicastsSent,
                broadcastsSent: broadcastsSent,
                sendFailures: sendFailures,
                datagramsReceived: datagramsReceived,
                lastSendError: lastSendError,
                packets: packets,
                deviceNames: devices.map { "\($0.name) \($0.displayedIPAddress)" },
                sourcePort: sourcePort,
                broadcastTargets: broadcastTargets,
                multicastEntitlementPresent: multicastEntitlementPresent,
                socketSetupErrors: socketSetupErrors,
                blockedReason: blockedReason
            )
        }
    }

    static func blockedResult(interface: IPv4Interface) -> Result {
        Result(
            devices: [],
            unicastsSent: 0,
            broadcastsSent: 0,
            sendFailures: 0,
            datagramsReceived: 0,
            lastSendError: nil,
            interface: interface,
            multicastEntitlementPresent: false,
            blockedReason: "This signed build does not include Apple’s approved Multicast Networking capability, so the app did not attempt UDP broadcast. Use a known IP after adding that feature, or use a FieldLink Gateway for unknown/no-IP devices."
        )
    }

    static func scan(interface: IPv4Interface) -> Result {
        let directedBroadcast = interface.broadcastAddress
        var targets = ["255.255.255.255"]
        if directedBroadcast != "255.255.255.255" {
            targets.append(directedBroadcast)
        }
        var stats = Result(
            devices: [],
            unicastsSent: 0,
            broadcastsSent: 0,
            sendFailures: 0,
            datagramsReceived: 0,
            lastSendError: nil,
            interface: interface,
            broadcastTargets: targets
        )

        func setupFailure(_ detail: String) -> Result {
            stats.socketSetupErrors.append(detail)
            stats.blockedReason = "The EtherNet/IP discovery socket could not be prepared."
            return stats
        }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            return setupFailure("Unable to open a UDP socket for EtherNet/IP discovery: \(String(cString: strerror(errno))).")
        }
        defer { close(fd) }

        var broadcast: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return setupFailure("Unable to enable UDP broadcast: \(String(cString: strerror(errno))).")
        }
        var reuse: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return setupFailure("Unable to configure the EtherNet/IP UDP socket: \(String(cString: strerror(errno))).")
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            return setupFailure("Unable to set the EtherNet/IP receive timeout: \(String(cString: strerror(errno))).")
        }

        var interfaceIndex = if_nametoindex(interface.name)
        guard interfaceIndex != 0 else {
            return setupFailure("Unable to resolve the USB-C Ethernet interface index for \(interface.name).")
        }
        guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &interfaceIndex, socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
            return setupFailure("Unable to bind EtherNet/IP discovery to \(interface.name): \(String(cString: strerror(errno))).")
        }

        var bindAddress = sockaddr_in()
        bindAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddress.sin_family = sa_family_t(AF_INET)
        bindAddress.sin_port = 0
        bindAddress.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &bindAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            return setupFailure("Unable to bind the EtherNet/IP UDP receive socket: \(String(cString: strerror(errno))).")
        }
        stats.sourcePort = localPort(fd: fd)

        let request = [UInt8](EtherNetIPListIdentity.request)

        func send(_ host: String, isBroadcast: Bool) {
            let sent = sendPacket(fd: fd, bytes: request, host: host)
            if sent {
                if isBroadcast { stats.broadcastsSent += 1 } else { stats.unicastsSent += 1 }
            } else {
                stats.sendFailures += 1
                stats.lastSendError = "\(host): \(String(cString: strerror(errno)))"
            }
        }

        // This code path is called only after runtime verification that the signed
        // iPhone build carries Apple's Multicast Networking capability. It performs
        // bounded read-only discovery, never an address sweep.
        for host in targets {
            send(host, isBroadcast: true)
        }

        var discovered: [String: PLCDevice] = [:]
        let deadline = Date().addingTimeInterval(4.0)
        var buffer = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    recvfrom(fd, &buffer, buffer.count, 0, sockaddrPointer, &sourceLength)
                }
            }
            guard received > 0 else { continue }
            stats.datagramsReceived += 1
            let sourceAddress = ipv4String(source)
            let sourcePort = UInt16(bigEndian: source.sin_port)
            let data = Data(buffer.prefix(Int(received)))
            let device = EtherNetIPListIdentity.parse(response: data, sourceAddress: sourceAddress)
            if let device {
                discovered[device.serialNumber + "|" + (device.ipAddress ?? sourceAddress)] = device
            }
            if stats.packets.count < 64 {
                stats.packets.append(
                    DiscoveryDebugPacket(
                        source: "\(sourceAddress):\(sourcePort)",
                        byteCount: Int(received),
                        hexPrefix: data.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " "),
                        parsedName: device.map { "\($0.name) \($0.displayedIPAddress)" }
                    )
                )
            }
        }

        stats.devices = discovered.values.sorted { ($0.ipAddress ?? "") < ($1.ipAddress ?? "") }
        return stats
    }

    private static func sendPacket(fd: Int32, bytes: [UInt8], host: String) -> Bool {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = EtherNetIPListIdentity.udpPort.bigEndian
        address.sin_addr.s_addr = inet_pton4(host)
        let result = bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    sendto(fd, buffer.baseAddress, bytes.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return result >= 0
    }

    private static func localPort(fd: Int32) -> UInt16? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard result == 0 else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }
}

private func inet_pton4(_ host: String) -> in_addr_t {
    var addr = in_addr()
    guard inet_pton(AF_INET, host, &addr) == 1 else { return INADDR_NONE }
    return addr.s_addr
}

struct IPv4Interface: Sendable {
    let name: String
    let address: String
    let netmask: String
    let flags: UInt32

    var prefixLength: Int {
        let mask = ipv4Value(netmask)
        return mask.nonzeroBitCount
    }

    var isUp: Bool { flags & UInt32(IFF_UP) != 0 }
    var isRunning: Bool { flags & UInt32(IFF_RUNNING) != 0 }

    var linkDescription: String {
        switch (isUp, isRunning) {
        case (true, true): " · link up"
        case (true, false): " · no carrier"
        default: " · interface down"
        }
    }

    var broadcastAddress: String {
        let ip = ipv4Value(address)
        let mask = ipv4Value(netmask)
        return ipv4String(ip | ~mask)
    }

    static func plantEthernet() async -> PlantEthernetLink {
        let reportedNames = await WiredEthernetMonitor.interfaceNames()
        let ipv4 = ipv4Interfaces()
        if let network = ipv4.first(where: { reportedNames.contains($0.name) }) {
            return .ready(network)
        }
        if let network = ipv4.first(where: { PlantEthernet.isCandidateName($0.name) }) {
            return .ready(network)
        }
        if let name = reportedNames.sorted().first {
            return .linkWithoutAddress(name)
        }
        return .none
    }

    static func wiredEthernet() async -> IPv4Interface? {
        if case let .ready(network) = await plantEthernet() {
            return network
        }
        return nil
    }

    private static func ipv4Interfaces() -> [IPv4Interface] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(first) }

        var candidates: [IPv4Interface] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let name = String(cString: current.pointee.ifa_name)
            guard current.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
                  let addr = current.pointee.ifa_addr,
                  let mask = current.pointee.ifa_netmask else { continue }

            let address = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                ipv4String($0.pointee)
            }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                ipv4String($0.pointee)
            }
            guard address != "0.0.0.0" else { continue }
            candidates.append(
                IPv4Interface(
                    name: name,
                    address: address,
                    netmask: netmask,
                    flags: UInt32(current.pointee.ifa_flags)
                )
            )
        }
        return candidates
    }
}

enum PlantEthernetLink: Sendable {
    case ready(IPv4Interface)
    case linkWithoutAddress(String)
    case none
}

enum PlantEthernet {
    static func isCandidateName(_ name: String) -> Bool {
        if name == "en0" { return false }
        if name == "lo0" || name.hasPrefix("lo") { return false }
        if name.hasPrefix("pdp_") || name.hasPrefix("utun") || name.hasPrefix("ipsec") { return false }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("ap") { return false }
        if name.hasPrefix("bridge") || name.hasPrefix("anpi") { return false }
        if name.hasPrefix("en") { return true }
        if name.hasPrefix("eth") { return true }
        return false
    }

    static func isCandidate(_ interface: NWInterface) -> Bool {
        switch interface.type {
        case .wiredEthernet:
            return true
        case .wifi, .cellular, .loopback:
            return false
        default:
            return isCandidateName(interface.name)
        }
    }
}

enum WiredEthernetMonitor {
    static func interfaceNames() async -> Set<String> {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let state = EthernetNameCollector()

            func finish() {
                guard let names = state.complete() else { return }
                monitor.cancel()
                continuation.resume(returning: names)
            }

            monitor.pathUpdateHandler = { path in
                let names = Set(path.availableInterfaces.filter(PlantEthernet.isCandidate).map(\.name))
                if state.merge(names) {
                    finish()
                }
            }
            monitor.start(queue: DispatchQueue(label: "fieldlink.wired-ethernet"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) {
                finish()
            }
        }
    }
}

private final class EthernetNameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String> = []
    private var finished = false

    func merge(_ extra: Set<String>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        names.formUnion(extra)
        return !names.isEmpty && !finished
    }

    func complete() -> Set<String>? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        finished = true
        return names
    }
}

enum LocalNetworkAuthorization {
    static func promptIfNeeded() async {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_fieldlink-gateway._tcp", domain: nil), using: parameters)
        browser.start(queue: .global(qos: .userInitiated))
        try? await Task.sleep(nanoseconds: 400_000_000)
        browser.cancel()
    }
}

/// Broadcast is allowed only when Apple has approved the managed capability for
/// the actual App ID and that entitlement is present in the signed app. Keeping
/// this check in the live client prevents a misleading "0 devices" result from
/// an on-device build that cannot legally send or receive UDP broadcast.
enum MulticastNetworkingCapability {
    static var isPresent: Bool {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.networking.multicast" as CFString,
                nil
              ) else {
            return false
        }
        return (value as? NSNumber)?.boolValue ?? false
    }
}

private func readUInt16LE(_ data: Data, _ offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

private func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
}

private func readUInt32BE(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset]) << 24
        | UInt32(data[offset + 1]) << 16
        | UInt32(data[offset + 2]) << 8
        | UInt32(data[offset + 3])
}

private func ipv4Value(_ address: String) -> UInt32 {
    UInt32(bigEndian: inet_addr(address))
}

private func ipv4String(_ value: UInt32) -> String {
    let parts = [
        (value >> 24) & 0xff,
        (value >> 16) & 0xff,
        (value >> 8) & 0xff,
        value & 0xff
    ]
    return parts.map(String.init).joined(separator: ".")
}

private func ipv4String(_ address: sockaddr_in) -> String {
    ipv4String(UInt32(bigEndian: address.sin_addr.s_addr))
}
