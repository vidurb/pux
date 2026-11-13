#if os(iOS)
import SwiftUI
import PuxCore

public struct CreateRelayScreen: View {
    @State private var isCommitting = false
    @State private var errorMessage: String?
    let onEnrolled: () -> Void

    public init(onEnrolled: @escaping () -> Void) {
        self.onEnrolled = onEnrolled
    }

    public var body: some View {
        VStack(spacing: 24) {
            Text("A new encryption keypair will be generated on this device. Only the public key is sent to the server.")
                .font(.body)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isCommitting {
                ProgressView()
                    .padding()
            }

            Button(action: handleCreateRelay) {
                Text("Generate keys and create relay")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(PuxTheme.primary)
                    .foregroundColor(PuxTheme.onPrimary)
                    .cornerRadius(12)
            }
            .disabled(isCommitting)

            if let error = errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(24)
        .navigationTitle("Create relay")
        .navigationBarBackButtonHidden(isCommitting)
    }

    private func handleCreateRelay() {
        guard !isCommitting else { return }
        isCommitting = true
        errorMessage = nil

        Task {
            do {
                let keys = try CryptoService.shared.generateKeyPair()
                let record = try await ApiClient.shared.createRecord(publicKey: keys.publicKey)

                do {
                    try RecordStore.shared.saveEnrollment([
                        "record_id": record.recordId,
                        "private_key": keys.privateKey,
                        "public_key": keys.publicKey,
                        "inbox": record.inboxAddress,
                        "server": RecordStore.shared.serverUrl
                    ])
                } catch {
                    // This device was the only holder of the new relay's ID.
                    // Clean up on server if saving locally failed.
                    try? await ApiClient.shared.deleteRecord(recordId: record.recordId)
                    throw error
                }

                await DeliveryController.shared.start()
                isCommitting = false
                onEnrolled()
            } catch {
                isCommitting = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

#endif
