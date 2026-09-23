import Foundation

/// Apple 云端（PCC）使用确认。首次使用云端前必须由用户明确同意；M0 存于 UserDefaults。
/// 默认后端始终是设备端；没有确认时 ModelBroker 拒绝任何云端请求。
public struct CloudConsentStore: Sendable {
    static let consentKey = "fairy.ai.privateCloudCompute.consent.v1"
    static let consentDateKey = "fairy.ai.privateCloudCompute.consentDate.v1"

    /// nil 表示 UserDefaults.standard；测试使用独立 suite。
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    public static let standard = CloudConsentStore()

    private var defaults: UserDefaults {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        return .standard
    }

    public var hasConsented: Bool {
        defaults.bool(forKey: Self.consentKey)
    }

    public var consentDate: Date? {
        defaults.object(forKey: Self.consentDateKey) as? Date
    }

    public func grantConsent(at date: Date = Date()) {
        defaults.set(true, forKey: Self.consentKey)
        defaults.set(date, forKey: Self.consentDateKey)
    }

    public func revokeConsent() {
        defaults.removeObject(forKey: Self.consentKey)
        defaults.removeObject(forKey: Self.consentDateKey)
    }
}
