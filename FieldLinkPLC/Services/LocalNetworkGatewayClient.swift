import CryptoKit
import Darwin
import Foundation
import Network
import os
import Security

private let discoveryLog = Logger(subsystem: "com.johnnybox.fieldlinkplc", category: "discovery")

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
                discoveryLog.error("Discovery blocked: \(blocked.summary, privacy: .public)")
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
            let profileBroadcast = directedBroadcast(ip: profile.interfaceIPAddress, mask: profile.subnetMask)
            let sameSubnet = profileBroadcast == network.broadcastAddress
            let extraBroadcasts = sameSubnet ? [profileBroadcast] : []
            let extraUnicasts = sameSubnet
                ? subnetHosts(ip: profile.interfaceIPAddress, mask: profile.subnetMask, skipping: network.address)
                : []
            let found = await Task.detached(priority: .userInitiated) {
                EtherNetIPScanner.scan(
                    interface: network,
                    extraBroadcasts: extraBroadcasts,
                    extraUnicasts: extraUnicasts
                )
            }.value
            devices = found.devices
            lastDebug = found.debugReport
            discoveryLog.info("\(found.summary, privacy: .public)")
            if found.devices.isEmpty {
                discoveryLog.info("No EtherNet/IP devices parsed")
            } else {
                for device in found.devices {
                    discoveryLog.info("Found \(device.name, privacy: .public) \(device.displayedIPAddress, privacy: .public) vendor=\(device.vendor, privacy: .public)")
                }
            }
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

    static func isRequest(_ data: Data) -> Bool {
        guard data.count == 24 else { return false }
        return readUInt16LE(data, 0) == 0x0063 && readUInt16LE(data, 2) == 0
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
        case 77: "HMS / Softing / PC adapter"
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
            let eipCount = devices.filter { $0.discoveryProtocols.contains(.ethernetIP) }.count
            let liveOnly = devices.count - eipCount
            var parts = [
                "EtherNet/IP ListIdentity on \(interface.name) \(interface.address)/\(interface.prefixLength)\(interface.linkDescription)",
                "found \(eipCount) EtherNet/IP device(s)",
                liveOnly > 0 ? "plus \(liveOnly) live IPv4 host(s)" : nil,
                "unicast probes \(unicastsSent)",
                "broadcasts \(broadcastsSent)",
                "recv \(datagramsReceived)"
            ].compactMap { $0 }
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
            blockedReason: "This signed build does not include Apple’s approved Multicast Networking capability, so the app did not attempt UDP broadcast. Use a known IP after adding that feature, or use a FieldLink Gateway for unknown/no-IP devices.",
            multicastEntitlementPresent: false
        )
    }

    static func scan(
        interface: IPv4Interface,
        extraBroadcasts: [String] = [],
        extraUnicasts: [String] = []
    ) -> Result {
        var targets = ["255.255.255.255"]
        if interface.prefixLength >= 24, interface.broadcastAddress != "255.255.255.255" {
            targets.append(interface.broadcastAddress)
        }
        for broadcast in extraBroadcasts where !targets.contains(broadcast) && broadcast != "0.0.0.0" {
            targets.append(broadcast)
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
        var receiveBuffer: Int32 = 256 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 150_000)
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

        // Many EtherNet/IP stacks reply to UDP 44818, not the ephemeral source port.
        var bindAddress = sockaddr_in()
        bindAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddress.sin_family = sa_family_t(AF_INET)
        bindAddress.sin_port = EtherNetIPListIdentity.udpPort.bigEndian
        bindAddress.sin_addr.s_addr = INADDR_ANY
        let bind44818 = withUnsafePointer(to: &bindAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bind44818 != 0 {
            bindAddress.sin_port = 0
            let bindAny = withUnsafePointer(to: &bindAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindAny == 0 else {
                return setupFailure("Unable to bind the EtherNet/IP UDP receive socket: \(String(cString: strerror(errno))).")
            }
        }
        stats.sourcePort = localPort(fd: fd)

        let request = [UInt8](EtherNetIPListIdentity.request)
        var discovered: [String: PLCDevice] = [:]
        var buffer = [UInt8](repeating: 0, count: 4096)

        func collectReplies(wait: Bool) {
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let flags: Int32 = wait ? 0 : MSG_DONTWAIT
            let received = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    recvfrom(fd, &buffer, buffer.count, flags, sockaddrPointer, &sourceLength)
                }
            }
            guard received > 0 else { return }
            let sourceAddress = ipv4String(source)
            let sourcePort = UInt16(bigEndian: source.sin_port)
            let data = Data(buffer.prefix(Int(received)))
            if sourceAddress == interface.address || EtherNetIPListIdentity.isRequest(data) {
                return
            }
            stats.datagramsReceived += 1
            let device = EtherNetIPListIdentity.parse(response: data, sourceAddress: sourceAddress)
            if let device {
                discovered[device.serialNumber + "|" + (device.ipAddress ?? sourceAddress)] = device
            } else {
                discoveryLog.info("Unparsed UDP \(received)B from \(sourceAddress, privacy: .public):\(sourcePort)")
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

        func send(_ host: String, isBroadcast: Bool) {
            let sent = sendPacket(fd: fd, bytes: request, host: host)
            if sent {
                if isBroadcast { stats.broadcastsSent += 1 } else { stats.unicastsSent += 1 }
            } else {
                stats.sendFailures += 1
                stats.lastSendError = "\(host): \(String(cString: strerror(errno)))"
            }
        }

        var unicastHosts = subnetHosts(ip: interface.address, mask: interface.netmask, skipping: interface.address)
        for host in extraUnicasts where !unicastHosts.contains(host) && host != interface.address {
            unicastHosts.append(host)
        }
        unicastHosts = unicastHosts.filter { isOnLink($0, interface: interface) }

        for (index, host) in unicastHosts.enumerated() {
            send(host, isBroadcast: false)
            if index % 16 == 0 {
                collectReplies(wait: false)
            }
        }

        let deadline = Date().addingTimeInterval(5.0)
        var nextBroadcast = Date()
        while Date() < deadline {
            if Date() >= nextBroadcast {
                for host in targets {
                    send(host, isBroadcast: true)
                }
                nextBroadcast = Date().addingTimeInterval(1.2)
            }
            collectReplies(wait: true)
        }

        let pingHosts = ICMPHostProbe.liveHosts(interface: interface, hosts: unicastHosts)
        let tcpHosts = TCPHostProbe.liveHosts(interface: interface, hosts: unicastHosts)
        let liveHosts = Set(pingHosts).union(tcpHosts)
        discoveryLog.info("Host probe ICMP=\(pingHosts.count) TCP=\(tcpHosts.count) unique=\(liveHosts.count)")
        for host in liveHosts.sorted() {
            let alreadyFound = discovered.values.contains { $0.ipAddress == host }
            guard !alreadyFound else { continue }
            let identity = LiveHostIdentifier.identify(ip: host, interfaceIndex: interfaceIndex)
            let device = liveIPv4Device(ip: host, identity: identity)
            discovered[host] = device
            discoveryLog.info(
                "Live IPv4 \(host, privacy: .public) name=\(device.name, privacy: .public) \(device.product, privacy: .public)"
            )
        }

        stats.devices = discovered.values.sorted { lhs, rhs in
            let leftEIP = lhs.discoveryProtocols.contains(.ethernetIP)
            let rightEIP = rhs.discoveryProtocols.contains(.ethernetIP)
            if leftEIP != rightEIP { return leftEIP && !rightEIP }
            return (lhs.ipAddress ?? "") < (rhs.ipAddress ?? "")
        }
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

            @Sendable func finish() {
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
    private static let entitlement = "com.apple.developer.networking.multicast"

    static var isPresent: Bool {
        if let fromProcess = processEntitlement() {
            return fromProcess
        }
        return provisioningProfileEntitlements()?[entitlement] as? Bool ?? false
    }

    /// `SecTaskCreateFromSelf` exists in Security on iOS but is not in the Swift overlay.
    private static func processEntitlement() -> Bool? {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let createSymbol = dlsym(defaultHandle, "SecTaskCreateFromSelf"),
              let copySymbol = dlsym(defaultHandle, "SecTaskCopyValueForEntitlement") else {
            return nil
        }
        typealias Create = @convention(c) (CFAllocator?) -> UnsafeRawPointer?
        typealias Copy = @convention(c) (UnsafeRawPointer, CFString, UnsafeMutablePointer<UnsafeRawPointer?>?) -> Unmanaged<CFTypeRef>?
        let create = unsafeBitCast(createSymbol, to: Create.self)
        let copy = unsafeBitCast(copySymbol, to: Copy.self)
        guard let task = create(kCFAllocatorDefault) else { return nil }
        defer { Unmanaged<CFTypeRef>.fromOpaque(task).release() }
        guard let value = copy(task, entitlement as CFString, nil) else { return false }
        return (value.takeRetainedValue() as? NSNumber)?.boolValue ?? false
    }

    private static func provisioningProfileEntitlements() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let ascii = String(data: data, encoding: .isoLatin1),
              let xmlStart = ascii.range(of: "<?xml"),
              let xmlEnd = ascii.range(of: "</plist>") else {
            return nil
        }
        let xml = String(ascii[xmlStart.lowerBound...xmlEnd.upperBound])
        guard let plistData = xml.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist["Entitlements"] as? [String: Any]
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

private func liveIPv4Device(ip: String, identity: LiveHostIdentity = LiveHostIdentity()) -> PLCDevice {
    PLCDevice(
        id: EtherNetIPListIdentity.stableID(serial: "ICMP", ip: ip),
        name: identity.displayName(for: ip),
        vendor: identity.vendor,
        product: identity.product,
        revision: identity.hostname ?? "",
        serialNumber: ip,
        macAddress: "Unknown",
        ipAddress: ip,
        subnetMask: nil,
        gatewayAddress: nil,
        discoveryProtocols: [.arp],
        addressingState: .staticAddress,
        linkStatus: .active,
        lastSeen: Date()
    )
}

struct LiveHostIdentity {
    var hostname: String?
    var openPorts: [UInt16] = []
    var httpServer: String?
    var httpTitle: String?

    var vendor: String {
        if openPorts.contains(44818) { return "CIP TCP (no UDP identity)" }
        if openPorts.contains(502) { return "Modbus TCP" }
        if openPorts.contains(9100) { return "Printer" }
        if openPorts.contains(554) { return "RTSP camera" }
        if openPorts.contains(445) { return "Windows / SMB" }
        if openPorts.contains(80) || openPorts.contains(443) || openPorts.contains(8080) { return "HTTP device" }
        if openPorts.contains(22) { return "SSH host" }
        if hostname != nil { return "DNS name" }
        return "Live IPv4"
    }

    var product: String {
        var parts: [String] = []
        if !openPorts.isEmpty {
            parts.append("TCP \(openPorts.map(String.init).joined(separator: ", "))")
        }
        if let httpServer, !httpServer.isEmpty { parts.append(httpServer) }
        if let httpTitle, !httpTitle.isEmpty, !LiveHostIdentity.isUselessTitle(httpTitle) {
            parts.append(httpTitle)
        }
        if parts.isEmpty { parts.append("Reachable. No EtherNet/IP ListIdentity.") }
        else { parts.append("No EtherNet/IP ListIdentity") }
        return parts.joined(separator: " · ")
    }

    func displayName(for ip: String) -> String {
        if let hostname {
            let short = hostname.split(separator: ".").first.map(String.init) ?? hostname
            if !short.isEmpty, short != ip { return short }
        }
        if let httpTitle, !httpTitle.isEmpty, !LiveHostIdentity.isUselessTitle(httpTitle) {
            return httpTitle
        }
        if openPorts.contains(9100) { return "Printer" }
        if openPorts.contains(554) { return "Camera" }
        if openPorts.contains(502) { return "Modbus device" }
        if openPorts.contains(44818) { return "EtherNet/IP TCP host" }
        if openPorts.contains(445) { return "Windows host" }
        if ip.hasSuffix(".1"), openPorts.contains(80) || openPorts.contains(443) { return "Router / gateway" }
        if openPorts.contains(80) || openPorts.contains(443) { return "Web device" }
        return "Live IPv4 host"
    }

    static func isUselessTitle(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return lowered.contains("404")
            || lowered.contains("403")
            || lowered.contains("401")
            || lowered.contains("not found")
            || lowered.contains("unauthorized")
            || lowered == "error"
    }
}

enum LiveHostIdentifier {
    private static let identityPorts: [UInt16] = [22, 80, 443, 445, 502, 554, 8080, 9100, 44818]

    static func identify(ip: String, interfaceIndex: UInt32) -> LiveHostIdentity {
        var identity = LiveHostIdentity()
        identity.hostname = reverseName(ip)
        identity.openPorts = TCPHostProbe.openPorts(hosts: [ip], ports: identityPorts, interfaceIndex: interfaceIndex)[ip] ?? []
        if identity.openPorts.contains(80) {
            let banner = httpBanner(ip: ip, port: 80, interfaceIndex: interfaceIndex)
            identity.httpServer = banner.server
            identity.httpTitle = banner.title
        }
        return identity
    }

    private static func reverseName(_ ip: String) -> String? {
        let box = TimeoutBox<String>()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_pton4(ip)
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    getnameinfo(sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size), &hostname, socklen_t(hostname.count), nil, 0, NI_NAMEREQD)
                }
            }
            guard result == 0 else { return }
            let name = String(cString: hostname)
            if name != ip, !name.isEmpty { box.value = name }
        }
        _ = group.wait(timeout: .now() + 0.45)
        return box.value
    }

    private static func httpBanner(ip: String, port: UInt16, interfaceIndex: UInt32) -> (server: String?, title: String?) {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return (nil, nil) }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        if interfaceIndex != 0 {
            var index = interfaceIndex
            setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_pton4(ip)
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var pollFd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollFd, 1, 500) > 0 else { return (nil, nil) }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        _ = withUnsafeMutablePointer(to: &error) { pointer in
            getsockopt(fd, SOL_SOCKET, SO_ERROR, pointer, &length)
        }
        guard error == 0 else { return (nil, nil) }

        let request = "GET / HTTP/1.0\r\nHost: \(ip)\r\nUser-Agent: FieldLinkPLC\r\nConnection: close\r\n\r\n"
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        var timeout = timeval(tv_sec: 0, tv_usec: 600_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = fcntl(fd, F_SETFL, 0)
        var buffer = [UInt8](repeating: 0, count: 2048)
        let received = recv(fd, &buffer, buffer.count, 0)
        guard received > 0 else { return (nil, nil) }
        let text = String(bytes: buffer.prefix(Int(received)), encoding: .isoLatin1) ?? ""
        return (httpHeader(text, name: "Server"), htmlTitle(text))
    }

    private static func httpHeader(_ text: String, name: String) -> String? {
        for line in text.split(whereSeparator: { $0 == "\n" }) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = name + ":"
            if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
                let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func htmlTitle(_ text: String) -> String? {
        guard let start = text.lowercased().range(of: "<title>"),
              let end = text.lowercased().range(of: "</title>", range: start.upperBound..<text.endIndex) else {
            return nil
        }
        let title = text[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : String(title.prefix(60))
    }
}

private final class TimeoutBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

enum ICMPHostProbe {
    static func liveHosts(interface: IPv4Interface, hosts: [String]) -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else {
            discoveryLog.info("ICMP probe unavailable: \(String(cString: strerror(errno)), privacy: .public)")
            return []
        }
        defer { close(fd) }

        var interfaceIndex = if_nametoindex(interface.name)
        if interfaceIndex != 0 {
            setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &interfaceIndex, socklen_t(MemoryLayout<UInt32>.size))
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 80_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let identifier = UInt16.random(in: 1 ... .max)
        for (index, host) in hosts.enumerated() {
            sendEcho(fd: fd, host: host, identifier: identifier, sequence: UInt16(truncatingIfNeeded: index))
        }

        var found = Set<String>()
        let deadline = Date().addingTimeInterval(2.0)
        var buffer = [UInt8](repeating: 0, count: 256)
        while Date() < deadline {
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    recvfrom(fd, &buffer, buffer.count, 0, sockaddrPointer, &sourceLength)
                }
            }
            guard received > 0 else { continue }
            let address = ipv4String(source)
            if address != interface.address, address != "0.0.0.0" {
                found.insert(address)
            }
        }
        return found.sorted()
    }

    private static func sendEcho(fd: Int32, host: String, identifier: UInt16, sequence: UInt16) {
        var packet = Data(count: 8)
        packet[0] = 8
        packet[1] = 0
        packet[4] = UInt8(identifier >> 8)
        packet[5] = UInt8(identifier & 0xff)
        packet[6] = UInt8(sequence >> 8)
        packet[7] = UInt8(sequence & 0xff)
        let sum = internetChecksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xff)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_pton4(host)
        _ = packet.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    sendto(fd, buffer.baseAddress, packet.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}

