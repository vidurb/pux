#if os(iOS)
#if canImport(UIKit)
import SwiftUI
import AVFoundation

public enum CameraErrorState: Equatable {
    case none
    case permissionDenied
    case unavailable
    case setupFailed(String)
}

public struct QRScannerView: UIViewControllerRepresentable {
    @Binding public var isScanning: Bool
    public let onCodeScanned: (String) -> Void
    public let onError: ((CameraErrorState) -> Void)?

    public init(
        isScanning: Binding<Bool> = .constant(true),
        onCodeScanned: @escaping (String) -> Void,
        onError: ((CameraErrorState) -> Void)? = nil
    ) {
        self._isScanning = isScanning
        self.onCodeScanned = onCodeScanned
        self.onError = onError
    }

    public func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    public func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {
        if isScanning {
            uiViewController.resumeScanning()
        } else {
            uiViewController.pauseScanning()
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned, onError: onError)
    }

    public final class Coordinator: NSObject, ScannerViewControllerDelegate {
        let onCodeScanned: (String) -> Void
        let onError: ((CameraErrorState) -> Void)?

        init(onCodeScanned: @escaping (String) -> Void, onError: ((CameraErrorState) -> Void)?) {
            self.onCodeScanned = onCodeScanned
            self.onError = onError
        }

        public func didScanCode(_ code: String) {
            onCodeScanned(code)
        }

        public func didFailWithError(_ error: CameraErrorState) {
            onError?(error)
        }
    }
}

public protocol ScannerViewControllerDelegate: AnyObject {
    func didScanCode(_ code: String)
    func didFailWithError(_ error: CameraErrorState)
}

public final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    public weak var delegate: ScannerViewControllerDelegate?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var errorContainerView: UIView?
    private let sessionQueue = DispatchQueue(label: "xyz.vidur.pux.camera")
    private var wantsScanning = true

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
        checkPermissionsAndSetup()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        errorContainerView?.frame = view.bounds
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if captureSession != nil && wantsScanning { resumeScanning() }
    }

    @objc private func didBecomeActive() {
        guard isViewLoaded, view.window != nil else { return }
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized, captureSession == nil {
            checkPermissionsAndSetup()
        } else if wantsScanning {
            resumeScanning()
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [weak self] in
            guard let session = self?.captureSession, session.isRunning else { return }
            session.stopRunning()
        }
    }

    private func checkPermissionsAndSetup() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCamera()
                    } else {
                        self?.showPermissionDeniedUI()
                    }
                }
            }
        case .denied, .restricted:
            showPermissionDeniedUI()
        @unknown default:
            showPermissionDeniedUI()
        }
    }

    private func setupCamera() {
        guard captureSession == nil else { return }
        errorContainerView?.removeFromSuperview()
        errorContainerView = nil
        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            showCameraUnavailableUI()
            return
        }

        let session = AVCaptureSession()
        do {
            let videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
            guard session.canAddInput(videoInput) else {
                showSetupFailedUI("Cannot add video input to session")
                return
            }
            session.addInput(videoInput)
        } catch {
            showSetupFailedUI(error.localizedDescription)
            return
        }

        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else {
            showSetupFailedUI("Cannot add metadata output to session")
            return
        }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        metadataOutput.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.previewLayer = preview
        self.captureSession = session
        delegate?.didFailWithError(.none)

        if wantsScanning { resumeScanning() }
    }

    private func showPermissionDeniedUI() {
        delegate?.didFailWithError(.permissionDenied)
        showOverlay(
            title: "Camera Permission Needed",
            message: "Camera access is needed to scan your existing relay's QR code. Please enable Camera in iOS Settings.",
            buttonTitle: "Open Settings",
            action: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        )
    }

    private func showCameraUnavailableUI() {
        delegate?.didFailWithError(.unavailable)
        showOverlay(
            title: "Camera Unavailable",
            message: "No video capture device was found (e.g., running on Simulator). You can paste the enrollment JSON manually.",
            buttonTitle: nil,
            action: nil
        )
    }

    private func showSetupFailedUI(_ reason: String) {
        delegate?.didFailWithError(.setupFailed(reason))
        showOverlay(
            title: "Camera Setup Failed",
            message: reason,
            buttonTitle: "Retry",
            action: { [weak self] in
                self?.errorContainerView?.removeFromSuperview()
                self?.setupCamera()
            }
        )
    }

    private func showOverlay(title: String, message: String, buttonTitle: String?, action: (() -> Void)?) {
        errorContainerView?.removeFromSuperview()

        let container = UIView(frame: view.bounds)
        container.backgroundColor = UIColor(white: 0.1, alpha: 0.95)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        stack.addArrangedSubview(titleLabel)

        let messageLabel = UILabel()
        messageLabel.text = message
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.textColor = UIColor(white: 0.8, alpha: 1.0)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        stack.addArrangedSubview(messageLabel)

        if let btnTitle = buttonTitle, let act = action {
            let button = UIButton(type: .system)
            button.setTitle(btnTitle, for: .normal)
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.backgroundColor = UIColor(red: 0.867, green: 0.953, blue: 0.839, alpha: 1.0) // Mint
            button.setTitleColor(UIColor(red: 0.055, green: 0.231, blue: 0.196, alpha: 1.0), for: .normal) // Pine
            button.layer.cornerRadius = 10
            button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
            button.addAction(UIAction { _ in act() }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32)
        ])

        view.addSubview(container)
        self.errorContainerView = container
    }

    public func pauseScanning() {
        wantsScanning = false
        sessionQueue.async { [weak self] in
            guard let session = self?.captureSession, session.isRunning else { return }
            session.stopRunning()
        }
    }

    public func resumeScanning() {
        wantsScanning = true
        sessionQueue.async { [weak self] in
            guard let session = self?.captureSession, !session.isRunning else { return }
            session.startRunning()
        }
    }

    public func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = metadataObject.stringValue
        else { return }

        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        pauseScanning()
        delegate?.didScanCode(stringValue)
    }
}
#endif

#endif
