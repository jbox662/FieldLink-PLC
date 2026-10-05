import SwiftUI

struct GatewayView: View {
    @EnvironmentObject private var model: CommissioningViewModel
    @EnvironmentObject private var sessionStore: GatewaySessionStore

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.gatewayStatus.title)
                                .font(.headline)
                            Text(model.gatewayStatus.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusPill(status: model.gatewayStatus)
                    }

                    LabeledContent("Session", value: sessionStore.modeDescription)

                    NavigationLink {
                        GatewaySessionView()
                    } label: {
                        Label("Manage gateway session", systemImage: "link.badge.plus")
                    }

                    NavigationLink {
                        DiscoveryDebugView()
                    } label: {
                        Label("Discovery debug", systemImage: "ant.fill")
                    }

                    Button {
                        Task { await model.connectGateway() }
                    } label: {
                        Label("Reconnect gateway", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isWorking)
                }

                if let gateway = model.gatewayInfo {
                    Section("Paired gateway") {
                        LabeledContent("Name", value: gateway.identifier)
                        LabeledContent("Serial number", value: gateway.serialNumber)
                        LabeledContent("Firmware", value: gateway.firmwareVersion)
                        LabeledContent("Ethernet link", value: gateway.linkSpeed)
                        if gateway.simulatorMode {
                            Label("Simulator mode is active", systemImage: "iphone.gen3")
                                .foregroundStyle(.fieldOrange)
                        } else if gateway.identifier == "USB-C Ethernet" {
                            Label("Live EtherNet/IP discovery on USB-C Ethernet", systemImage: "cable.connector")
                                .foregroundStyle(.fieldTeal)
                        }
                    }
                }

                Section("Gateway capabilities") {
                    ForEach(visibleCapabilities, id: \.self) { capability in
                        Label {
                            Text(capability)
                        } icon: {
                            Image(systemName: "checkmark.seal.fill")
                        }
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                }

                Section("Recent activity") {
                    if model.events.isEmpty {
                        Text("No activity recorded yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.events.prefix(8)) { event in
                            ActivityRow(event: event)
                        }
                    }

                    NavigationLink {
                        ActivityLogView()
                    } label: {
                        Label("View all activity", systemImage: "list.bullet.rectangle")
                    }

                    ShareLink(item: model.auditExportText()) {
                        Label("Export activity", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.events.isEmpty)
                }
            }
            .navigationTitle("Gateway")
        }
    }

    private var visibleCapabilities: [String] {
        if model.gatewayInfo?.identifier == "USB-C Ethernet" {
            return [
                "Read-only EtherNet/IP ListIdentity broadcast after Apple approves and provisions Multicast Networking",
                "Known-address EtherNet/IP traffic can stay pinned to USB-C Ethernet",
                "Unknown/no-IP and raw-L2 PLC discovery requires a FieldLink Gateway",
                "Read-only identity (no address writes from the phone)",
                "Local commissioning activity log"
            ]
        }
        return GatewayCapability.allCases.map(\.rawValue)
    }
}

struct DiscoveryDebugView: View {
    @EnvironmentObject private var model: CommissioningViewModel

    var body: some View {
        List {
            Section {
                Button {
                    Task { await model.discoverDevices() }
                } label: {
                    Label(model.isWorking ? "Probing…" : "Run discovery now", systemImage: "radar")
                }
                .disabled(model.isWorking || !model.isGatewayReady)

                ShareLink(item: model.debugExportText()) {
                    Label("Share debug log", systemImage: "square.and.arrow.up")
                }
            }

            if let report = model.discoveryDebug {
                Section("USB-C Ethernet") {
                    LabeledContent("Interface", value: report.interfaceName)
                    LabeledContent("IPv4", value: report.interfaceAddress)
                    LabeledContent("Mask", value: report.netmask)
                    LabeledContent("Link", value: report.linkDescription.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "· ", with: ""))
                    LabeledContent("Captured", value: report.capturedAt.formatted(date: .omitted, time: .standard))
                }
                Section("Discovery capability") {
                    LabeledContent("Multicast capability", value: report.multicastEntitlementPresent ? "Present in signed build" : "Unavailable in signed build")
                    if let blockedReason = report.blockedReason {
                        Text(blockedReason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Section("UDP 44818") {
                    LabeledContent("Unicast sent", value: "\(report.unicastsSent)")
                    LabeledContent("Broadcast sent", value: "\(report.broadcastsSent)")
                    LabeledContent("Send failures", value: "\(report.sendFailures)")
                    LabeledContent("Datagrams received", value: "\(report.datagramsReceived)")
                    if let sourcePort = report.sourcePort {
                        LabeledContent("Source port", value: "\(sourcePort) (ephemeral)")
                    }
                    if !report.broadcastTargets.isEmpty {
                        LabeledContent("Targets", value: report.broadcastTargets.joined(separator: ", "))
                    }
                    if let error = report.lastSendError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if !report.socketSetupErrors.isEmpty {
                        ForEach(report.socketSetupErrors, id: \.self) { error in
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                Section("Devices parsed") {
                    if report.deviceNames.isEmpty {
                        Text("None")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(report.deviceNames, id: \.self) { name in
                            Text(name)
                        }
                    }
                }
                Section("Received packets") {
                    if report.packets.isEmpty {
                        Text("No EtherNet/IP identity reply was received. This is inconclusive: the PLC may have no IP, use another protocol, be silent, or have a link/configuration problem.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(report.packets) { packet in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(packet.source)
                                    .font(.subheadline.weight(.semibold))
                                Text(packet.parsedName ?? "Not a ListIdentity body")
                                    .font(.caption)
                                    .foregroundStyle(packet.parsedName == nil ? .orange : .fieldTeal)
                                Text("\(packet.byteCount) bytes  \(packet.hexPrefix)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            } else {
                Section {
                    Text("Run discovery to capture send/receive counts, Ethernet link state, and any UDP replies.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Discovery debug")
    }
}

struct ActivityLogView: View {
    @EnvironmentObject private var model: CommissioningViewModel

    var body: some View {
        List {
            if model.events.isEmpty {
                ContentUnavailableView {
                    Label("No activity yet", systemImage: "list.bullet.clipboard")
                } description: {
                    Text("Gateway connection, discovery, and address changes appear here.")
                }
            } else {
                ForEach(model.events) { event in
                    ActivityRow(event: event)
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: model.auditExportText()) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(model.events.isEmpty)
                .accessibilityLabel("Export activity")
            }
        }
    }
}

struct ActivityRow: View {
    let event: CommissioningEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.kind.symbol)
                .foregroundStyle(event.successful ? .fieldTeal : .red)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.kind.rawValue)
                    .font(.subheadline.weight(.semibold))
                if let deviceName = event.deviceName {
                    Text(deviceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(event.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(event.timestamp.fieldLinkFormatted)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