enum TCPHostProbe {
    private static let ports: [UInt16] = [80, 443, 44818]

    static func liveHosts(interface: IPv4Interface, hosts: [String]) -> [String] {
        let interfaceIndex = if_nametoindex(interface.name)
        var live = Set<String>()
        let batchSize = 32
        var start = 0
        while start < hosts.count {
            let end = min(start + batchSize, hosts.count)
            live.formUnion(probe(hosts: Array(hosts[start..<end]), interfaceIndex: interfaceIndex))
            start = end
        }
        return live.sorted()
    }

    static func openPorts(hosts: [String], ports: [UInt16], interfaceIndex: UInt32) -> [String: [UInt16]] {
        connect(hosts: hosts, ports: ports, interfaceIndex: interfaceIndex, timeoutMs: 450).open
    }

    private static func probe(hosts: [String], interfaceIndex: UInt32) -> Set<String> {
        let result = connect(hosts: hosts, ports: ports, interfaceIndex: interfaceIndex, timeoutMs: 280)
        return Set(result.live)
    }

    private static func connect(
        hosts: [String],
        ports: [UInt16],
        interfaceIndex: UInt32,
        timeoutMs: Int32
    ) -> (live: [String], open: [String: [UInt16]]) {
        var sockets: [(fd: Int32, host: String, port: UInt16)] = []
        sockets.reserveCapacity(hosts.count * ports.count)
        for host in hosts {
            for port in ports {
                let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                guard fd >= 0 else { continue }
                _ = fcntl(fd, F_SETFL, O_NONBLOCK)
                if interfaceIndex != 0 {
                    var index = interfaceIndex
                    setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
                }
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                address.sin_addr.s_addr = inet_pton4(host)
                _ = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                sockets.append((fd, host, port))
            }
        }

        var pollFds = sockets.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
        _ = pollFds.withUnsafeMutableBufferPointer { buffer in
            poll(buffer.baseAddress, nfds_t(buffer.count), timeoutMs)
        }

        var live = Set<String>()
        var open: [String: [UInt16]] = [:]
        for (index, entry) in sockets.enumerated() {
            if pollFds[index].revents & Int16(POLLOUT | POLLERR | POLLHUP) != 0 {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                _ = withUnsafeMutablePointer(to: &error) { pointer in
                    getsockopt(entry.fd, SOL_SOCKET, SO_ERROR, pointer, &length)
                }
                if error == 0 || error == ECONNREFUSED {
                    live.insert(entry.host)
                }
                if error == 0 {
                    open[entry.host, default: []].append(entry.port)
                }
            }
            close(entry.fd)
        }
        for key in open.keys {
            open[key]?.sort()
        }
        return (Array(live), open)
    }
}

