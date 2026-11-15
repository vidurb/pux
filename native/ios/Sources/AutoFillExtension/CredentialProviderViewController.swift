#if os(iOS)
import AuthenticationServices
import UIKit
import PuxCore

@available(iOS 18.0, *)
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let stack = UIStackView()
    private var configuration = false
    private var displayedCode: String?
    private var displayedDate: Date?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
        ])
    }

    override func prepareInterfaceForExtensionConfiguration() {
        configuration = true
        AutoFillIdentities.refresh()
        showPicker()
    }

    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        showPicker()
    }

    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        let cache = AutoFillStore()
        guard credentialRequest is ASOneTimeCodeCredentialRequest,
              let identity = credentialRequest.credentialIdentity as? ASOneTimeCodeCredentialIdentity,
              let mapping = cache.mapping,
              identity.recordIdentifier == AutoFillIdentities.recordIdentifier,
              identity.label == "Pux code from \(mapping.senderDomain)",
              identity.serviceIdentifier.identifier == mapping.websiteDomain,
              let code = cache.latest(), mapping.matches(code)
        else {
            cancel(.userInteractionRequired)
            return
        }
        extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code.code), completionHandler: nil)
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        showPicker()
    }

    private func showPicker() {
        loadViewIfNeeded()
        displayedCode = nil
        displayedDate = nil
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let title = UILabel()
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        title.text = "Pux AutoFill"
        stack.addArrangedSubview(title)

        let message = UILabel()
        message.numberOfLines = 0
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        let cache = AutoFillStore()
        if configuration {
            message.text = "Enable keyboard codes in Pux → Keyboard AutoFill. Then send a test code or receive an OTP."
        } else if let code = cache.latest() {
            displayedCode = code.code
            displayedDate = code.receivedAt
            message.text = "From \(code.sender)\(code.verified ? "" : " (unverified)"). Only fill this code if you requested it on this app or website."
            stack.addArrangedSubview(message)
            addButton("Fill \(code.code)", action: #selector(fillLatest))
        } else {
            message.text = cache.isEnabled
                ? "No recent code. Receive an OTP, then try again. Codes are available here for five minutes."
                : "Enable keyboard codes in Pux → Keyboard AutoFill, then receive an OTP."
        }
        if message.superview == nil { stack.addArrangedSubview(message) }
        if !configuration { addButton("Refresh", action: #selector(refresh)) }
        addButton(configuration ? "Done" : "Cancel", action: #selector(close))
    }

    private func addButton(_ title: String, action: Selector) {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        stack.addArrangedSubview(button)
    }

    @objc private func refresh() { showPicker() }

    @objc private func fillLatest() {
        guard let code = AutoFillStore().latest(),
              code.code == displayedCode, code.receivedAt == displayedDate
        else { showPicker(); return }
        extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code.code), completionHandler: nil)
    }

    @objc private func close() {
        if configuration { extensionContext.completeExtensionConfigurationRequest() }
        else { cancel(.userCanceled) }
    }

    private func cancel(_ code: ASExtensionError.Code) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue))
    }
}
#endif
