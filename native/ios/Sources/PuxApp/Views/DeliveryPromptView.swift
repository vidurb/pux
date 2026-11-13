#if os(iOS)
import SwiftUI
import PuxCore

public struct DeliveryPromptView: View {
    @ObservedObject var permissions: NotificationPermissions
    @State private var dismissedRestrictions: Set<DeliveryRestriction> = []

    public init(permissions: NotificationPermissions) {
        self.permissions = permissions
    }

    public var body: some View {
        Group {
            if permissions.access != .allowed {
                notificationPrompt(permissions.access)
            } else if let restriction = activeRestriction {
                restrictionPrompt(restriction)
            }
        }
        .onAppear {
            loadDismissed()
        }
    }

    private var activeRestriction: DeliveryRestriction? {
        for restriction in DeliveryRestriction.allCases {
            if permissions.quietDelivery.active.contains(restriction) && !dismissedRestrictions.contains(restriction) {
                return restriction
            }
        }
        return nil
    }

    @ViewBuilder
    private func notificationPrompt(_ access: NotificationAccess) -> some View {
        let (title, bodyText, isWarning) = promptTexts(for: access)
        let color: Color = isWarning ? .orange : .red

        PromptCard(
            title: title,
            bodyText: bodyText,
            color: color,
            actionLabel: access == .notAsked ? "Allow notifications" : "Open settings",
            onAction: {
                if access == .notAsked {
                    Task { _ = await permissions.ask() }
                } else {
                    permissions.openSettings()
                }
            }
        )
    }

    private func promptTexts(for access: NotificationAccess) -> (String, String, Bool) {
        let lost = "Codes that arrive in the meantime are lost."
        switch access {
        case .notAsked:
            return (
                "Notifications are off",
                "pux can only show codes as notifications, so you won't see any until you allow them. \(lost)",
                false
            )
        case .quiet:
            return (
                "Codes may arrive without an alert",
                "pux's notifications are set to arrive quietly, with no banner or alert, so you could miss a code before it expires. Open settings and turn on alerts for pux.",
                true
            )
        case .off:
            return (
                "Notifications are off",
                "pux can only show codes as notifications, so you won't see any until you allow them. \(lost) Open settings and allow notifications for pux.",
                false
            )
        case .allowed:
            return ("", "", false)
        }
    }

    @ViewBuilder
    private func restrictionPrompt(_ restriction: DeliveryRestriction) -> some View {
        PromptCard(
            title: "Codes wait for your notification summary",
            bodyText: "iOS holds pux's notifications for your scheduled summary, so codes can expire before you see them. Open settings and choose Immediate Delivery for pux.",
            color: .orange,
            actionLabel: "Open settings",
            onAction: {
                permissions.openSettings()
            },
            onDismiss: {
                dismiss(restriction)
            }
        )
    }

    private func loadDismissed() {
        let names = RecordStore.shared.dismissedRestrictionPrompts()
        dismissedRestrictions = Set(names.compactMap(DeliveryRestriction.init(rawValue:)))
    }

    private func dismiss(_ restriction: DeliveryRestriction) {
        dismissedRestrictions.insert(restriction)
        try? RecordStore.shared.saveDismissedRestrictionPrompts(Set(dismissedRestrictions.map(\.rawValue)))
    }
}

private struct PromptCard: View {
    let title: String
    let bodyText: String
    let color: Color
    let actionLabel: String
    let onAction: () -> Void
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundColor(color)

            Text(bodyText)
                .font(.footnote)
                .foregroundColor(.primary)

            HStack {
                Spacer()
                if let onDismiss = onDismiss {
                    Button("Dismiss", action: onDismiss)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 8)
                }

                Button(actionLabel, action: onAction)
                    .font(.footnote.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(color)
                    .foregroundColor(.white)
                    .cornerRadius(6)
            }
        }
        .padding(12)
        .background(color.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color, lineWidth: 1)
        )
        .cornerRadius(8)
    }
}

#endif
