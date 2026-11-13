#if os(iOS)
#if canImport(UIKit)
import SwiftUI
import PuxCore

public struct ImportEnrollmentScreen: View {
    @State private var textInput = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showServerConfirmation = false
    @State private var serverToConfirm = ""
    @State private var pendingPayload: [String: Any]?

    let onEnrolled: () -> Void

    public init(onEnrolled: @escaping () -> Void) {
        self.onEnrolled = onEnrolled
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Paste the enrollment JSON copied from another device:")
                    .font(.body)

                TextEditor(text: $textInput)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(PuxTheme.border, lineWidth: 1)
                    )
                    .frame(minHeight: 140, idealHeight: 180, maxHeight: 240)
                    .accessibilityLabel(EnrollmentImportAccessibility.editorLabel)
                    .accessibilityHint(EnrollmentImportAccessibility.editorHint)
                    .accessibilityIdentifier(EnrollmentImportAccessibility.editorIdentifier)

                if isProcessing {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding(.vertical, 8)
                        Spacer()
                    }
                }

                Button(action: handleImport) {
                    Text("Import and connect")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(PuxTheme.primary)
                        .foregroundColor(PuxTheme.onPrimary)
                        .cornerRadius(12)
                }
                .disabled(isProcessing || textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let error = errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.red)
                }

                Spacer(minLength: 20)
            }
            .padding(24)
        }
        .background(PuxTheme.background.ignoresSafeArea())
        .navigationTitle("Import enrollment")
        .confirmServerAlert(
            isPresented: $showServerConfirmation,
            serverUrl: serverToConfirm,
            onConfirm: {
                if let payload = pendingPayload {
                    commitSave(payload: payload)
                }
            },
            onCancel: {
                isProcessing = false
                pendingPayload = nil
            }
        )
    }

    private func handleImport() {
        guard !isProcessing else { return }
        isProcessing = true
        errorMessage = nil

        do {
            let payload = try RecordStore.shared.parseQr(textInput)
            let server = try RecordStore.shared.enrollmentServer(payload)

            if server != RecordStore.shared.serverUrl {
                pendingPayload = payload
                serverToConfirm = server
                showServerConfirmation = true
            } else {
                commitSave(payload: payload)
            }
        } catch {
            isProcessing = false
            errorMessage = error.localizedDescription
        }
    }

    private func commitSave(payload: [String: Any]) {
        Task {
            do {
                try RecordStore.shared.saveEnrollment(payload)
                await DeliveryController.shared.start()
                isProcessing = false
                onEnrolled()
            } catch {
                isProcessing = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
#endif

#endif
