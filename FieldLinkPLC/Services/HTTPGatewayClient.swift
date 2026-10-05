import Foundation
import Security

enum GatewayTransport {
    static func makePinnedSession(certificatePinBase64: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        let pin = Data(base64Encoded: certificatePinBase64) ?? Data()
        return URLSession(
            configuration: configuration,
            delegate: CertificatePinningDelegate(certificatePin: pin),
            delegateQueue: nil
        )
    }
}

/// Production transport for a paired FieldLink Gateway.
/// The endpoint must be reachable only on a paired, local control link.
actor HTTPGatewayClient: GatewayClient {
    private let baseURL: URL
    private let authorizationToken: String
    private let session: URLSession

    init(baseURL: URL, authorizationToken: String, certificatePinBase64: String) {
        self.baseURL = baseURL
        self.authorizationToken = authorizationToken
        self.session = GatewayTransport.makePinnedSession(certificatePinBase64: certificatePinBase64)
    }

    func connect() async throws -> GatewayStatus {
        let response: GatewayStatusResponse = try await request(path: "v1/status")
        guard response.state == "ready" else {
            return .fault(response.message ?? "Gateway did not enter a ready state.")
        }
        return .ready
    }

    func gatewayInfo() async throws -> GatewayInfo {
        try await request(path: "v1/gateway")
    }

    func startDiscovery(profile: NetworkProfile) async throws -> [PLCDevice] {
        let body = try JSONEncoder().encode(profile)
        return try await request(path: "v1/discovery", method: "POST", body: body)
    }

    func applyAddressChange(_ requestToApply: AddressChangeRequest) async throws -> CommissioningEvent {
        let body = try JSONEncoder().encode(requestToApply)
        return try await request(path: "v1/address-changes", method: "POST", body: body)
    }

    func fetchAuditTrail() async throws -> [CommissioningEvent] {
        try await request(path: "v1/audit")
    }

    func lastDiscoveryDebug() async -> DiscoveryDebugReport? {
        nil
    }

    private func request<Response: Decodable>(path: String, method: String = "GET", body: Data? = nil) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw GatewayClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout(for: path)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GatewayClientError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw gatewayError(statusCode: httpResponse.statusCode, data: data)
        }

        do {
            return try makeDecoder().decode(Response.self, from: data)
        } catch {
            throw GatewayClientError.invalidResponse
        }
    }

    private func timeout(for path: String) -> TimeInterval {
        if path.contains("address-changes") { return 90 }
        if path.contains("discovery") { return 30 }
        return 15
    }

    private func gatewayError(statusCode: Int, data: Data) -> GatewayClientError {
        let errorResponse = try? makeDecoder().decode(GatewayAPIErrorResponse.self, from: data)
        let message = errorResponse?.message ?? "The gateway rejected the request (HTTP \(statusCode))."

        switch statusCode {
        case 401, 403:
            return .authenticationFailed(message)
        case 409:
            return .conflict(message)
        case 422:
            return .unsupportedOperation(message)
        default:
            return .gatewayFault(message)
        }
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standardFormatter = ISO8601DateFormatter()
            standardFormatter.formatOptions = [.withInternetDateTime]

            if let date = fractionalFormatter.date(from: value) ?? standardFormatter.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO-8601 timestamp.")
        }
        return decoder
    }
}

private struct GatewayStatusResponse: Decodable {
    let state: String
    let message: String?
}

private struct GatewayAPIErrorResponse: Decodable {
    let code: String?
    let message: String
}

final class CertificatePinningDelegate: NSObject, URLSessionDelegate {
    private let certificatePin: Data

    init(certificatePin: Data) {
        self.certificatePin = certificatePin
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              !certificatePin.isEmpty else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let presentedCertificate = SecCertificateCopyData(certificate) as Data
        guard presentedCertificate == certificatePin else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
