#if os(iOS)
import SwiftUI
import PuxCore

public struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isEnrolled = RecordStore.shared.isEnrolled()
    @State private var storageError: String?
    @State private var intent: RemovalIntent?
    @State private var journalError: String?
    @State private var busy = false
    @State private var recoveryError: String?
    @State private var showUncertainRegistrationWarning = false
    @State private var uncertainWarningJournalError: String?

    public init() {}

    public var body: some View {
        Group {
            if let storageError = storageError {
                VStack(spacing: 16) {
                    Text("Secure storage is unavailable").font(.headline)
                    Text(storageError).foregroundColor(.secondary)
                    Button("Try again") { refresh() }
                }.padding()
            } else if let journalError = journalError {
                VStack(spacing: 16) {
                    Text("Unable to check an interrupted removal").font(.headline)
                    Text(journalError).foregroundColor(.secondary)
                    Text("Delivery is paused until this can be checked.")
                    Button("Try again") { refresh() }
                }.padding()
            } else if let intent = intent {
                recoveryView(intent)
            } else if isEnrolled {
                enrolledHome
            } else {
                enrollChooser
            }
        }
        .onAppear { refresh() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { refresh() }
        }
        .alert("Stale registration possible", isPresented: $showUncertainRegistrationWarning) {
            Button("OK") {
                try? RecordStore.shared.acknowledgeUncertainRegistrationRemovalWarning()
            }
        } message: {
            Text(RecordStore.uncertainRegistrationRemovalWarningMessage)
        }
    }

    private func refresh() {
        RecordStore.shared.refreshFromStorage()
        applyShell(RecordStore.shared.contentShellState())
    }

    private func applyShell(_ shell: RecordStore.ContentShellState) {
        showUncertainRegistrationWarning = shell.showsUncertainWarningAlert
        uncertainWarningJournalError = shell.showsUncertainWarningJournalNotice
            ? RecordStore.uncertainRegistrationWarningJournalUnreadableMessage
            : nil
        switch shell.route {
        case .storageUnavailable:
            storageError = PuxError.keychainUnavailable.localizedDescription
            journalError = nil
            intent = nil
            showUncertainRegistrationWarning = false
            uncertainWarningJournalError = nil
            isEnrolled = false
        case .removalIntentCheckFailed:
            storageError = nil
            intent = nil
            journalError = shell.removalIntentReadErrorMessage
            isEnrolled = RecordStore.shared.isEnrolled()
        case .recoverRemoval(let savedIntent):
            storageError = nil
            journalError = nil
            intent = savedIntent
            isEnrolled = RecordStore.shared.isEnrolled()
        case .home:
            storageError = nil
            journalError = nil
            intent = nil
            isEnrolled = true
        case .enroll:
            storageError = nil
            journalError = nil
            intent = nil
            isEnrolled = false
        }
    }

    private var uncertainWarningJournalBanner: some View {
        Group {
            if let uncertainWarningJournalError = uncertainWarningJournalError {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Stale-registration reminder unavailable").font(.headline)
                    Text(uncertainWarningJournalError).foregroundColor(.secondary)
                    Button("Try again") { refresh() }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            }
        }
    }

    private var enrolledHome: some View {
        VStack(spacing: 0) {
            uncertainWarningJournalBanner
                .padding(.horizontal)
                .padding(.top, 8)
            HomeScreen(onRelayForgotten: refresh)
        }
    }

    private var enrollChooser: some View {
        VStack(spacing: 0) {
            uncertainWarningJournalBanner
                .padding(.horizontal)
                .padding(.top, 8)
            EnrollChooserScreen(onEnrolled: refresh)
        }
    }

    private func recoveryView(_ intent: RemovalIntent) -> some View {
        PuxStackNavigation {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    uncertainWarningJournalBanner
                    Text("Removal was interrupted").font(.title2.bold())
                    switch intent {
                    case .relay:
                        Text("You chose to delete the relay everywhere. Retrying can delete the relay and disconnect every device. The server operation may already have completed.")
                    case .device:
                        Text("You chose to remove this device. Other devices on the relay are unaffected. The server operation may already have completed.")
                    case .local:
                        Text("Finish clearing the local credentials before using pux.")
                    }
                    if let recoveryError = recoveryError {
                        Text(recoveryError).foregroundColor(.red)
                    }
                    Button(intent == .local ? "Finish clearing credentials" : (intent == .relay ? "Retry deleting relay everywhere" : "Retry removing this device")) {
                        perform { try await DeliveryController.shared.recoverRemoval(intent) }
                    }
                    if intent != .local {
                        Button("Forget locally anyway", role: .destructive) {
                            perform { try await DeliveryController.shared.finishRemovalLocally() }
                        }
                        Text("Forgetting locally may leave this device or relay active on the server.")
                            .font(.footnote).foregroundColor(.secondary)
                        if isEnrolled {
                            Button("Keep relay and resume delivery") {
                                perform { try await DeliveryController.shared.endRemoval(resume: true) }
                            }
                            Text("Resuming may register this device again, even if removal already succeeded.")
                                .font(.footnote).foregroundColor(.secondary)
                        }
                    }
                    if busy { ProgressView() }
                }.padding().disabled(busy)
            }.navigationTitle("pux")
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            do {
                try await action()
                recoveryError = nil
                refresh()
            } catch {
                recoveryError = error.localizedDescription
                refresh()
            }
            busy = false
        }
    }
}
#endif
