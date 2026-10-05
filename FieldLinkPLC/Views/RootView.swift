import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: CommissioningViewModel
    @EnvironmentObject private var sessionStore: GatewaySessionStore

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Overview", systemImage: "rectangle.3.group.fill") }

            DevicesView()
                .tabItem { Label("Devices", systemImage: "cpu") }

            NetworkProfilesView()
                .tabItem { Label("Profiles", systemImage: "network") }

            GatewayView()
                .tabItem { Label("Gateway", systemImage: "cable.connector") }
        }
        .tint(.fieldTeal)
        .task { await model.configureGateway(sessionStore.activeClient()) }
        .alert(item: $model.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}
