import SwiftUI
import PuxCore

public struct HeldCodesView: View {
    @EnvironmentObject var controller: DeliveryController
    @State private var copiedId: String? = nil

    public init() {}

    public var body: some View {
        if !controller.heldDeliveries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Codes that may not have appeared")
                    .font(.subheadline)
                    .bold()

                Text("pux couldn't confirm these reached you as notifications. They are removed once they do, or when they expire, and are never saved on this device.")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                ForEach(controller.heldDeliveries) { delivery in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(delivery.notification.title)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(delivery.notification.body)
                                .font(.system(.body, design: .monospaced))
                                .bold()
                                .textSelection(.enabled)
                        }

                        Spacer()

                        if let code = delivery.notification.code {
                            Button(copiedId == delivery.deliveryId ? "Copied" : "Copy code") {
                                SensitiveClipboard.shared.copy(code)
                                copiedId = delivery.deliveryId
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    if copiedId == delivery.deliveryId {
                                        copiedId = nil
                                    }
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
                }
            }
            .padding(12)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange, lineWidth: 1)
            )
        }
    }
}
