import Combine
import Foundation
import Security

enum GatewayConnectionMode: String, Codable {
    case simulator
    case liveNetwork
    case pairedGateway
}

struct PairedGatewayConfiguration: Codable, Hashable {
    let id: UUID
    let displayName: String
    let baseURLString: String
    let certificatePinBase64: String
    let gatewayInfo: GatewayInfo
}

@MainActor
final class GatewaySessionStore: ObservableObject {
    @Published private(set) var mode: GatewayConnectionMode = GatewaySessionStore.defaultMode
    @Published private(set) var pairedGateway: PairedGatewayConfiguration?

    private let configurationKey = "fieldlink.pairedGateway.configuration"
    private let keychain = GatewayKeychain(service: "com.fieldlink.plc.gateway")

    init() {
        restoreConfiguration()
    }

    static var defaultMode: GatewayConnectionMode {
        #if targetEnvironment(simulator)
        .simulator
        #else
        .liveNetwork
        #endif
    }

    var hasPairedGateway: Bool { pairedGateway != nil }

    var modeDescription: String {
        switch mode {
        case .simulator: "Simulator Mode"
        case .liveNetwork: "USB-C Ethernet (live discovery)"
        case .pairedGateway: pairedGateway?.displayName ?? "Paired Gateway"
        }
    }

    func activeClient() -> any GatewayClient {
        switch mode {
        case .pairedGateway:
            if let configuration = pairedGateway,
               let url = URL(string: configuration.baseURLString),
               let token = try? keychain.read(account: configuration.id.uuidString) {
                return HTTPGatewayClient(
                    baseURL: url,
                    authorizationToken: token,
                    certificatePinBase64: configuration.certificatePinBase64
                )
            }
            return LocalNetworkGatewayClient()
        case .liveNetwork:
            return LocalNetworkGatewayClient()
        case .simulator:
            return SimulatedGatewayClient()
        }
    }

    func activateLiveNetwork() -> any GatewayClient {
        mode = .liveNetwork
        UserDefaults.standard.set(mode.rawValue, forKey: "fieldlink.gateway.mode")
        return LocalNetworkGatewayClient()
    }

    func activateSimulator() -> any GatewayClient {
        mode = .simulator
        UserDefaults.standard.set(mode.rawValue, forKey: "fieldlink.gateway.mode")
        return SimulatedGatewayClient()
    }

    func activatePairedGateway() throws -> any GatewayClient {
        guard let configuration = pairedGateway,
              let token = try? keychain.read(account: configuration.id.uuidString),
              let url = URL(string: configuration.baseURLString) else {
            throw GatewayClientError.authenticationFailed("The paired gateway session has expired. Pair the gateway again.")
        }
        mode = .pairedGateway
        UserDefaults.standard.set(mode.rawValue, forKey: "fieldlink.gateway.mode")
        return HTTPGatewayClient(
            baseURL: url,
            authorizationToken: token,
            certificatePinBase64: configuration.certificatePinBase64
        )
    }

    func pair(
        displayName: String,
        baseURLString: String,
        pairingCode: String,
        certificatePinBase64: String
    ) async throws -> any GatewayClient {
        guard let baseURL = normalizedHTTPSURL(from: baseURLString) else {
            throw GatewayClientError.invalidGatewayURL
        }
        guard !pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatewayClientError.pairingRequired
        }
        guard Data(base64Encoded: certificatePinBase64) != nil else {
            throw GatewayClientError.invalidCertificatePin
        }

        let pairing = try await GatewayPairingClient.pair(
            baseURL: baseURL,
            code: pairingCode,
            certificatePinBase64: certificatePinBase64
        )
        guard pairing.certificatePinBase64 == certificatePinBase64 else {
            throw GatewayClientError.invalidCertificatePin
        }

        let configuration = PairedGatewayConfiguration(
            id: UUID(),
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? pairing.gateway.identifier : displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURLString: baseURL.absoluteString,
            certificatePinBase64: certificatePinBase64,
            gatewayInfo: pairing.gateway
        )
        try keychain.save(pairing.sessionToken, account: configuration.id.uuidString)
        save(configuration)
        pairedGateway = configuration
        mode = .pairedGateway
        UserDefaults.standard.set(mode.rawValue, forKey: "fieldlink.gateway.mode")

        return HTTPGatewayClient(
            baseURL: baseURL,
            authorizationToken: pairing.sessionToken,
            certificatePinBase64: certificatePinBase64
        )
    }

    func unpair() {
        if let pairedGateway {
            try? keychain.delete(account: pairedGateway.id.uuidString)
        }
        pairedGateway = nil
        UserDefaults.standard.removeObject(forKey: configurationKey)
        _ = activateLiveNetwork()
    }

    private func restoreConfiguration() {
        if let data = UserDefaults.standard.data(forKey: configurationKey),
           let configuration = try? JSONDecoder().decode(PairedGatewayConfiguration.self, from: data) {
            pairedGateway = configuration
        }

        let savedMode = UserDefaults.standard.string(forKey: "fieldlink.gateway.mode")
        if savedMode == GatewayConnectionMode.pairedGateway.rawValue,
           let pairedGateway,
           (try? keychain.read(account: pairedGateway.id.uuidString)) != nil {
            mode = .pairedGateway
            return
        }
        if savedMode == GatewayConnectionMode.simulator.rawValue {
            #if targetEnvironment(simulator)
            mode = .simulator
            #else
            mode = .liveNetwork
            #endif
            return
        }
        mode = GatewaySessionStore.defaultMode
    }

    private func save(_ configuration: PairedGatewayConfiguration) {
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: configurationKey)
        }
    }

    private func normalizedHTTPSURL(from value: String) -> URL? {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "https",
              components.host != nil else {
            return nil
        }
        if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        return components.url
    }
}

private struct GatewayPairingRequest: Encodable {
    let pairingCode: String
}

private struct GatewayPairingResponse: Decodable {
    let gateway: GatewayInfo
    let sessionToken: String
    let certificatePinBase64: String
}

private enum GatewayPairingClient {
    static func pair(baseURL: URL, code: String, certificatePinBase64: String) async throws -> GatewayPairingResponse {
        guard let url = URL(string: "v1/pair", relativeTo: baseURL) else {
            throw GatewayClientError.invalidGatewayURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(GatewayPairingRequest(pairingCode: code))

        let session = GatewayTransport.makePinnedSession(certificatePinBase64: certificatePinBase64)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GatewayClientError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw GatewayClientError.authenticationFailed("Pairing was rejected by the gateway.")
        }
        do {
            return try JSONDecoder().decode(GatewayPairingResponse.self, from: data)
        } catch {
            throw GatewayClientError.invalidResponse
        }
    }
}

private final class GatewayKeychain {
    private let service: String

    init(service: String) {
        self.service = service
    }

    func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        try? delete(account: account)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw GatewayClientError.keychainUnavailable
        }
    }

    func read(account: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw GatewayClientError.keychainUnavailable
        }
        return value
    }

    func delete(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GatewayClientError.keychainUnavailable
        }
    }
}
