import Combine
import Foundation

@MainActor
final class CommissioningViewModel: ObservableObject {
    @Published private(set) var gatewayStatus: GatewayStatus = .offline
    @Published private(set) var gatewayInfo: GatewayInfo?
    @Published private(set) var devices: [PLCDevice] = []
    @Published private(set) var events: [CommissioningEvent] = []
    @Published var profiles: [NetworkProfile] = [.commissioningLab, .lineTwo]
    @Published private(set) var selectedProfileID: UUID = NetworkProfile.commissioningLab.id
    @Published private(set) var isWorking = false
    @Published var alert: AppAlert?
    @Published private(set) var discoveryDebug: DiscoveryDebugReport?

    private var gateway: any GatewayClient
    private let profilesStorageKey = "fieldlink.networkProfiles"
    private let selectedProfileStorageKey = "fieldlink.selectedProfileID"

    init(gateway: any GatewayClient) {
        self.gateway = gateway
        restoreProfiles()
    }

    var activeProfile: NetworkProfile {
        profiles.first(where: { $0.id == selectedProfileID }) ?? NetworkProfile.commissioningLab
    }

    var isGatewayReady: Bool {
        gatewayStatus == .ready
    }

    func configureGateway(_ client: any GatewayClient) async {
        gateway = client
        gatewayStatus = .offline
        gatewayInfo = nil
        devices = []
        events = []
        discoveryDebug = nil
        await connectGateway()
    }

    func connectGateway() async {
        guard !isWorking else { return }
        isWorking = true
        gatewayStatus = .connecting
        defer { isWorking = false }

        do {
            gatewayStatus = try await gateway.connect()
            gatewayInfo = try await gateway.gatewayInfo()
            events = try await gateway.fetchAuditTrail()
        } catch {
            gatewayStatus = .fault(error.localizedDescription)
            present(error, title: "Unable to connect")
        }
    }

    func discoverDevices() async {
        guard isGatewayReady else {
            alert = AppAlert(title: "Gateway required", message: "Connect the FieldLink Gateway before discovering PLCs.")
            return
        }
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            devices = try await gateway.startDiscovery(profile: activeProfile)
            events = try await gateway.fetchAuditTrail()
            discoveryDebug = await gateway.lastDiscoveryDebug()
        } catch {
            discoveryDebug = await gateway.lastDiscoveryDebug()
            present(error, title: "Discovery failed")
        }
    }

    @discardableResult
    func applyAddressChange(_ request: AddressChangeRequest) async -> Bool {
        guard isGatewayReady else {
            alert = AppAlert(title: "Gateway required", message: "Connect the FieldLink Gateway before applying an address change.")
            return false
        }
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }

        do {
            _ = try await gateway.applyAddressChange(request)
            devices = try await gateway.startDiscovery(profile: activeProfile)
            events = try await gateway.fetchAuditTrail()
            return true
        } catch {
            if let events = try? await gateway.fetchAuditTrail() {
                self.events = events
            }
            present(error, title: "Address change not applied")
            return false
        }
    }

    func selectProfile(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
        persistProfiles()
    }

    func upsertProfile(_ profile: NetworkProfile) {
        guard profile.isValid else {
            alert = AppAlert(title: "Invalid profile", message: "Enter a name and valid IPv4 values for the gateway interface, subnet mask, and gateway address.")
            return
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        selectedProfileID = profile.id
        persistProfiles()
    }

    func deleteProfile(_ profile: NetworkProfile) {
        guard profiles.count > 1 else {
            alert = AppAlert(title: "Profile required", message: "Keep at least one network profile for discovery and assignment.")
            return
        }
        profiles.removeAll { $0.id == profile.id }
        if selectedProfileID == profile.id {
            selectedProfileID = profiles[0].id
        }
        persistProfiles()
    }

    func device(with id: UUID) -> PLCDevice? {
        devices.first(where: { $0.id == id })
    }

    func conflictingDevice(for request: AddressChangeRequest) -> PLCDevice? {
        devices.first { $0.id != request.deviceID && $0.ipAddress == request.newIPAddress }
    }

    func debugExportText() -> String {
        discoveryDebug?.shareText ?? "No discovery debug yet. Run Discover devices first."
    }

    func auditExportText() -> String {
        let gatewayLine: String
        if let gatewayInfo {
            gatewayLine = "Gateway: \(gatewayInfo.identifier) (\(gatewayInfo.serialNumber))"
        } else {
            gatewayLine = "Gateway: not connected"
        }

        var lines = [
            "FieldLink PLC commissioning activity",
            gatewayLine,
            "Active profile: \(activeProfile.name) · \(activeProfile.summary)",
            ""
        ]

        if events.isEmpty {
            lines.append("No activity recorded.")
        } else {
            for event in events {
                let result = event.successful ? "success" : "rejected"
                lines.append("[\(event.timestamp.formatted(date: .abbreviated, time: .shortened))] \(event.kind.rawValue) — \(result)")
                if let deviceName = event.deviceName {
                    lines.append("Device: \(deviceName)")
                }
                lines.append(event.detail)
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func restoreProfiles() {
        if let data = UserDefaults.standard.data(forKey: profilesStorageKey),
           let saved = try? JSONDecoder().decode([NetworkProfile].self, from: data),
           !saved.isEmpty {
            profiles = saved
        }
        if let raw = UserDefaults.standard.string(forKey: selectedProfileStorageKey),
           let id = UUID(uuidString: raw),
           profiles.contains(where: { $0.id == id }) {
            selectedProfileID = id
        }
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesStorageKey)
        }
        UserDefaults.standard.set(selectedProfileID.uuidString, forKey: selectedProfileStorageKey)
    }

    private func present(_ error: Error, title: String) {
        alert = AppAlert(title: title, message: error.localizedDescription)
    }
}
