import Darwin
import Foundation

/// The fixture app is a separate bundle. Invalid fixture configuration fails
/// closed instead of silently falling back to the user's real home directory.
struct CleanupEnvironment {
    let home: URL
    let recoveryRoot: URL
    let isFixture: Bool
    let blockedReason: String?

    static var fixtureRequested: Bool { Bundle.main.object(forInfoDictionaryKey: "PureMacFixtureRoot") != nil }

    static var current: CleanupEnvironment {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "PureMacFixtureRoot") as? String else {
            let home = XcodeBuildMCPDerivedDataSupport.canonicalHomeDirectory(FileManager.default.homeDirectoryForCurrentUser)
            return CleanupEnvironment(home: home,
                recoveryRoot: home.appendingPathComponent("Library/Application Support/\(ProductIdentity.storageDirectory)/Recovery"),
                isFixture: false, blockedReason: nil)
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        do {
            let parent = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("test-workspaces").path
            guard RecoveryFileSystem.inside(path, parent),
                  try RecoveryFileSystem.canonicalExisting(path) == path else { throw RecoveryFailure.unsafePath }
            let marker = try Data(contentsOf: root.appendingPathComponent(".puremac-fixture.json"))
            let data = try JSONSerialization.jsonObject(with: marker) as? [String: String]
            guard data?["purpose"] == "PureMac disposable recovery tests", data?["root"] == path else {
                throw RecoveryFailure.invalidRecord
            }
            let home = root.appendingPathComponent("home", isDirectory: true)
            let fd = try RecoveryFileSystem.directory(home.path)
            close(fd)
            return CleanupEnvironment(home: home, recoveryRoot: root.appendingPathComponent("recovery"),
                                      isFixture: true, blockedReason: nil)
        } catch {
            return CleanupEnvironment(home: root.appendingPathComponent("INVALID-NO-OPERATIONS"),
                recoveryRoot: root.appendingPathComponent("INVALID-NO-OPERATIONS"),
                isFixture: true, blockedReason: error.localizedDescription)
        }
    }

    func makeRecoveryStore() -> RecoveryStore {
        RecoveryStore(root: recoveryRoot,
            allowedRoots: isFixture ? [home] : CleaningEngine.recoveryRoots(home: home),
            allowedRootItems: isFixture ? [] : CleaningEngine.recoveryRootItems(home: home),
            pathValidator: { path, category, snapshot in
                if ProductIdentity.isPublicBeta && !BetaCapabilities.categories.contains(where: { $0.rawValue == category }) {
                    return false
                }
                return RecoveryPathPolicy.accepts(path: path, category: category, snapshot: snapshot, home: home)
            })
    }
}
