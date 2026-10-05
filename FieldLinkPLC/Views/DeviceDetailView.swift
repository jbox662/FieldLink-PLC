import SwiftUI

struct DeviceDetailView: View {
    @EnvironmentObject private var model: CommissioningViewModel
    let deviceID: UUID
    @State private var showAddressChange = false

    var body: some View {
        Group {
            if let device = model.device(with: deviceID) {
                List {
                    Section {
                        HStack(spacing: 14) {
                            Image(systemName: device.primaryProtocol.symbol)
                                .font(.system(size: 34))
                                .foregroundStyle(.fieldTeal)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name)
                                    .font(.headline)
                                Text(device.product)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }

                    Section("Identity") {
                        DetailRow(label: "Vendor", value: device.vendor)
                        DetailRow(label: "Revision", value: device.revision)
                        DetailRow(label: "Serial", value: device.serialNumber)
                        DetailRow(label: "MAC", value: device.macAddress)
                    }

                    Section("Network") {
                        DetailRow(label: "IP address", value: device.displayedIPAddress)
                        DetailRow(label: "Subnet mask", value: device.subnetMask ?? "Not assigned")
                        DetailRow(label: "Gateway", value: device.gatewayAddress ?? "Not assigned")
                        DetailRow(label: "Addressing", value: device.addressingState.rawValue)
                        DetailRow(label: "Link", value: device.linkStatus.rawValue)
                    }

                    Section("Discovery evidence") {
                        ForEach(device.discoveryProtocols) { protocolName in
                            Label {
                                Text(protocolName.rawValue)
                            } icon: {
                                Image(systemName: protocolName.symbol)
                            }
                        }
                        Text("Last seen \(device.lastSeen.fieldLinkFormatted)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        Button {
                            showAddressChange = true
                        } label: {
                            Label {
                                Text(device.needsAddressAssignment ? "Assign IP address" : "Change IP address")
                            } icon: {
                                Image(systemName: "arrow.left.arrow.right")
                            }
                        }
                        .disabled(!device.isAddressable || !model.isGatewayReady || model.isWorking)
                    } footer: {
                        Text(
                            device.needsAddressAssignment
                                ? "Unconfigured and BOOTP devices are assigned by the FieldLink Gateway after identity review. The gateway will not respond until you confirm the target."
                                : "Changes are sent by the FieldLink Gateway. Review target identity, current value, and proposed value before applying."
                        )
                    }
                }
                .navigationTitle(device.name)
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showAddressChange) {
                    AddressChangeSheet(device: device, profile: model.activeProfile) {
                        showAddressChange = false
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Device unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Run discovery again to refresh the gateway inventory.")
                }
            }
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
        } label: {
            Text(label)
        }
    }
}

struct AddressChangeSheet: View {
    @EnvironmentObject private var model: CommissioningViewModel
    @Environment(\.dismiss) private var dismiss
    let device: PLCDevice
    let onApplied: () -> Void
    @State private var address: String
    @State private var subnetMask: String
    @State private var gateway: String
    @State private var makeStatic = true
    @State private var acknowledged = false
    @State private var reviewRequest: AddressChangeRequest?

    init(device: PLCDevice, profile: NetworkProfile, onApplied: @escaping () -> Void) {
        self.device = device
        self.onApplied = onApplied
        _address = State(initialValue: device.ipAddress ?? "")
        _subnetMask = State(initialValue: device.subnetMask ?? profile.subnetMask)
        _gateway = State(initialValue: device.gatewayAddress ?? profile.gatewayAddress)
    }

    private var inputIsValid: Bool {
        IPv4Validator.isValid(address) && IPv4Validator.isValid(subnetMask) && IPv4Validator.isValid(gateway)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Target device") {
                    LabeledContent("Device", value: device.name)
                    LabeledContent("MAC", value: device.macAddress)
                    LabeledContent("Current IP", value: device.displayedIPAddress)
                    LabeledContent("Addressing", value: device.addressingState.rawValue)
                }

                Section("Proposed network settings") {
                    TextField("IP address", text: $address)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                    TextField("Subnet mask", text: $subnetMask)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                    TextField("Gateway address", text: $gateway)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                    Toggle("Make address static after assignment", isOn: $makeStatic)
                }

                Section {
                    Toggle("I verified this is the intended device and this address is approved for the active network.", isOn: $acknowledged)
                } header: {
                    Text("Safety acknowledgement")
                } footer: {
                    Text("The app will show a final before/after review before any change is sent to the gateway.")
                }
            }
            .navigationTitle(device.needsAddressAssignment ? "Assign IP address" : "Change IP address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") {
                        reviewRequest = AddressChangeRequest(
                            device: device,
                            newIPAddress: address,
                            subnetMask: subnetMask,
                            gatewayAddress: gateway,
                            profileName: model.activeProfile.name,
                            makeStatic: makeStatic,
                            technicianAcknowledged: acknowledged
                        )
                    }
                    .disabled(!inputIsValid || !acknowledged)
                }
            }
            .sheet(item: $reviewRequest) { request in
                CommissioningReviewSheet(request: request) {
                    onApplied()
                    dismiss()
                }
            }
        }
    }
}

struct CommissioningReviewSheet: View {
    @EnvironmentObject private var model: CommissioningViewModel
    @Environment(\.dismiss) private var dismiss
    let request: AddressChangeRequest
    let onApplied: () -> Void
    @State private var finalAcknowledgement = false

    private var conflictingDevice: PLCDevice? {
        model.conflictingDevice(for: request)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Confirm the target") {
                    LabeledContent("Device", value: request.deviceName)
                    LabeledContent("Current address", value: request.currentIPAddress ?? "Unassigned")
                    LabeledContent("Proposed address", value: request.newIPAddress)
                    LabeledContent("Subnet mask", value: request.subnetMask)
                    LabeledContent("Gateway", value: request.gatewayAddress)
                    LabeledContent("Mode", value: request.makeStatic ? "Static after assignment" : "DHCP")
                    LabeledContent("Network profile", value: request.profileName)
                }

                if let conflictingDevice {
                    Section {
                        Label {
                            Text("\(request.newIPAddress) is already used by \(conflictingDevice.name).")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.red)
                        .font(.subheadline.weight(.semibold))
                    }
                }

                Section("Final safeguard") {
                    Toggle("I understand this action can change communications to the target device.", isOn: $finalAcknowledgement)
                }
            }
            .navigationTitle("Review change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                        .disabled(model.isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isWorking {
                        ProgressView()
                    } else {
                        Button("Apply change", role: .destructive) {
                            Task {
                                let didApply = await model.applyAddressChange(request)
                                if didApply {
                                    onApplied()
                                    dismiss()
                                }
                            }
                        }
                        .disabled(!finalAcknowledgement || conflictingDevice != nil)
                    }
                }
            }
        }
    }
}
