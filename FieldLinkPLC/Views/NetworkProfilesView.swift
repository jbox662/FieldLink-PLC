import SwiftUI

struct NetworkProfilesView: View {
    @EnvironmentObject private var model: CommissioningViewModel
    @State private var editorProfile: NetworkProfile?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Profiles belong to the FieldLink Gateway. They define the gateway’s commissioning interface, subnet, and gateway values used in an approved assignment workflow.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Saved profiles") {
                    ForEach(model.profiles) { profile in
                        HStack(spacing: 12) {
                            Button {
                                model.selectProfile(profile.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: profile.id == model.selectedProfileID ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(profile.id == model.selectedProfileID ? .fieldTeal : .secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.name)
                                            .foregroundStyle(.primary)
                                        Text(profile.summary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)

                            Button {
                                editorProfile = profile
                            } label: {
                                Image(systemName: "pencil")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Edit \(profile.name)")
                        }
                    }
                    .onDelete(perform: deleteProfiles)
                }

                Section("Active profile details") {
                    LabeledContent("IP address", value: model.activeProfile.interfaceIPAddress)
                    LabeledContent("Subnet mask", value: model.activeProfile.subnetMask)
                    LabeledContent("Gateway", value: model.activeProfile.gatewayAddress)
                    Text(model.activeProfile.notes)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Network profiles")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editorProfile = NetworkProfile(
                            name: "New commissioning profile",
                            interfaceIPAddress: model.activeProfile.interfaceIPAddress,
                            subnetMask: model.activeProfile.subnetMask,
                            gatewayAddress: model.activeProfile.gatewayAddress,
                            notes: ""
                        )
                    } label: {
                        Label("Add profile", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editorProfile) { profile in
                NetworkProfileEditorSheet(profile: profile)
            }
        }
    }

    private func deleteProfiles(at offsets: IndexSet) {
        for index in offsets {
            model.deleteProfile(model.profiles[index])
        }
    }
}

private struct NetworkProfileEditorSheet: View {
    @EnvironmentObject private var model: CommissioningViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var profile: NetworkProfile

    init(profile: NetworkProfile) {
        _profile = State(initialValue: profile)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $profile.name)
                    TextField("Interface IP address", text: $profile.interfaceIPAddress)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                    TextField("Subnet mask", text: $profile.subnetMask)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                    TextField("Gateway address", text: $profile.gatewayAddress)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                    TextField("Notes", text: $profile.notes, axis: .vertical)
                        .lineLimit(3 ... 6)
                }
            }
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.upsertProfile(profile)
                        dismiss()
                    }
                    .disabled(!profile.isValid)
                }
            }
        }
    }
}