private func isOnLink(_ host: String, interface: IPv4Interface) -> Bool {
    let address = ipv4Value(host)
    let local = ipv4Value(interface.address)
    let mask = ipv4Value(interface.netmask)
    guard mask != 0 else { return false }
    return (address & mask) == (local & mask)
}

private func internetChecksum(_ data: Data) -> UInt16 {
    var sum: UInt32 = 0
    var index = 0
    while index + 1 < data.count {
        sum += UInt32(data[index]) << 8 | UInt32(data[index + 1])
        index += 2
    }
    if index < data.count {
        sum += UInt32(data[index]) << 8
    }
    while sum >> 16 != 0 {
        sum = (sum & 0xffff) + (sum >> 16)
    }
    return UInt16(~sum & 0xffff)
}

private func directedBroadcast(ip: String, mask: String) -> String {
    let address = ipv4Value(ip)
    let netmask = ipv4Value(mask)
    guard address != 0, netmask != 0 else { return "255.255.255.255" }
    return ipv4String(address | ~netmask)
}

private func subnetHosts(ip: String, mask: String, skipping excluded: String) -> [String] {
    let address = ipv4Value(ip)
    let netmask = ipv4Value(mask)
    guard address != 0, netmask != 0 else { return [] }
    var prefix = netmask == 0 ? 22 : netmask.nonzeroBitCount
    if prefix < 22 { prefix = 22 }
    guard prefix < 32 else { return [] }
    let scanMask = UInt32.max << (32 - prefix)
    let hostCount = (1 << (32 - prefix)) - 2
    guard hostCount <= 1022 else { return [] }
    let network = address & scanMask
    let broadcast = network | ~scanMask
    let skip = ipv4Value(excluded)
    var hosts: [String] = []
    var host = network + 1
    while host < broadcast {
        if host != address, host != skip {
            hosts.append(ipv4String(host))
        }
        host += 1
    }
    return hosts
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
