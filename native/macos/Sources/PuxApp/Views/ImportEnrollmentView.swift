import SwiftUI
import PuxCore

public struct ImportEnrollmentView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var controller: DeliveryController

    @State private var jsonText: String = ""
    @State private var errorMessage: String? = nil
    @State private var isProcessing: Bool = false
    @State private var pendingPayload: EnrollmentPayload? = nil
    @State private var showingConfirmServer: Bool = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Import enrollment")
                    .font(.title2)
                    .bold()
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isProcessing)
            }

            Text("Paste the enrollment JSON exported from a mobile device. Desktop clients receive OTP codes but do not generate keys.")
                .foregroundColor(.secondary)
                .font(.callout)

            TextEditor(text: $jsonText)
                .font(.system(.body, design: .monospaced))
                .border(Color.gray.opacity(0.3), width: 1)
                .frame(minHeight: 180)
                .accessibilityLabel("Enrollment JSON")
                .accessibilityHint("Paste the enrollment JSON exported from a mobile device")

            if isProcessing {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Import and connect") {
                    handleImport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing || jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 500, minHeight: 380)
        .sheet(isPresented: $showingConfirmServer) {
            if let payload = pendingPayload {
                ConfirmServerDialog(
                    serverUrl: controller.recordStore.effectiveServer(for: payload),
                    onConfirm: {
                        showingConfirmServer = false
                        commit(payload)
                    },
                    onCancel: {
                        showingConfirmServer = false
                        isProcessing = false
                    }
                )
            }
        }
    }

    private func handleImport() {
        errorMessage = nil
        isProcessing = true

        do {
            let payload = try EnrollmentPayload.parse(jsonString: jsonText.trimmingCharacters(in: .whitespacesAndNewlines))
            pendingPayload = payload
            showingConfirmServer = true
        } catch {
            errorMessage = error.localizedDescription
            isProcessing = false
        }
    }

    private func commit(_ payload: EnrollmentPayload) {
        Task {
            do {
                try await controller.commitEnrollment(payload)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isProcessing = false
            }
        }
    }
}
