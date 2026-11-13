#if os(iOS)
import SwiftUI
import PuxCore

public struct EnrollScreen: View {
    @State private var isProcessing = false
    @State private var isScanning = true
    @State private var errorMessage: String?
    @State private var pendingPayload: [String: Any]?
    @State private var showServerConfirmation = false
    @State private var serverToConfirm = ""

    let onEnrolled: () -> Void

    public init(onEnrolled: @escaping () -> Void) {
        self.onEnrolled = onEnrolled
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text("Scan the QR from an existing enrolled device.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()

            ZStack {
                QRScannerView(isScanning: $isScanning, onCodeScanned: { scannedCode in
                    handleScannedCode(scannedCode)
                }, onError: { error in
                    switch error {
                    case .permissionDenied:
                        errorMessage =
                            "Camera access is required to scan QR codes. Open Settings to allow camera access, or paste enrollment JSON manually."
                    case .unavailable:
                        errorMessage = "This device has no camera. Paste enrollment JSON manually."
                    case .setupFailed:
                        errorMessage = "The camera could not be started. Paste enrollment JSON manually."
                    case .none:
                        errorMessage = nil
                    }
                })
                .edgesIgnoringSafeArea(.bottom)

                if isProcessing {
                    Color.black.opacity(0.4)
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(PuxTheme.errorText)
                    .padding()
            }

            NavigationLink(destination: ImportEnrollmentScreen(onEnrolled: onEnrolled)) {
                Text("Or paste enrollment JSON manually")
                    .font(.footnote)
                    .foregroundColor(PuxTheme.leaf)
                    .padding()
            }
        }
        .navigationTitle("Enroll device")
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
                isScanning = true
                pendingPayload = nil
            }
        )
    }

    private func handleScannedCode(_ raw: String) {
        guard !isProcessing else { return }
        isProcessing = true
        isScanning = false
        errorMessage = nil

        do {
            let payload = try RecordStore.shared.parseQr(raw)
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
            DispatchQueue.main.async { isScanning = true }
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
                DispatchQueue.main.async { isScanning = true }
                errorMessage = error.localizedDescription
            }
        }
    }
}

#endif
