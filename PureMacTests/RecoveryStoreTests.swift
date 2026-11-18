import CryptoKit
import Darwin
import Foundation

#if canImport(XCTest)
import XCTest
@testable import PureMac
final class RecoveryStoreTests: XCTestCase {
    func testRecoveryFailureMatrix() async throws {
        for (_, test) in RecoveryChecks.cases { try await test() }
    }
}
#elseif PUREMAC_RECOVERY_STORE_TEST_RUNNER
@main
enum RecoveryStoreTestRunner {
    static func main() async {
        var failures: [String] = []
        for (name, test) in RecoveryChecks.cases {
            do { try await test(); print("PASS: \(name)") }
            catch { failures.append(name + ": " + String(describing: error)); print("FAIL: \(name): \(error)") }
        }
        print("Recovery checks: \(RecoveryChecks.cases.count - failures.count)/\(RecoveryChecks.cases.count) passed; disposable workspaces only.")
        if !failures.isEmpty { exit(1) }
    }
}
#endif

enum RecoveryChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }
    static func expectFailure(_ operation: () async throws -> Void) async throws {
        var failed = false
        do { try await operation() } catch { failed = true }
        try require(failed, "Unsafe operation unexpectedly succeeded")
    }

    struct Fixture {
        let root: URL
        var home: URL { root.appendingPathComponent("home") }
        var cache: URL { home.appendingPathComponent("Library/Caches") }
        var vault: URL { root.appendingPathComponent("recovery") }
        var sentinel: URL { home.appendingPathComponent("Documents/preserve.txt") }
        var outside: URL { root.appendingPathComponent("outside/preserve.txt") }
        let preserved = Data("PRESERVE-TEST-SENTINEL-ONLY".utf8)

        func store(fault: (@Sendable (RecoveryCheckpoint) throws -> Void)? = nil) -> RecoveryStore {
            RecoveryStore(root: vault, allowedRoots: [cache], fault: fault)
        }
        func file(_ name: String = "sample.bin") throws -> URL {
            let url = cache.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("TEST-DATA-\(name)-0123456789".utf8).write(to: url)
            return url
        }
        func stage(_ source: URL, store: RecoveryStore? = nil) async throws -> RecoveryEntry {
            guard let snapshot = RecoverySnapshot.capture(source.path) else { throw Failure(description: "Missing fixture") }
            return try await (store ?? self.store()).stage(path: source.path, name: source.lastPathComponent,
                category: "User Cache", bytes: 4096, expected: snapshot).entry
        }
        func object(_ id: UUID) -> URL { vault.appendingPathComponent("objects/" + id.uuidString) }
        func record(_ id: UUID) -> URL { vault.appendingPathComponent("entries/" + id.uuidString + ".json") }
    }

    static func fixture(_ name: String, _ body: (Fixture) async throws -> Void) async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let location = repository.appendingPathComponent("build-local/test-workspaces/\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let root = location.standardizedFileURL
        let fixture = Fixture(root: root)
        for parent in [fixture.cache, fixture.sentinel.deletingLastPathComponent(), fixture.outside.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try fixture.preserved.write(to: fixture.sentinel)
        try fixture.preserved.write(to: fixture.outside)
        var caught: Error?
        do { try await body(fixture) } catch { caught = error }
        try require(try Data(contentsOf: fixture.sentinel) == fixture.preserved, "Document sentinel changed")
        try require(try Data(contentsOf: fixture.outside) == fixture.preserved, "Outside-boundary sentinel changed")
        if let caught {
            let audit: [String: Any] = ["test": name, "workspace": root.path,
                "sentinels_unchanged": true, "test_completed": false,
                "sentinel_sha256": SHA256.hash(data: fixture.preserved).map { String(format: "%02x", $0) }.joined()]
            try JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("audit.json"))
            throw caught
        }
        try FileManager.default.removeItem(at: root)
    }

    static var cases: [(String, () async throws -> Void)] { [
        ("file round trip", {
            try await fixture("round-trip") { f in
                let source = try f.file(); let bytes = try Data(contentsOf: source)
                try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
                let store = f.store(); let entry = try await f.stage(source, store: store)
                try require(!FileManager.default.fileExists(atPath: source.path), "Source was not moved")
                _ = try await store.restore(entry.id)
                try require(try Data(contentsOf: source) == bytes, "Restored bytes differ")
                try require((RecoverySnapshot.capture(source.path)?.mode ?? 0) & 0o777 == 0o640, "File permissions changed")
            }
        }),
        ("hidden directory round trip", {
            try await fixture("directory-hidden") { f in
                let nested = try f.file("folder/.hidden/secret-test.txt")
                let visible = try f.file("folder/visible.txt")
                let a = try Data(contentsOf: nested), b = try Data(contentsOf: visible)
                let folder = f.cache.appendingPathComponent("folder")
                let store = f.store(); let entry = try await f.stage(folder, store: store)
                _ = try await store.restore(entry.id)
                try require(try Data(contentsOf: nested) == a && Data(contentsOf: visible) == b, "Directory contents changed")
            }
        }),
        ("persisted history after restart", {
            try await fixture("restart") { f in
                let source = try f.file(); let entry = try await f.stage(source)
                let restarted = f.store(); let catalog = try await restarted.catalog()
                try require(catalog.entries.contains { $0.id == entry.id && $0.canRestore }, "Persistent record missing")
                _ = try await restarted.restore(entry.id)
            }
        }),
        ("restore conflict preserves both copies and permits retry", {
            try await fixture("conflict") { f in
                let source = try f.file(); let old = try Data(contentsOf: source)
                let store = f.store(); let entry = try await f.stage(source, store: store)
                let replacement = Data("NEW-FIXTURE-CONTENT".utf8); try replacement.write(to: source)
                try await expectFailure { _ = try await store.restore(entry.id) }
                try require(try Data(contentsOf: source) == replacement, "Existing destination was overwritten")
                try require(try Data(contentsOf: f.object(entry.id)) == old, "Recovery copy was lost")
                try FileManager.default.moveItem(at: source, to: f.cache.appendingPathComponent("new-copy-kept.bin"))
                _ = try await store.restore(entry.id)
                try require(try Data(contentsOf: source) == old, "Conflict retry failed")
            }
        }),
        ("missing original parent recreated", {
            try await fixture("missing-parent") { f in
                let source = try f.file("sub/file.bin"); let store = f.store()
                let entry = try await f.stage(source, store: store)
                try FileManager.default.removeItem(at: source.deletingLastPathComponent())
                _ = try await store.restore(entry.id)
                try require(FileManager.default.fileExists(atPath: source.path), "Missing parent was not recreated")
            }
        }),
        ("stale replaced file refused", {
            try await fixture("replaced") { f in
                let source = try f.file(); let snapshot = RecoverySnapshot.capture(source.path)!
                try FileManager.default.moveItem(at: source, to: f.cache.appendingPathComponent("old.bin"))
                try Data("REPLACEMENT".utf8).write(to: source)
                try await expectFailure { _ = try await f.store().stage(path: source.path, name: "old", category: "User Cache", bytes: 10, expected: snapshot) }
                try require(try Data(contentsOf: source) == Data("REPLACEMENT".utf8), "Replacement was moved")
            }
        }),
        ("stale modified file refused", {
            try await fixture("modified") { f in
                let source = try f.file(); let snapshot = RecoverySnapshot.capture(source.path)!
                try Data("CHANGED-SIZE".utf8).write(to: source)
                try await expectFailure { _ = try await f.store().stage(path: source.path, name: "old", category: "User Cache", bytes: 10, expected: snapshot) }
            }
        }),
        ("symbolic link source refused", {
            try await fixture("source-link") { f in
                let link = f.cache.appendingPathComponent("link")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.outside)
                try await expectFailure { _ = try await f.store().stage(path: link.path, name: "link", category: "User Cache", bytes: 1, expected: RecoverySnapshot.capture(f.outside.path)!) }
            }
        }),
        ("symbolic link parent refused", {
            try await fixture("parent-link") { f in
                let alias = f.cache.appendingPathComponent("alias")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.outside.deletingLastPathComponent())
                try await expectFailure { _ = try await f.store().stage(path: alias.appendingPathComponent("preserve.txt").path, name: "alias", category: "User Cache", bytes: 1, expected: RecoverySnapshot.capture(f.outside.path)!) }
            }
        }),
        ("restore into linked parent refused", {
            try await fixture("restore-link") { f in
                let source = try f.file("sub/file.bin"); let store = f.store()
                let entry = try await f.stage(source, store: store)
                try FileManager.default.removeItem(at: source.deletingLastPathComponent())
                try FileManager.default.createSymbolicLink(at: source.deletingLastPathComponent(), withDestinationURL: f.outside.deletingLastPathComponent())
                try await expectFailure { _ = try await store.restore(entry.id) }
                try require(FileManager.default.fileExists(atPath: f.object(entry.id).path), "Recovery copy vanished")
            }
        }),
        ("changed recovery object refused", {
            try await fixture("changed-object") { f in
                let source = try f.file(); let store = f.store(); let entry = try await f.stage(source, store: store)
                try Data("ALTERED-RECOVERY-COPY".utf8).write(to: f.object(entry.id))
                try await expectFailure { _ = try await store.restore(entry.id) }
                try require(!FileManager.default.fileExists(atPath: source.path), "Altered object was restored")
            }
        }),
        ("an open file changed in Recovery can be saved separately", {
            try await fixture("save-open-log") { f in
                let source = try f.file("running.log")
                let original = try Data(contentsOf: source)
                let writer = try FileHandle(forWritingTo: source)
                defer { try? writer.close() }
                try writer.seekToEnd()
                let store = f.store()
                let entry = try await f.stage(source, store: store)
                let later = Data("more generated log lines".utf8)
                try writer.write(contentsOf: later)
                try writer.close()
                let catalog = try await store.catalog()
                try require(catalog.entries.first?.canSaveCopy == true && catalog.entries.first?.canRestore == false,
                            "The changed file still advertised ordinary restore")
                try await expectFailure { _ = try await store.restore(entry.id) }
                let target = f.home.appendingPathComponent("Documents/running-copy.log")
                try await store.saveCopy(entry.id, to: target)
                try require(try Data(contentsOf: target) == original + later, "The copy lost the new log lines")
                try require(try Data(contentsOf: f.object(entry.id)) == original + later, "Saving the copy changed Recovery")
                try require(!FileManager.default.fileExists(atPath: source.path), "Saving changed the original location")
                try await expectFailure { try await store.saveCopy(entry.id, to: target) }
                try await expectFailure { try await store.saveCopy(entry.id, to: source) }
                try await expectFailure { try await store.saveCopy(entry.id, to: f.vault.appendingPathComponent("new-copy")) }
                try require(try Data(contentsOf: target) == original + later, "The existing destination was overwritten")
            }
        }),
        ("a nested change can be copied with the directory metadata and hidden files", {
            try await fixture("save-changed-directory") { f in
                let source = try f.file("folder/.hidden/log.txt")
                let included = try f.file("folder/unchanged.txt")
                let unchanged = try Data(contentsOf: included)
                let folder = f.cache.appendingPathComponent("folder")
                let store = RecoveryStore(root: f.vault, allowedRoots: [f.cache], copyDestinationRoot: f.home)
                let entry = try await f.stage(folder, store: store)
                let stored = f.object(entry.id).appendingPathComponent(".hidden/log.txt")
                let changed = Data("longer fixture log".utf8)
                try changed.write(to: stored)
                try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: stored.path)
                let attribute = Data("fixture-only".utf8)
                let result = attribute.withUnsafeBytes { setxattr(stored.path, "com.cachora.sample", $0.baseAddress, $0.count, 0, 0) }
                try require(result == 0, "Could not add a fixture extended attribute")
                let catalog = try await store.catalog()
                try require(catalog.entries.first?.state == .copyChanged, "The catalog missed a nested change")
                let rejected = f.outside.deletingLastPathComponent().appendingPathComponent("forbidden")
                try await expectFailure { try await store.saveCopy(entry.id, to: rejected) }
                let target = f.home.appendingPathComponent("Documents/copy")
                try await store.saveCopy(entry.id, to: target)
                let file = target.appendingPathComponent(".hidden/log.txt")
                try require(try Data(contentsOf: file) == changed, "The nested change was not copied")
                try require(try Data(contentsOf: target.appendingPathComponent("unchanged.txt")) == unchanged, "A sibling was lost")
                let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
                try require(mode?.intValue == 0o640, "File permissions were not preserved")
                var metadata = Data(count: attribute.count)
                let count = metadata.withUnsafeMutableBytes { getxattr(file.path, "com.cachora.sample", $0.baseAddress, $0.count, 0, 0) }
                try require(count == attribute.count && metadata == attribute, "Extended attributes were not preserved")
                try require(!FileManager.default.fileExists(atPath: rejected.path), "Saving escaped the test home")
                try require(try Data(contentsOf: stored) == changed, "The stored directory was altered")
                try require(!FileManager.default.fileExists(atPath: source.path), "Saving recreated the original directory")
            }
        }),
        ("a replacement in Recovery cannot be exported as the original", {
            try await fixture("save-replaced-object") { f in
                let store = f.store()
                let entry = try await f.stage(f.file(), store: store)
                try Data("unrelated fixture file".utf8).write(to: f.object(entry.id), options: .atomic)
                let catalog = try await store.catalog()
                try require(catalog.entries.first?.state == .missing, "Replacement was offered as an export")
                let target = f.home.appendingPathComponent("Documents/replacement")
                try await expectFailure { try await store.saveCopy(entry.id, to: target) }
                try require(!FileManager.default.fileExists(atPath: target.path), "An unrelated object was exported")
            }
        }),
        ("permanent deletion requires explicit confirmation", {
            try await fixture("purge-confirmation") { f in
                let entry = try await f.stage(f.file()); let store = f.store()
                try await expectFailure { _ = try await store.purge(entry.id, confirmed: false) }
                try require(FileManager.default.fileExists(atPath: f.object(entry.id).path), "Unconfirmed purge changed files")
            }
        }),
        ("confirmed permanent deletion inside vault only", {
            try await fixture("purge") { f in
                _ = try f.file("folder/.hidden/a"); let folder = f.cache.appendingPathComponent("folder")
                let store = f.store(); let entry = try await f.stage(folder, store: store)
                _ = try await store.purge(entry.id, confirmed: true)
                try require(!FileManager.default.fileExists(atPath: f.object(entry.id).path), "Confirmed copy was not purged")
                let catalog = try await store.catalog()
                try require(catalog.entries.first?.state == .purged, "Purge state not saved")
                try await expectFailure { _ = try await store.restore(entry.id) }
            }
        }),
        ("journal failure before move preserves source", {
            try await fixture("journal-failure") { f in
                let source = try f.file()
                let store = f.store { if $0 == .beforePrepare { throw Failure(description: "injected journal failure") } }
                try await expectFailure { _ = try await f.stage(source, store: store) }
                try require(FileManager.default.fileExists(atPath: source.path), "Source changed before durable journal")
            }
        }),
        ("interrupted move reconciled after restart", {
            try await fixture("interrupted-move") { f in
                let source = try f.file()
                let interrupted = f.store { if $0 == .afterMove { throw Failure(description: "injected interruption") } }
                let entry = try await f.stage(source, store: interrupted)
                let restarted = f.store(); let catalog = try await restarted.catalog()
                try require(catalog.entries.first?.state == .stored, "Prepared journal was not reconciled")
                _ = try await restarted.restore(entry.id)
            }
        }),
        ("interrupted restore reconciled after restart", {
            try await fixture("interrupted-restore") { f in
                let source = try f.file(); let entry = try await f.stage(source)
                let interrupted = f.store { if $0 == .afterRestore { throw Failure(description: "injected interruption") } }
                _ = try await interrupted.restore(entry.id)
                let catalog = try await f.store().catalog()
                try require(catalog.entries.first?.state == .restored, "Interrupted restore was not reconciled")
                try require(FileManager.default.fileExists(atPath: source.path), "Restored source missing")
            }
        }),
        ("corrupt record retained with visible warning", {
            try await fixture("corrupt-record") { f in
                let entry = try await f.stage(f.file())
                try Data("not-json".utf8).write(to: f.record(entry.id))
                let catalog = try await f.store().catalog()
                try require(!catalog.warnings.isEmpty, "Corrupt record silently ignored")
                try require(FileManager.default.fileExists(atPath: f.object(entry.id).path), "Corrupt record caused deletion")
            }
        }),
        ("tampered record cannot restore outside approved roots", {
            try await fixture("tampered-record") { f in
                let entry = try await f.stage(f.file())
                var data = try JSONSerialization.jsonObject(with: Data(contentsOf: f.record(entry.id))) as! [String: Any]
                data["originalPath"] = f.outside.path
                try JSONSerialization.data(withJSONObject: data).write(to: f.record(entry.id))
                try await expectFailure { _ = try await f.store().restore(entry.id) }
                try await expectFailure { _ = try await f.store().purge(entry.id, confirmed: true) }
            }
        }),
        ("concurrent process lock refuses second writer", {
            try await fixture("lock") { f in
                let store = f.store(); _ = try await store.catalog()
                let fd = open(f.vault.appendingPathComponent("operation.lock").path, O_RDWR)
                guard fd >= 0 else { throw Failure(description: "No fixture lock") }
                defer { flock(fd, LOCK_UN); close(fd) }
                try require(flock(fd, LOCK_EX | LOCK_NB) == 0, "Fixture lock could not be acquired")
                try await expectFailure { _ = try await f.stage(f.file(), store: store) }
            }
        }),
        ("cancelled move preserves source", {
            try await fixture("cancel") { f in
                let source = try f.file(); let snapshot = RecoverySnapshot.capture(source.path)!
                let store = f.store()
                let task = Task {
                    while !Task.isCancelled { await Task.yield() }
                    return try await store.stage(path: source.path, name: "sample", category: "User Cache", bytes: 1, expected: snapshot)
                }
                task.cancel()
                try await expectFailure { _ = try await task.value }
                try require(FileManager.default.fileExists(atPath: source.path), "Cancelled operation moved source")
            }
        }),
        ("unwritable store preserves source", {
            try await fixture("unwritable") { f in
                let source = try f.file(); let store = f.store(); _ = try await store.catalog()
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: f.vault.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.vault.path) }
                try await expectFailure { _ = try await f.stage(source, store: store) }
                try require(FileManager.default.fileExists(atPath: source.path), "Permission failure changed source")
            }
        }),
        ("failed purge keeps recovery copy", {
            try await fixture("purge-failure") { f in
                let entry = try await f.stage(f.file())
                let store = f.store { if $0 == .beforePurge { throw Failure(description: "injected deletion failure") } }
                try await expectFailure { _ = try await store.purge(entry.id, confirmed: true) }
                try require(FileManager.default.fileExists(atPath: f.object(entry.id).path), "Failed purge lost recovery copy")
            }
        }),
        ("partial permanent deletion records failure and permits retry", {
            try await fixture("partial-purge") { f in
                _ = try f.file("folder/aaa.bin")
                let kept = try f.file("folder/zzz/keep.bin")
                let keptData = try Data(contentsOf: kept)
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: kept.deletingLastPathComponent().path)
                let store = f.store()
                let entry = try await f.stage(f.cache.appendingPathComponent("folder"), store: store)
                try await expectFailure { _ = try await store.purge(entry.id, confirmed: true) }
                let remaining = f.object(entry.id).appendingPathComponent("zzz/keep.bin")
                try require(try Data(contentsOf: remaining) == keptData, "Failed purge lost surviving data")
                let catalog = try await store.catalog()
                try require(catalog.entries.first?.state == .purgeFailed, "Partial purge was reported as complete")
                try require(catalog.entries.first?.canRestore == false, "Partial copy was offered as a complete restore")
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: remaining.deletingLastPathComponent().path)
                _ = try await store.purge(entry.id, confirmed: true)
                try require(!FileManager.default.fileExists(atPath: f.object(entry.id).path), "Retry did not finish fixture purge")
            }
        }),
        ("repeated restore cannot overwrite anything", {
            try await fixture("repeat-restore") { f in
                let source = try f.file(); let original = try Data(contentsOf: source)
                let store = f.store(); let entry = try await f.stage(source, store: store)
                _ = try await store.restore(entry.id)
                try await expectFailure { _ = try await store.restore(entry.id) }
                try require(try Data(contentsOf: source) == original, "Repeated restore changed original")
            }
        }),
        ("linked recovery root refused", {
            try await fixture("linked-store") { f in
                let source = try f.file()
                try FileManager.default.createSymbolicLink(at: f.vault, withDestinationURL: f.outside.deletingLastPathComponent())
                try await expectFailure { _ = try await f.stage(source) }
            }
        }),
        ("both temporary path spellings survive staging and reloading", {
            try await fixture("system-alias") { _ in
                let name = "PureMac-Recovery-Alias-\(UUID().uuidString)"
                let home = URL(fileURLWithPath: "/private/tmp/" + name, isDirectory: true)
                let alias = URL(fileURLWithPath: "/tmp/" + name, isDirectory: true)
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: home) }
                let cache = home.appendingPathComponent("cache")
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
                let source = cache.appendingPathComponent("sample.bin")
                let bytes = Data("DISPOSABLE-ALIAS-TEST".utf8); try bytes.write(to: source)
                guard let expected = RecoverySnapshot.capture(source.path) else { throw Failure(description: "System alias could not be measured") }
                let vault = home.appendingPathComponent("recovery")
                let store = RecoveryStore(root: vault, allowedRoots: [alias.appendingPathComponent("cache")])
                for prefix in [home.path, alias.path] {
                    let path = prefix + "/cache/sample.bin"
                    let entry = try await store.stage(path: path, name: "sample", category: "User Cache",
                                                      bytes: Int64(bytes.count), expected: expected).entry
                    try require(entry.originalPath == path && !FileManager.default.fileExists(atPath: source.path),
                                "Staging did not retain the original spelling and move the sample")
                    let reopened = RecoveryStore(root: alias.appendingPathComponent("recovery"), allowedRoots: [cache])
                    _ = try await reopened.restore(entry.id)
                    try require(try Data(contentsOf: source) == bytes, "System alias restore failed")
                }
                try await expectFailure {
                    _ = try await store.stage(path: cache.path + "/../cache/sample.bin", name: "sample",
                                              category: "User Cache", bytes: Int64(bytes.count), expected: expected)
                }
                try require(try Data(contentsOf: source) == bytes, "Rejected traversal changed the sample")
            }
        }),
    ] }
}
