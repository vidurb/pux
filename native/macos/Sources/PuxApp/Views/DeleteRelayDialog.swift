import SwiftUI

public struct DeleteRelayDialog: View {
    public let onConfirm: () async throws -> Void
    public let onCancel: () -> Void

    @State private var input: String = ""
    @State private var isDeleting: Bool = false
    @State private var errorMessage: String? = nil

    public init(onConfirm: @escaping () async throws -> Void, onCancel: @escaping () -> Void) {
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    private var isConfirmed: Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "delete"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete relay everywhere?")
                .font(.headline)

            Text("This deletes the relay from the server. Every device on it stops receiving codes, the inbox address stops working and pending codes are discarded. This cannot be undone.")
                .font(.callout)
                .foregroundColor(.secondary)

            if let error = errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundColor(.red)
            }

            Text("Type \"delete\" to confirm:")
                .font(.callout)

            TextField("delete", text: $input)
                .textFieldStyle(.roundedBorder)
                .disabled(isDeleting)
                .accessibilityLabel("Type delete to confirm")

            HStack {
                if isDeleting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Deleting from server…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isDeleting)

                Button("Delete everywhere") {
                    guard isConfirmed && !isDeleting else { return }
                    isDeleting = true
                    errorMessage = nil
                    Task {
                        do {
                            try await onConfirm()
                        } catch {
                            isDeleting = false
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!isConfirmed || isDeleting)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
