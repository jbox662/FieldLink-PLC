import Foundation

enum CommissioningEventKind: String, Codable, Hashable {
    case gatewayConnected = "Gateway connected"
    case discoveryCompleted = "Discovery completed"
    case addressAssigned = "Address assigned"
    case staticEnabled = "Static mode enabled"
    case validationCompleted = "Validation completed"

    var symbol: String {
        switch self {
        case .gatewayConnected: "cable.connector"
        case .discoveryCompleted: "radar"
        case .addressAssigned: "arrow.left.arrow.right"
        case .staticEnabled: "lock.fill"
        case .validationCompleted: "checkmark.shield.fill"
        }
    }
}

struct CommissioningEvent: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let kind: CommissioningEventKind
    let deviceName: String?
    let detail: String
    let successful: Bool

    init(kind: CommissioningEventKind, deviceName: String? = nil, detail: String, successful: Bool = true) {
        self.id = UUID()
        self.timestamp = Date()
        self.kind = kind
        self.deviceName = deviceName
        self.detail = detail
        self.successful = successful
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
