import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: CommissioningViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    quickActions
                    safetyCard
                    recentDevices
                }
                .padding()
            }
            .background(Color.fieldSurface.ignoresSafeArea())
            .navigationTitle("FieldLink PLC")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    StatusPill(status: model.gatewayStatus)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Commission with confidence.")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                    Text("Discover EtherNet/IP devices on the USB-C Ethernet segment. They do not need to match this phone’s subnet. Wi-Fi is not used.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                }
                Spacer()
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.fieldTeal)
            }

            if let gateway = model.gatewayInfo {
                Label {
                    Text("\(gateway.identifier) · \(gateway.linkSpeed)")
                } icon: {
                    Image(systemName: "cable.connector")
                }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            } else {
                Label("Connect a gateway to begin", systemImage: "cable.connector")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(20)
        .background(Color.fieldNavy, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var quickActions: some View {
        SectionCard(title: "Start a field task", symbol: "wrench.and.screwdriver") {
            HStack(spacing: 12) {
                Button {
                    Task { await model.discoverDevices() }
                } label: {
                    Label {
                        Text(model.isWorking ? "Working…" : "Discover devices")
                    } icon: {
                        Image(systemName: "radar")
                    }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.fieldTeal)
                .disabled(model.isWorking || !model.isGatewayReady)

                Button {
                    Task { await model.connectGateway() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(minWidth: 24)
                }
                .buttonStyle(.bordered)
                .disabled(model.isWorking)
                .accessibilityLabel("Reconnect gateway")
            }

            Text("Active profile: \(model.activeProfile.name) · \(model.activeProfile.summary)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var safetyCard: some View {
        SectionCard(title: "Commissioning safeguard", symbol: "shield.lefthalf.filled") {
            Text("FieldLink defaults to read-only discovery. Address changes require matching device identity, a displayed before/after review, and an explicit acknowledgement.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Label("Use an isolated commissioning segment whenever possible.", systemImage: "checkmark.seal.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.green)
        }
    }

    private var recentDevices: some View {
        SectionCard(title: "Latest devices", symbol: "cpu") {
            if model.devices.isEmpty {
                ContentUnavailableView {
                    Label("No devices discovered", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("Run discovery after the gateway shows ready.")
                }
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(model.devices.prefix(3)) { device in
                    NavigationLink {
                        DeviceDetailView(deviceID: device.id)
                    } label: {
                    HStack(spacing: 12) {
                        Image(systemName: device.primaryProtocol.symbol)
                            .foregroundStyle(.fieldTeal)
                            .frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(device.name).font(.subheadline.weight(.semibold))
                            Text("\(device.displayedIPAddress) · \(device.product)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(device.addressingState.rawValue)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.fieldInk)
                    }
                    }
                    if device.id != model.devices.prefix(3).last?.id { Divider() }
                }
            }
        }
    }
}
