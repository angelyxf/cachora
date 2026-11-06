import AppKit
import Foundation

#if canImport(XCTest)
import XCTest
@testable import PureMac
final class CleaningRecoveryIntegrationTests: XCTestCase {
    @MainActor func testCleanupRecoveryIntegration() async throws {
        for (_, test) in CleaningRecoveryChecks.cases { try await test() }
    }
}
#elseif PUREMAC_RECOVERY_INTEGRATION_TEST_RUNNER
@main
enum CleaningRecoveryTestRunner {
    @MainActor static func main() async {
        var failed = 0
        for (name, test) in CleaningRecoveryChecks.cases {
            do { try await test(); print("PASS: \(name)") }
            catch { failed += 1; print("FAIL: \(name): \(error)") }
        }
        print("Cleanup integration checks: \(CleaningRecoveryChecks.cases.count - failed)/\(CleaningRecoveryChecks.cases.count) passed; fixture homes only.")
        if failed > 0 { exit(1) }
    }
}
#endif

@MainActor
enum CleaningRecoveryChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw RecoveryChecks.Failure(description: message) }
    }

    static func environment(_ f: RecoveryChecks.Fixture, blocked: String? = nil) -> CleanupEnvironment {
        CleanupEnvironment(home: f.home, recoveryRoot: f.vault, isFixture: true, blockedReason: blocked)
    }

    static func item(_ path: URL, selected: Bool = true, category: CleaningCategory = .userCache) -> CleanableItem {
        CleanableItem(name: path.lastPathComponent, path: path.path, size: 4096,
                      category: category, isSelected: selected, lastModified: nil)
    }

    static func waitUntilIdle(_ state: AppState) async throws {
        for _ in 0..<500 {
            if !state.scanState.isActive { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw RecoveryChecks.Failure(description: "Operation did not finish")
    }

    static var cases: [(String, @MainActor () async throws -> Void)] { [
        ("engine cleanup records recoverable bytes, not freed bytes", {
            try await RecoveryChecks.fixture("engine-space") { f in
                let source = try f.file(); let store = f.store()
                let engine = CleaningEngine(homeDirectory: f.home, recoveryStore: store, fixtureBoundary: f.home)
                let result = await engine.cleanItems([item(source)]) { _ in }
                try require(result.errors.isEmpty && result.itemsCleaned == 1, "Recoverable cleanup failed")
                try require(result.freedSpace == 0 && result.recoverableBytes == 4096, "Retained files were reported as freed space")
                _ = try await store.restore(result.recoveryEntries[0].id)
            }
        }),
        ("engine mixed success preserves failed and outside items", {
            try await RecoveryChecks.fixture("engine-partial") { f in
                let good = try f.file("good.bin"), bad = try f.file("changed.bin")
                let stale = item(bad); try Data("CHANGED".utf8).write(to: bad)
                let engine = CleaningEngine(homeDirectory: f.home, recoveryStore: f.store(), fixtureBoundary: f.home)
                let result = await engine.cleanItems([item(good), stale, item(f.outside)]) { _ in }
                try require(result.itemsCleaned == 1 && result.errors.count == 2, "Mixed outcome was not reported correctly")
                try require(FileManager.default.fileExists(atPath: bad.path), "Failed source changed")
                try require(result.requiresAdmin.isEmpty, "Recovery requested administrator deletion")
            }
        }),
        ("engine refuses virtual and app modification actions", {
            try await RecoveryChecks.fixture("engine-actions") { f in
                let source = try f.file()
                let virtual = CleanableItem(name: "action", path: "", size: 999, category: .dockerCache, isSelected: true, lastModified: nil)
                let engine = CleaningEngine(homeDirectory: f.home, recoveryStore: f.store(), fixtureBoundary: f.home)
                let result = await engine.cleanItems([virtual, item(source, category: .universalBinaries)]) { _ in }
                try require(result.itemsCleaned == 0 && result.errors.count == 2, "Unrecoverable actions were executed")
                try require(FileManager.default.fileExists(atPath: source.path), "Unsupported item changed")
            }
        }),
        ("parent and child selection moves only one recovery object", {
            try await RecoveryChecks.fixture("engine-overlap") { f in
                let child = try f.file("folder/child.bin"), folder = f.cache.appendingPathComponent("folder")
                let engine = CleaningEngine(homeDirectory: f.home, recoveryStore: f.store(), fixtureBoundary: f.home)
                let result = await engine.cleanItems([item(child), item(folder)]) { _ in }
                try require(result.itemsCleaned == 1 && result.recoveryEntries.count == 1 && result.errors.isEmpty, "Overlapping selection was duplicated")
                try require(result.cleanedPaths.contains(child.path) && result.cleanedPaths.contains(folder.path), "Child selection was left stale")
            }
        }),
        ("changed nested directory file blocks cleanup", {
            try await RecoveryChecks.fixture("engine-nested-change") { f in
                let child = try f.file("folder/deep/child.bin"), folder = f.cache.appendingPathComponent("folder")
                let reviewed = item(folder)
                try Data("MODIFIED-NESTED-DATA".utf8).write(to: child)
                let engine = CleaningEngine(homeDirectory: f.home, recoveryStore: f.store(), fixtureBoundary: f.home)
                let result = await engine.cleanItems([reviewed]) { _ in }
                try require(result.itemsCleaned == 0 && !result.errors.isEmpty, "Changed nested file was moved")
                try require(FileManager.default.fileExists(atPath: child.path), "Changed nested file vanished")
            }
        }),
        ("AppState clean category then restore preserves selection and diagnostics", {
            try await RecoveryChecks.fixture("app-state") { f in
                let chosen = try f.file("chosen.bin"), keep = try f.file("keep.bin")
                let state = AppState(performStartupTasks: false, cleanupEnvironment: environment(f))
                let selected = item(chosen), unselected = item(keep, selected: false)
                let issue = ScanIssue(path: f.cache.appendingPathComponent("unreadable").path, kind: .permissionDenied, detail: "fixture")
                state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [selected, unselected], totalSize: 8192, issues: [issue])
                state.cleanCategory(.userCache, itemIDs: [selected.id])
                try await waitUntilIdle(state)
                try require(state.lastRecoveryMovedCount == 1 && state.totalFreedSpace == 0, "AppState lost recovery totals")
                try require(state.categoryResults[.userCache]?.items.count == 1 && state.scanIssues.count == 1, "Remaining selection or issues lost")
                try require(FileManager.default.fileExists(atPath: keep.path), "Unselected test file was moved")
                guard let entry = state.recoveryCenter.entries.first else { throw RecoveryChecks.Failure(description: "Recovery entry absent from UI model") }
                await state.recoveryCenter.restore(entry.id)
                try require(state.recoveryCenter.error == nil && FileManager.default.fileExists(atPath: chosen.path), "UI model restoration failed")
            }
        }),
        ("AppState clean all honors explicit IDs", {
            try await RecoveryChecks.fixture("app-all") { f in
                let a = try f.file("a.bin"), b = try f.file("b.bin")
                let first = item(a), second = item(b)
                let state = AppState(performStartupTasks: false, cleanupEnvironment: environment(f))
                state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [first, second], totalSize: 8192)
                state.cleanAll(itemIDs: [first.id]); try await waitUntilIdle(state)
                try require(state.lastRecoveryMovedCount == 1 && FileManager.default.fileExists(atPath: b.path), "Clean all ignored reviewed selection")
            }
        }),
        ("recovery UI model shows conflict without changing either copy", {
            try await RecoveryChecks.fixture("model-conflict") { f in
                let source = try f.file(); let entry = try await f.stage(source)
                let newer = Data("NEW-COPY".utf8); try newer.write(to: source)
                let model = RecoveryCenterModel(store: f.store()); await model.refresh()
                await model.restore(entry.id)
                try require(model.error != nil && model.entries.first?.canRestore == true, "Conflict not visible or copy no longer restorable")
                try require(try Data(contentsOf: source) == newer, "Model overwrote newer file")
            }
        }),
        ("recovery UI model purge requires confirmation", {
            try await RecoveryChecks.fixture("model-purge") { f in
                let source = try f.file(); let entry = try await f.stage(source)
                let model = RecoveryCenterModel(store: f.store()); await model.refresh()
                await model.purge(entry.id, confirmed: false)
                try require(model.error != nil && FileManager.default.fileExists(atPath: f.object(entry.id).path), "UI model accepted unconfirmed purge")
                await model.purge(entry.id, confirmed: true)
                try require(model.error == nil && model.entries.first?.state == .purged, "UI model did not record confirmed purge")
            }
        }),
        ("invalid fixture configuration blocks scan and cleanup", {
            try await RecoveryChecks.fixture("invalid-fixture") { f in
                let source = try f.file(); let row = item(source)
                let state = AppState(performStartupTasks: false, cleanupEnvironment: environment(f, blocked: "fixture invalid"))
                state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [row], totalSize: 4096)
                state.startSmartScan(); state.cleanAll(); state.cleanCategory(.userCache)
                try require(state.scanState == .idle && FileManager.default.fileExists(atPath: source.path), "Invalid fixture fell back to normal operations")
            }
        }),
        ("optional AI history can recover while models stay protected", {
            try await RecoveryChecks.fixture("ai-history") { f in
                let history = f.home.appendingPathComponent(".ollama/history")
                let model = f.home.appendingPathComponent(".ollama/models/model.bin")
                try FileManager.default.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("DUMMY-PROMPT-HISTORY".utf8).write(to: history)
                let modelData = Data("DUMMY-MODEL-KEEP".utf8); try modelData.write(to: model)
                let store = RecoveryStore(root: f.vault, allowedRoots: CleaningEngine.recoveryRoots(home: f.home),
                    allowedRootItems: CleaningEngine.recoveryRootItems(home: f.home))
                let engine = CleaningEngine(homeDirectory: f.home, recoveryStore: store, fixtureBoundary: f.home)
                let result = await engine.cleanItems([item(history, category: .aiApps), item(model, category: .aiApps)]) { _ in }
                try require(result.itemsCleaned == 1 && result.errors.count == 1, "AI allowlist lost its boundary")
                try require(try Data(contentsOf: model) == modelData, "Model data changed")
                _ = try await store.restore(result.recoveryEntries[0].id)
                try require(FileManager.default.fileExists(atPath: history.path), "Optional history did not restore")
            }
        }),
        ("container document cannot masquerade as an application cache", {
            try await RecoveryChecks.fixture("container-boundary") { f in
                let document = f.home.appendingPathComponent("Library/Containers/example/Data/Documents/private.txt")
                try FileManager.default.createDirectory(at: document.deletingLastPathComponent(), withIntermediateDirectories: true)
                let contents = Data("DUMMY-CONTAINER-DOCUMENT".utf8); try contents.write(to: document)
                let engine = CleaningEngine(homeDirectory: f.home, recoveryStore: f.store(), fixtureBoundary: f.home)
                let result = await engine.cleanItems([item(document)]) { _ in }
                try require(result.itemsCleaned == 0 && !result.errors.isEmpty, "Container document was accepted as cache")
                try require(try Data(contentsOf: document) == contents, "Container document changed")
            }
        }),
    ] }
}
