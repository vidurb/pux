#if os(iOS)
import AuthenticationServices

@available(iOS 18.0, *)
public enum AutoFillIdentities {
    public static let recordIdentifier = "pux.latest"

    public static func refresh(completion: @escaping (Bool) -> Void = { _ in }) {
        let store = ASCredentialIdentityStore.shared
        store.getState { state in
            guard state.isEnabled else { completion(false); return }
            let cache = AutoFillStore()
            var identities: [any ASCredentialIdentity] = []
            if cache.isEnabled, let mapping = cache.mapping {
                identities = [ASOneTimeCodeCredentialIdentity(
                    serviceIdentifier: ASCredentialServiceIdentifier(identifier: mapping.websiteDomain, type: .domain),
                    label: "Pux code from \(mapping.senderDomain)",
                    recordIdentifier: recordIdentifier
                )]
            }
            store.replaceCredentialIdentities(identities) { success, _ in completion(success) }
        }
    }
}
#endif
