import Darwin
import Foundation

/// The fixture app is a separate bundle. Invalid fixture configuration fails
/// closed instead of silently falling back to the user's real home directory.
struct CleanupEnvironment: Sendable {
    let home: URL
    let recoveryRoot: URL
    let isFixture: Bool
    let blockedReason: String?

    static var fixtureRequested: Bool { Bundle.main.object(forInfoDictionaryKey: "PureMacFixtureRoot") != nil }

    static var current: CleanupEnvironment {
        guard let configuredRoot = Bundle.main.object(forInfoDictionaryKey: "PureMacFixtureRoot") else {
            let home = XcodeBuildMCPDerivedDataSupport.canonicalHomeDirectory(FileManager.default.homeDirectoryForCurrentUser)
            return CleanupEnvironment(home: home,
                recoveryRoot: home.appendingPathComponent("Library/Application Support/\(ProductIdentity.storageDirectory)/Recovery"),
                isFixture: false, blockedReason: nil)
        }
        guard let path = configuredRoot as? String, !path.isEmpty else {
            let unavailable = Bundle.main.bundleURL.appendingPathComponent("INVALID-NO-OPERATIONS")
            return CleanupEnvironment(home: unavailable, recoveryRoot: unavailable,
                                      isFixture: true, blockedReason: RecoveryFailure.invalidRecord.localizedDescription)
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        do {
            let parent = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("test-workspaces")
            return try checkedFixture(root: root, below: parent)
        } catch {
            return CleanupEnvironment(home: root.appendingPathComponent("INVALID-NO-OPERATIONS"),
                recoveryRoot: root.appendingPathComponent("INVALID-NO-OPERATIONS"),
                isFixture: true, blockedReason: error.localizedDescription)
        }
    }

    static func checkedFixture(root: URL, below parent: URL) throws -> CleanupEnvironment {
        let parentFD = try RecoveryFileSystem.directory(parent.path)
        defer { close(parentFD) }
        let physicalParent = try RecoveryFileSystem.canonicalExisting(parent.path)
        guard RecoveryFileSystem.inside(root.path, physicalParent),
              try RecoveryFileSystem.canonicalExisting(root.path) == root.path else { throw RecoveryFailure.unsafePath }
        let rootFD = try RecoveryFileSystem.directory(root.path)
        defer { close(rootFD) }
        let marker = try RecoveryFileSystem.read(at: rootFD, name: ".puremac-fixture.json")
        let data = try JSONSerialization.jsonObject(with: marker) as? [String: String]
        guard data?["purpose"] == "PureMac disposable recovery tests", data?["root"] == root.path else {
            throw RecoveryFailure.invalidRecord
        }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let fd = try RecoveryFileSystem.directory(home.path)
        defer { close(fd) }
        // Use the scanners' spelling of the home path for both review and recovery.
        // Foundation may spell macOS's verified /private/tmp alias as /tmp.
        let scanHome = XcodeBuildMCPDerivedDataSupport.canonicalHomeDirectory(home)
        guard try RecoveryFileSystem.canonicalExisting(scanHome.path) == home.path else { throw RecoveryFailure.unsafePath }
        return CleanupEnvironment(home: scanHome, recoveryRoot: root.appendingPathComponent("recovery"),
                                  isFixture: true, blockedReason: nil)
    }

    var scanCategories: [CleaningCategory] {
        guard blockedReason == nil else { return [] }
        return CleaningCategory.scannable
    }

    var sampleHome: URL? { isFixture && blockedReason == nil ? home : nil }

    var sampleTrash: (@Sendable (URL) throws -> Void)? {
        guard let sampleHome else { return nil }
        let trash = recoveryRoot.deletingLastPathComponent().appendingPathComponent("sample-trash")
        return { url in
            try RecoveryFileSystem.checkDirectory(sampleHome.path)
            let parent = url.deletingLastPathComponent()
            let sourceFD = try RecoveryFileSystem.directory(parent.path)
            defer { close(sourceFD) }
            let physicalHome = try RecoveryFileSystem.canonicalExisting(sampleHome.path)
            let physicalParent = try RecoveryFileSystem.canonicalExisting(parent.path)
            guard physicalParent == physicalHome || RecoveryFileSystem.inside(physicalParent, physicalHome) else {
                throw RecoveryFailure.unsafePath
            }
            let name = url.lastPathComponent
            _ = try RecoveryFileSystem.snapshot(at: sourceFD, name: name, includeTree: false)
            let destination = trash.appendingPathComponent(UUID().uuidString)
            let destinationFD = try RecoveryFileSystem.directory(destination.path, create: true)
            defer { close(destinationFD) }
            try RecoveryFileSystem.move(from: sourceFD, name: name, to: destinationFD, target: name)
        }
    }

    func makeRecoveryStore() -> RecoveryStore {
        RecoveryStore(root: recoveryRoot,
            allowedRoots: isFixture ? [home] : CleaningEngine.recoveryRoots(home: home),
            allowedRootItems: isFixture ? [] : CleaningEngine.recoveryRootItems(home: home),
            pathValidator: { path, category, snapshot in
                RecoveryPathPolicy.accepts(path: path, category: category, snapshot: snapshot, home: home)
            })
    }
}
