import Foundation

/// Public identity is supplied by release/product.json when packaging.
/// Internal module names remain unchanged to preserve the upstream history.
enum ProductIdentity {
    static var name: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Cachora" }
    static var isPublicBeta: Bool { Bundle.main.object(forInfoDictionaryKey: "SafeCleanupBeta") as? Bool ?? false }
    static var storageDirectory: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "SafeCleanupStorageDirectory") as? String ?? "Cachora"
        return value.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil ? value : "Cachora"
    }
    static var releaseChannel: AppReleaseChannel? {
        guard let repository = Bundle.main.object(forInfoDictionaryKey: "SafeCleanupRepository") as? String,
              let prefix = Bundle.main.object(forInfoDictionaryKey: "SafeCleanupAssetPrefix") as? String else { return nil }
        return AppReleaseChannel(repository: repository, assetPrefix: prefix, includesPrereleases: isPublicBeta)
    }
}
