import SwiftUI

@main
struct FieldLinkPLCApp: App {
    @StateObject private var sessionStore: GatewaySessionStore
    @StateObject private var commissioning: CommissioningViewModel

    init() {
        let store = GatewaySessionStore()
        _sessionStore = StateObject(wrappedValue: store)
        _commissioning = StateObject(wrappedValue: CommissioningViewModel(gateway: store.activeClient()))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(commissioning)
                .environmentObject(sessionStore)
        }
    }
}
