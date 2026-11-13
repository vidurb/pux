import Foundation

public struct FirebaseConfig: Equatable, Sendable {
    public let apiKey: String
    public let projectId: String
    public let gcmSenderId: String
    public let googleAppId: String
    public let bundleId: String

    public init(
        apiKey: String,
        projectId: String,
        gcmSenderId: String,
        googleAppId: String,
        bundleId: String
    ) {
        self.apiKey = apiKey
        self.projectId = projectId
        self.gcmSenderId = gcmSenderId
        self.googleAppId = googleAppId
        self.bundleId = bundleId
    }

    public static func load(from bundle: Bundle = .main) -> FirebaseConfig? {
        guard let path = bundle.path(forResource: "GoogleService-Info", ofType: "plist")
                ?? Bundle(for: RecordStore.self).path(forResource: "GoogleService-Info", ofType: "plist")
        else {
            return nil
        }
        return load(fromPath: path)
    }

    public static func load(fromPath path: String) -> FirebaseConfig? {
        guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return nil
        }
        return load(fromDictionary: dict)
    }

    public static func load(fromDictionary dict: [String: Any]) -> FirebaseConfig? {
        guard let apiKey = dict["API_KEY"] as? String,
              !apiKey.isEmpty,
              !apiKey.contains("REPLACE_ME"),
              let projectId = dict["PROJECT_ID"] as? String,
              !projectId.isEmpty,
              !projectId.contains("REPLACE_ME"),
              let gcmSenderId = dict["GCM_SENDER_ID"] as? String,
              !gcmSenderId.isEmpty,
              let googleAppId = dict["GOOGLE_APP_ID"] as? String,
              !googleAppId.isEmpty,
              !googleAppId.contains("REPLACE_ME"),
              let bundleId = dict["BUNDLE_ID"] as? String,
              !bundleId.isEmpty
        else {
            return nil
        }

        return FirebaseConfig(
            apiKey: apiKey,
            projectId: projectId,
            gcmSenderId: gcmSenderId,
            googleAppId: googleAppId,
            bundleId: bundleId
        )
    }
}
