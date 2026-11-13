#if os(iOS)
import SwiftUI

public struct DeleteRelayDialog: View {
    @Binding var isPresented: Bool
    let onConfirmDelete: () -> Void

    @State private var input: String = ""

    public var body: some View {
        PuxStackNavigation {
            VStack(alignment: .leading, spacing: 16) {
                Text("This deletes the relay from the server. Every device on it stops receiving codes, the inbox address stops working and pending codes are discarded. This cannot be undone.")
                    .font(.body)

                Text("Type \"delete\" to confirm.")
                    .font(.subheadline.weight(.medium))

                TextField("", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .accessibilityLabel("Type delete to confirm relay deletion")

                Spacer()

                Button(action: {
                    isPresented = false
                    onConfirmDelete()
                }) {
                    Text("Delete everywhere")
                        .font(.body.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isConfirmed ? Color.red : Color.gray.opacity(0.3))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .disabled(!isConfirmed)
            }
            .padding(24)
            .navigationTitle("Delete relay everywhere?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
        }
    }

    private var isConfirmed: Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "delete"
    }
}

#endif
