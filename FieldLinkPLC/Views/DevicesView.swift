import SwiftUI

struct DevicesView: View {
    @EnvironmentObject private var model: CommissioningViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.activeProfile.name)
                                .font(.subheadline.weight(.semibold))
                            Text("\(model.activeProfile.summary) · \(model.devices.count) discovered")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "network")
                            .foregroundStyle(.fieldTeal)
                    }
                }

                if model.devices.isEmpty {
                    ContentUnavailableView {
                        Label("No devices yet", systemImage: "radar")
                    } description: {
                        Text("Run Discover, then open Gateway → Discovery debug if the list stays empty.")
                    }
                    NavigationLink {
                        DiscoveryDebugView()
                    } label: {
                        Label("Open discovery debug", systemImage: "ant.fill")
                    }
                } else {
                    Section("Discovered devices") {
                        ForEach(model.devices) { device in
                            NavigationLink {
                                DeviceDetailView(deviceID: device.id)
                            } label: {
                                DeviceRow(device: device)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Devices")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.discoverDevices() }
                    } label: {
                        if model.isWorking {
                            ProgressView()
                        } else {
                            Label("Discover", systemImage: "radar")
                        }
                    }
                    .disabled(model.isWorking || !model.isGatewayReady)
                }
            }
            .refreshable { await model.discoverDevices() }
        }
    }
}

struct DeviceRow: View {
    let device: PLCDevice

    private var statusColor: Color {
        switch device.addressingState {
        case .staticAddress: .green
        case .dhcp: .fieldTeal
        case .bootp, .unconfigured: .fieldOrange
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.primaryProtocol.symbol)
                .font(.title3)
                .foregroundStyle(.fieldTeal)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.subheadline.weight(.semibold))
                Text("\(device.displayedIPAddress) · \(device.vendor)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Text(device.addressingState.rawValue)
                .font(.caption2.weight(.bold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(statusColor.opacity(0.12), in: Capsule())
        }
        .accessibilityElement(children: .combine)
    }
}
