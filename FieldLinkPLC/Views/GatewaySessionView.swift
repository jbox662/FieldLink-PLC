import SwiftUI

struct GatewaySessionView: View {
    @EnvironmentObject private var model: CommissioningViewModel
    @EnvironmentObject private var sessionStore: GatewaySessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var baseURL = "https://fieldlink-gateway.local/"
    @State private var pairingCode = ""
    @State private var certificatePin = ""
    @State private var isPairing = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Live discovery") {
                Text("Plug a USB-C Ethernet adapter into this iPhone for read-only EtherNet/IP work. Unknown-IP broadcast discovery runs only after Apple approves and provisions Multicast Networking for this signed build. Wi-Fi is never used for PLC discovery.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Use USB-C Ethernet") {
                    let client = sessionStore.activateLiveNetwork()
                    Task {
                        await model.configureGateway(client)
                        dismiss()
                    }
                }
                .disabled(sessionStore.mode == .liveNetwork && model.isGatewayReady)
            }

            Section("Simulator") {
                Text("Simulator Mode is the default for Xcode Simulator. It runs realistic discovery and commissioning scenarios without touching a network.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Use Simulator Mode") {
                    let client = sessionStore.activateSimulator()
                    Task {
                        await model.configureGateway(client)
                        dismiss()
                    }
                }
                .disabled(sessionStore.mode == .simulator && model.isGatewayReady)
            }

            if sessionStore.hasPairedGateway {
                Section("Saved physical gateway") {
                    Text(sessionStore.pairedGateway?.displayName ?? "Paired gateway")
                    Button("Connect saved gateway") {
                        do {
                            let client = try sessionStore.activatePairedGateway()
                            Task {
                                await model.configureGateway(client)
                                dismiss()
                            }
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    Button("Forget paired gateway", role: .destructive) {
                        sessionStore.unpair()
                    }
                }
            }

            Section {
                Text("Pair only while physically connected to or standing at the gateway. The pairing QR/card provides the HTTPS address, one-time code, and certificate pin.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Gateway name (optional)", text: $displayName)
                TextField("HTTPS gateway URL", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                SecureField("One-time pairing code", text: $pairingCode)
                SecureField("Gateway certificate pin (Base64)", text: $certificatePin)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button(isPairing ? "Pairing…" : "Pair gateway") {
                    pairGateway()
                }
                .disabled(isPairing || baseURL.isEmpty || pairingCode.isEmpty || certificatePin.isEmpty)
            } header: {
                Text("Pair a physical FieldLink Gateway")
            } footer: {
                Text("Pairing uses the certificate pin immediately for TLS. The app stores only the resulting short-lived session token in Keychain. The pairing code is not retained.")
            }
        }
        .navigationTitle("Gateway session")
        .alert("Pairing failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown pairing error.")
        }
    }

    private func pairGateway() {
        isPairing = true
        Task {
            defer { isPairing = false }
            do {
                let client = try await sessionStore.pair(
                    displayName: displayName,
                    baseURLString: baseURL,
                    pairingCode: pairingCode,
                    certificatePinBase64: certificatePin
                )
                await model.configureGateway(client)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
