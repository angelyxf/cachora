import Foundation

#if canImport(XCTest)
import XCTest
@testable import PureMac
final class ReleaseReadinessTests: XCTestCase {
    @MainActor func testReleaseBoundaries() async throws {
        for (_, test) in ReleaseChecks.cases { try await test() }
    }
}
#elseif PUREMAC_RELEASE_TEST_RUNNER
@main enum ReleaseTestRunner {
    @MainActor static func main() async {
        var failures = 0
        for (name, test) in ReleaseChecks.cases {
            do { try await test(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("Release checks: \(ReleaseChecks.cases.count - failures)/\(ReleaseChecks.cases.count) passed.")
        if failures > 0 { exit(1) }
    }
}
#endif

private actor PhotoAnalysisUpdates {
    private(set) var progress: [SimilarPhotoScanProgress] = []

    func record(_ update: SimilarPhotoScanProgress) { progress.append(update) }
}

@MainActor enum ReleaseChecks {
    static let channel = AppReleaseChannel(repository: "example-owner/cleaner-beta", assetPrefix: "CleanerBeta", includesPrereleases: true)!
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw RecoveryChecks.Failure(description: message) }
    }
    static func data(tag: String = "v0.2.0-beta.1", url: String? = nil, asset: String = "CleanerBeta-0.2.0-beta.1.zip",
                     draft: Bool = false, prerelease: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: [["tag_name": tag,
            "html_url": url ?? "https://github.com/example-owner/cleaner-beta/releases/tag/\(tag)",
            "assets": [["name": asset]], "draft": draft, "prerelease": prerelease]])
    }
    static func rejects(_ data: Data, channel: AppReleaseChannel = channel) -> Bool {
        (try? UpdateService.latestAppRelease(in: data, channel: channel)) == nil
    }
    static var cases: [(String, @MainActor () async throws -> Void)] { [
        ("stable releases refuse scheduled file moves and defer scheduled scans during duplicate moves", {
            try await RecoveryChecks.fixture("stable-manual-review") { f in
                let sample = try f.file()
                let before = try Data(contentsOf: sample)
                let environment = CleanupEnvironment(home: f.home, recoveryRoot: f.vault, isFixture: true, blockedReason: nil)
                let state = AppState(performStartupTasks: false, cleanupEnvironment: environment)
                let item = CleanableItem(name: sample.lastPathComponent, path: sample.path, size: Int64(before.count),
                                         category: .userCache, isSelected: true, lastModified: nil)
                state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [item], totalSize: item.size)
                state.cleanAll(itemIDs: [item.id], scheduled: true)
                try require(state.scanState == .idle && state.lastRecoveryMovedCount == 0,
                            "Scheduled cleanup started without manual review")
                state.duplicateMoveInProgress = true
                try require(!state.canRunScheduledScan(isAppActive: false), "A scheduled scan interrupted duplicate file moves")
                state.duplicateMoveInProgress = false
                try require(try Data(contentsOf: sample) == before, "Scheduled cleanup changed the sample")
            }
        }),
        ("stable uninstall preserves items that require administrator removal", {
            try await RecoveryChecks.fixture("stable-no-admin-fallback") { f in
                let sample = try f.file()
                let before = try Data(contentsOf: sample)
                let environment = CleanupEnvironment(home: f.home, recoveryRoot: f.vault, isFixture: false, blockedReason: nil)
                let state = AppState(performStartupTasks: false,
                    appFileTrasher: { urls, completion in completion([], false, urls, []) }, cleanupEnvironment: environment)
                state.selectedFiles = [sample]
                state.removeSelectedFiles(confirmedURLs: [sample])
                for _ in 0..<100 where state.isRemovingAppFiles { try await Task.sleep(nanoseconds: 10_000_000) }
                try require(!state.isRemovingAppFiles && state.selectedFiles.contains(sample),
                            "Administrator-only item was not retained as failed")
                let after = try Data(contentsOf: sample)
                try require(state.removalError != nil && after == before,
                            "A failed Trash move was replaced by administrator deletion")
            }
        }),
        ("duplicate cancellation reports completed moves and keeps all remaining files", {
            try await RecoveryChecks.fixture("duplicate-partial-cancel") { f in
                let folder = f.home.appendingPathComponent("Duplicates")
                let bytes = Data(repeating: 63, count: 8192)
                let files = try duplicateSamples(["00-keep.txt", "01-copy.txt", "02-copy.txt"], bytes: bytes, in: folder)
                let environment = CleanupEnvironment(home: f.home, recoveryRoot: f.vault, isFixture: true, blockedReason: nil)
                let trash = try requireSampleTrash(environment)
                let finder = DuplicateFinder(trashHandler: { url in
                    try trash(url)
                    withUnsafeCurrentTask { $0?.cancel() }
                })
                let scan = try await finder.scan(folder: folder)
                let group = try duplicateGroup(in: scan, containing: files[0])
                let task = Task { try await finder.moveToTrash(group: group, selectedIDs: Set(files.dropFirst())) }
                let report = try await task.value
                try require(report.cancelled && report.trashedFiles.map(\.url) == [files[1]],
                            "Cancellation discarded the partial move report")
                try require(!FileManager.default.fileExists(atPath: files[1].path), "Completed copy was not moved")
                try require(try Data(contentsOf: files[0]) == bytes && Data(contentsOf: files[2]) == bytes,
                            "Cancellation changed the keeper or a remaining file")
                let remaining = try await DuplicateFinder().scan(folder: folder)
                try require(remaining.groups.count == 1 && remaining.duplicateFileCount == 2,
                            "Remaining duplicates were not available for a fresh review")
            }
        }),
        ("duplicate cancellation during final verification retains the completed move", {
            try await RecoveryChecks.fixture("duplicate-final-cancel") { f in
                let folder = f.home.appendingPathComponent("Duplicates")
                let bytes = Data(repeating: 64, count: 8192)
                let files = try duplicateSamples(["00-keep.txt", "01-copy.txt"], bytes: bytes, in: folder)
                let environment = CleanupEnvironment(home: f.home, recoveryRoot: f.vault, isFixture: true, blockedReason: nil)
                let trash = try requireSampleTrash(environment)
                let finder = DuplicateFinder(trashHandler: { url in
                    try trash(url)
                    withUnsafeCurrentTask { $0?.cancel() }
                })
                let scan = try await finder.scan(folder: folder)
                let group = try duplicateGroup(in: scan, containing: files[0])
                let task = Task { try await finder.moveToTrash(group: group, selectedIDs: [files[1]]) }
                let report = try await task.value
                try require(report.cancelled && report.trashedFiles.map(\.url) == [files[1]],
                            "Cancellation after the last move discarded its result")
                try require(try Data(contentsOf: files[0]) == bytes, "The retained original changed")
            }
        }),
        ("dashboard shows the latest completed activity without a future timestamp", {
            let now = Date(timeIntervalSince1970: 1_900_000_000)
            let older = now.addingTimeInterval(-180)
            let recent = now.addingTimeInterval(-1)
            let format = String(localized: "Last activity: %@")
            let justNow = String(format: format, String(localized: "Just now"))
            try require(DashboardView.lastCareText(lastScan: nil, lastCleanup: nil, relativeTo: now)
                        == String(localized: "No scan run yet"), "Missing activity did not show the empty state")
            try require(DashboardView.lastCareText(lastScan: recent, lastCleanup: older, relativeTo: now) == justNow,
                        "An older cleanup hid the latest scan")
            try require(DashboardView.lastCareText(lastScan: older, lastCleanup: recent, relativeTo: now) == justNow,
                        "An older scan hid the latest cleanup")
            try require(DashboardView.lastCareText(lastScan: now.addingTimeInterval(1), lastCleanup: nil,
                                                  relativeTo: now) == justNow, "A clock difference showed a future timestamp")
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            let past = formatter.localizedString(for: older, relativeTo: now)
            try require(DashboardView.lastCareText(lastScan: older, lastCleanup: nil, relativeTo: now)
                        == String(format: format, past), "An older activity still showed just now")
        }),
        ("scheduled scan stays off until enabled and retries a busy scan", {
            let scheduler = SchedulerService(defaults: nil)
            defer { scheduler.stop() }
            let due = Date(timeIntervalSince1970: 1_900_000_000)
            var calls = 0
            scheduler.setTrigger {
                calls += 1
                return calls > 1
            }
            scheduler.config.nextRunDate = due
            await scheduler.runIfDue(at: due)
            try require(calls == 0, "An unapproved schedule fired")

            scheduler.toggleEnabled(true)
            scheduler.updateSchedule(interval: .hours1)
            try require(scheduler.config.nextRunDate.map { $0 > Date() } == true, "Enabling did not set a future date")
            scheduler.config.nextRunDate = due
            await scheduler.runIfDue(at: due.addingTimeInterval(-1))
            try require(calls == 0, "The scan ran before its deadline")
            await scheduler.runIfDue(at: due)
            try require(calls == 1 && scheduler.config.lastRunDate == nil && scheduler.config.nextRunDate == due,
                        "The busy scan was recorded as completed")
            let retry = due.addingTimeInterval(60)
            await scheduler.runIfDue(at: retry)
            try require(calls == 2 && scheduler.config.lastRunDate == retry
                        && scheduler.config.nextRunDate == retry.addingTimeInterval(3600), "Retry did not update the schedule")
            scheduler.toggleEnabled(false)
            try require(scheduler.config.nextRunDate == nil, "A disabled schedule retained a pending run")
        }),
        ("the scheduled scan lists a test cache without moving it", {
            try await RecoveryChecks.fixture("schedule-review-only") { f in
                let sample = f.cache.appendingPathComponent("scheduled-sample.bin")
                let data = Data(repeating: 41, count: 4096)
                try data.write(to: sample)
                let scheduler = SchedulerService(defaults: nil)
                scheduler.config.isEnabled = true
                scheduler.config.categoriesToScan = [.userCache]
                scheduler.config.autoClean = true
                scheduler.config.minimumCleanSize = 1
                let environment = CleanupEnvironment(home: f.home, recoveryRoot: f.vault, isFixture: false, blockedReason: nil)
                let state = AppState(performStartupTasks: false, cleanupEnvironment: environment, scheduler: scheduler)
                state.showCleanConfirmation = true
                let whileReviewing = await state.runScheduledScan()
                try require(!whileReviewing && state.scanState == .idle, "Scheduled scan interrupted a review")
                state.showCleanConfirmation = false
                let completed = await state.runScheduledScan()
                try require(completed && state.categoryResults[.userCache]?.items.contains(where: { $0.path == sample.path }) == true,
                            "Scheduled scan did not report the test cache")
                try require(try Data(contentsOf: sample) == data && state.lastRecoveryMovedCount == 0,
                            "Scheduled scan moved files")
            }
        }),
        ("normal scans skip generated test folders and keep neighboring files visible", {
            try await RecoveryChecks.fixture("normal-scan-skips-test-workspaces") { f in
                let local = f.home.appendingPathComponent("Documents/Cachora/build-local")
                let folders = ["test-workspaces", ".retired-test-artifacts", "test-workspaces-not-a-fixture"]
                for folder in folders {
                    let base = local.appendingPathComponent(folder)
                    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                    let file = base.appendingPathComponent("old-test.bin")
                    try Data([1]).write(to: file)
                    let handle = try FileHandle(forWritingTo: file)
                    try handle.truncate(atOffset: 12 * 1024 * 1024)
                    try handle.close()
                    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 978307200)],
                                                          ofItemAtPath: file.path)
                }
                let result = await ScanEngine(homeDirectory: f.home).scanCategory(.largeFiles)
                try require(result.items.map(\.path) == [local.appendingPathComponent(folders[2] + "/old-test.bin").path],
                            "Normal scan included generated test data or skipped an adjacent folder")
                try require(CleanupExclusions.isGeneratedTestRoot("/private/tmp/cachora-fixture-a_fwgcnn")
                            && CleanupExclusions.isGeneratedTestRoot("/tmp/cachora-ui-nx0569bc")
                            && !CleanupExclusions.isGeneratedTestRoot("/private/tmp/cachora-fixture-report.txt"),
                            "Temporary workspace detection did not respect the generated names")
            }
        }),
        ("unconfigured updates never contact a server", {
            var calls = 0
            let service = UpdateService(currentVersion: "0.1.0-beta.1", channel: nil) { _ in
                calls += 1; throw URLError(.badURL)
            }
            await service.check()
            try require(calls == 0, "Unconfigured update contacted a server")
            guard case .failed = service.state else { throw RecoveryChecks.Failure(description: "Missing configuration was called current") }
        }),
        ("upstream and malformed repository configurations refused", {
            for repository in ["momenbasel/PureMac", "momenbasel/puremac", "owner/repo/extra", "https://github.com/a/b", "owner/repo?token=x", ""] {
                try require(AppReleaseChannel(repository: repository, assetPrefix: "CleanerBeta") == nil, "Unsafe repository accepted")
            }
        }),
        ("beta channel accepts its own beta and stable releases", {
            try require(try !rejects(data()), "Own beta rejected")
            try require(try !rejects(data(tag: "v0.2.0", prerelease: false)), "Own stable rejected")
            try require(try rejects(data(draft: true)), "Draft accepted")
        }),
        ("stable channel excludes prereleases", {
            let stable = AppReleaseChannel(repository: channel.repository, assetPrefix: channel.assetPrefix)!
            try require(try rejects(data(), channel: stable), "Stable channel accepted beta")
        }),
        ("forged and upstream release URLs refused", {
            for url in ["https://github.com/momenbasel/PureMac/releases/tag/v0.2.0-beta.1",
                        "https://example.com/example-owner/cleaner-beta/releases/tag/v0.2.0-beta.1",
                        "https://user@github.com/example-owner/cleaner-beta/releases/tag/v0.2.0-beta.1",
                        "https://github.com/example-owner/cleaner-beta/releases/tag/v9.9.9",
                        "https://github.com/example-owner/cleaner-beta/releases/tag/v0.2.0-beta.1?redirect=1"] {
                try require(try rejects(data(url: url)), "Untrusted release URL accepted")
            }
        }),
        ("CLI fixtures and upstream artifacts refused", {
            for name in ["PureMac-0.2.0.zip", "CleanerBeta-cli.zip", "CleanerBeta-fixture.zip", "CleanerBeta-0.2.0-source.zip", "CleanerBeta-0.2.0-arm64-local-preview.zip", "CleanerBeta-0.2.0-arm64-LOCAL-PREVIEW.dmg", "CleanerBeta-0.2.0-unsigned.dmg", "CleanerBeta-0.2.0.txt", "../CleanerBeta-0.2.0.zip"] {
                try require(try rejects(data(asset: name)), "Wrong product artifact accepted")
            }
        }),
        ("numeric newest version wins over order of releases", {
            let first = try JSONSerialization.jsonObject(with: data(tag: "v0.9.0")) as! [[String: Any]]
            let second = try JSONSerialization.jsonObject(with: data(tag: "v0.10.0")) as! [[String: Any]]
            let combined = try JSONSerialization.data(withJSONObject: first + second)
            try require(try UpdateService.latestAppRelease(in: combined, channel: channel).tagName == "v0.10.0", "Lexical update ordering")
        }),
        ("network update checks only independent repository", {
            let service = UpdateService(currentVersion: "0.1.0-beta.1", channel: channel) { request in
                try require(request.url == channel.apiURL, "Wrong update endpoint")
                return (try data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            await service.check()
            guard case .available = service.state else { throw RecoveryChecks.Failure(description: "New beta not offered") }
        }),
        ("offline update errors remain errors on retry", {
            var calls = 0
            let service = UpdateService(currentVersion: "0.1.0-beta.1", channel: channel) { _ in
                calls += 1; throw URLError(.notConnectedToInternet)
            }
            await service.check(); await service.check()
            try require(calls == 2, "Retry did not execute")
            guard case .failed = service.state else { throw RecoveryChecks.Failure(description: "Offline was called current") }
        }),
        ("a failed Homebrew recheck locks the old selection until it is refreshed", {
            let sample = SampleBrew([
                .check([.first]), .info(["sample-a"]), .failedCheck,
                .check([.changedFirst]), .info(["sample-a"]), .upgrade(["sample-a"]), .check([]),
            ])
            let updater = sample.updater()
            await updater.checkForUpdates()
            updater.setSelected(true, token: "sample-a")
            let previous = updater.selectedUpdates
            let checkedAt = updater.lastCheckedAt
            try require(updater.canUpgradeSelection && checkedAt != nil, "The fresh sample could not be selected")

            await updater.checkForUpdates()
            try require(updater.phase == .checkFailed("Sample check failed") && !updater.canUpgradeSelection,
                        "A failed recheck left the sample actionable")
            try require(updater.updates == previous && updater.lastCheckedAt == checkedAt,
                        "The previous result was not retained for reference")
            await updater.upgrade(previous)

            await updater.checkForUpdates()
            try require(updater.canUpgradeSelection && updater.selectedUpdates.first?.currentVersion == "3.0",
                        "A successful retry did not restore the selection with its current version")
            await updater.upgrade(previous)
            await updater.upgrade(updater.selectedUpdates)
            try require(updater.phase == .completed(1) && updater.updates.isEmpty && !updater.canUpgradeSelection,
                        "A verified upgrade did not clear the sample update")
            try await sample.requireComplete()
        }),
        ("a Homebrew upgrade failure has its own state and requires rechecking", {
            let sample = SampleBrew([
                .check([.first]), .info(["sample-a"]), .upgrade(["sample-a"], failed: true),
            ])
            let updater = sample.updater()
            await updater.checkForUpdates()
            updater.setSelected(true, token: "sample-a")
            let selection = updater.selectedUpdates
            await updater.upgrade(selection)
            try require(updater.phase == .upgradeFailed("Sample upgrade failed") && !updater.canUpgradeSelection,
                        "An upgrade failure was misclassified or left the previous result actionable")
            await updater.upgrade(selection)
            try await sample.requireComplete()
        }),
        ("Homebrew upgrade success without verification stays unconfirmed", {
            let sample = SampleBrew([
                .check([.first]), .info(["sample-a"]), .upgrade(["sample-a"]), .failedCheck,
            ])
            let updater = sample.updater()
            await updater.checkForUpdates()
            updater.setSelected(true, token: "sample-a")
            let selection = updater.selectedUpdates
            await updater.upgrade(selection)
            try require(updater.phase == .needsVerification("Sample check failed") && !updater.canUpgradeSelection,
                        "An unverified upgrade was called complete or left the previous result actionable")
            await updater.upgrade(selection)
            try await sample.requireComplete()
        }),
        ("Homebrew reports remaining updates and retains only fresh selections", {
            let sample = SampleBrew([
                .check([.first, .second]), .info(["sample-a", "sample-b"]), .upgrade(["sample-a", "sample-b"]),
                .check([.second]), .info(["sample-b"]),
            ])
            let updater = sample.updater()
            await updater.checkForUpdates()
            updater.setSelected(true, token: "sample-a")
            updater.setSelected(true, token: "sample-b")
            await updater.upgrade(updater.selectedUpdates)
            try require(updater.phase == .updatesRemaining(1) && updater.canUpgradeSelection,
                        "The remaining sample was not distinguished from a complete upgrade")
            try require(updater.selectedUpdates.map(\.token) == ["sample-b"], "The completed sample was still selected")
            try await sample.requireComplete()
        }),
        ("a changed Homebrew executable invalidates its previous confirmation", {
            let sample = SampleBrew([.check([.first]), .info(["sample-a"])])
            var detected: URL? = SampleBrew.executable
            let updater = sample.updater(locateBrew: { detected })
            await updater.checkForUpdates()
            updater.setSelected(true, token: "sample-a")
            let selection = updater.selectedUpdates
            detected = nil
            await updater.upgrade(selection)
            try require(!updater.isHomebrewAvailable && !updater.canUpgradeSelection && updater.updates.isEmpty,
                        "The previous confirmation survived Homebrew becoming unavailable")
            try await sample.requireComplete()
        }),
        ("fixture scans its own system samples and refuses links and external moves", {
            try await RecoveryChecks.fixture("fixture-scan-scope") { f in
                let home = XcodeBuildMCPDerivedDataSupport.canonicalHomeDirectory(f.home)
                let fixture = CleanupEnvironment(home: home, recoveryRoot: f.vault, isFixture: true, blockedReason: nil)
                let log = home.appendingPathComponent("Library/Logs/test.log")
                try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = Data(repeating: 42, count: 4096)
                try data.write(to: log)
                let link = log.deletingLastPathComponent().appendingPathComponent("linked-log")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.outside)
                let state = AppState(performStartupTasks: false, cleanupEnvironment: fixture)
                state.scanSingleCategory(.systemJunk)
                for _ in 0..<500 where state.scanState.isActive { try await Task.sleep(nanoseconds: 10_000_000) }
                try require(state.categoryResults[.systemJunk]?.items.map(\.path) == [log.path],
                            "Fixture system scan did not stay inside its sample directory")
                let trash = try requireSampleTrash(fixture)
                try await RecoveryChecks.expectFailure { try trash(f.outside) }
                try await RecoveryChecks.expectFailure { try trash(link) }
                try trash(log)
                try require(!FileManager.default.fileExists(atPath: log.path), "Sample did not move")
                let moved = try FileManager.default.contentsOfDirectory(at: f.root.appendingPathComponent("sample-trash"),
                                                                       includingPropertiesForKeys: nil)
                try require(moved.count == 1, "Sample Trash did not retain the selected item")
                let bytes = try Data(contentsOf: moved[0].appendingPathComponent("test.log"))
                try require(bytes == data, "Sample bytes were not retained")
                try require(try Data(contentsOf: f.outside) == f.preserved, "External sentinel changed")
            }
        }),
        ("duplicate bulk selection keeps one chosen file in each group", {
            try await RecoveryChecks.fixture("fixture-duplicate-bulk") { f in
                let home = XcodeBuildMCPDerivedDataSupport.canonicalHomeDirectory(f.home)
                let environment = CleanupEnvironment(home: home, recoveryRoot: f.vault, isFixture: true, blockedReason: nil)
                let folder = home.appendingPathComponent("Duplicates")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let firstGroup = ["01-original.txt", "02-copy.txt", "03-copy.txt"].map { folder.appendingPathComponent($0) }
                let secondGroup = ["01-notes.txt", "02-notes.txt"].map { folder.appendingPathComponent($0) }
                let firstBytes = Data("matching report contents".utf8)
                let secondBytes = Data("matching notes".utf8)
                for (index, url) in (firstGroup + secondGroup).enumerated() {
                    try (firstGroup.contains(url) ? firstBytes : secondBytes).write(to: url)
                    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_600_000_000 + index))],
                                                          ofItemAtPath: url.path)
                }
                let finder = DuplicateFinder(trashHandler: try requireSampleTrash(environment))
                let result = try await finder.scan(folder: folder)
                guard result.groups.count == 2, let group = result.groups.first(where: { $0.contains(firstGroup[0]) }),
                      let custom = group.files.first(where: { $0.url == firstGroup[1] }) else {
                    throw RecoveryChecks.Failure(description: "The two duplicate sample groups did not scan")
                }
                try require(group.keeper.url == firstGroup[0], "The oldest sample was not recommended")
                var selection = DuplicateSelection()
                try require(selection.urls.isEmpty, "Scanning selected copies automatically")
                selection.toggleCopies(in: group)
                try require(selection.urls == Set(firstGroup.dropFirst()), "Group selection affected other files")
                selection.selectAll(in: result.groups)
                try require(selection.urls == [firstGroup[1], firstGroup[2], secondGroup[1]], "Select all included a recommended keeper")
                selection.keep(custom, in: group)
                selection.setSelected(true, url: custom.url, in: group)
                try require(selection.urls == [firstGroup[2], secondGroup[1]], "Changing the keeper selected the former keeper or allowed the new keeper to be selected")
                selection.clear()
                try require(selection.urls.isEmpty && selection.keeper(in: group) == custom,
                            "Clearing selections reset the keeper")
                selection.selectAll(in: result.groups)
                let review = selection.groupsForReview(in: result.groups)
                try require(Set(review.map(\.keeper.url)) == [firstGroup[1], secondGroup[0]], "The review lost the chosen keepers")
                let expected = Set([firstGroup[0], firstGroup[2], secondGroup[1]])
                try require(selection.urls == expected, "Select all ignored the chosen keeper")
                var moved: Set<URL> = []
                for group in review {
                    let report = try await finder.moveToTrash(group: group, selectedIDs: Set(group.files.dropFirst().map(\.url)))
                    try require(report.failures.isEmpty, "A reviewed copy failed to move")
                    moved.formUnion(report.trashedFiles.map(\.url))
                }
                try require(moved == expected && expected.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
                            "The files moved differed from the reviewed files")
                try require(try Data(contentsOf: firstGroup[1]) == firstBytes && Data(contentsOf: secondGroup[0]) == secondBytes,
                            "A kept sample changed")
                let rescanned = try await finder.scan(folder: folder)
                try require(rescanned.groups.isEmpty, "The folder still has exact duplicates")
            }
        }),
        ("duplicate search matches names and paths and combines with file types", {
            try await RecoveryChecks.fixture("duplicate-search-types") { f in
                let folder = f.home.appendingPathComponent("SearchSamples")
                let reports = try duplicateSamples(["Keep/Original.txt", "InboxFolder/报告.TXT", "Archive/REPORT.pdf", "Pictures/copy.PNG"],
                                                  bytes: Data("identical report sample".utf8), in: folder)
                let samples: [(DuplicateFileKind, String)] = [(.videos, "mp4"), (.audio, "mp3"), (.archives, "zip"), (.other, "unknowncachora")]
                for (index, sample) in samples.enumerated() {
                    _ = try duplicateSamples(["kind-\(index)-a.\(sample.1)", "kind-\(index)-b.\(sample.1)"],
                                             bytes: Data(repeating: UInt8(index + 70), count: 31 + index), in: folder)
                }
                let result = try await DuplicateFinder().scan(folder: folder)
                let group = try duplicateGroup(in: result, containing: reports[0])
                let chinese = DuplicateResultFilter(query: "  报告  ")
                try require(chinese.groups(from: result.groups).map(\.id) == [group.id], "Chinese filename search did not find the whole group")
                try require(chinese.matchingCopyURLs(in: result.groups, selection: DuplicateSelection()) == [reports[1]],
                            "Filename search selected a nonmatching copy")
                let path = DuplicateResultFilter(query: "inboxfolder")
                try require(path.matchingCopyURLs(in: result.groups, selection: DuplicateSelection()) == [reports[1]],
                            "Case-insensitive parent-path search failed")
                let upper = DuplicateResultFilter(query: "report.PDF")
                try require(upper.matchingCopyURLs(in: result.groups, selection: DuplicateSelection()) == [reports[2]],
                            "Case-insensitive filename search failed")
                let documents = DuplicateResultFilter(kind: .documents)
                try require(documents.matchingCopyURLs(in: [group], selection: DuplicateSelection()) == [reports[1], reports[2]],
                            "Document filtering included the image copy or omitted an uppercase extension")
                try require(DuplicateResultFilter(kind: .images).matchingCopyURLs(in: [group], selection: DuplicateSelection()) == [reports[3]],
                            "Image filtering did not operate per file")
                try require(DuplicateResultFilter(query: "报告", kind: .images).groups(from: result.groups).isEmpty,
                            "Search and file type were combined with OR instead of AND")
                try require(DuplicateResultFilter(query: " \n\t ").groups(from: result.groups).count == result.groups.count,
                            "Whitespace-only search hid results")
                try require(DuplicateResultFilter(query: "no-such-sample").groups(from: result.groups).isEmpty,
                            "An unmatched search returned a group")
                for (kind, suffix) in samples {
                    let found = DuplicateResultFilter(kind: kind).matchingCopyURLs(in: result.groups, selection: DuplicateSelection())
                    try require(found.count == 1 && found.allSatisfy { $0.pathExtension == suffix }, "File type \(kind) matched the wrong copies")
                }
                try require(try Data(contentsOf: reports[0]) == Data("identical report sample".utf8), "Search changed a file")
            }
        }),
        ("duplicate results sort by reclaimable size name and newest modification in both directions", {
            try await RecoveryChecks.fixture("duplicate-result-sort") { f in
                let folder = f.home.appendingPathComponent("SortSamples")
                let a = try duplicateSamples(["Alpha.txt", "Alpha-copy-1.txt", "Zeta-custom.txt"],
                                             bytes: Data(repeating: 65, count: 10), in: folder, modifiedBase: 1_600_000_100)
                let b = try duplicateSamples(["Beta.txt", "Beta-copy.txt"],
                                             bytes: Data(repeating: 66, count: 15), in: folder, modifiedBase: 1_600_000_300)
                let z = try duplicateSamples(["Zulu.txt", "Zulu-copy.txt"],
                                             bytes: Data(repeating: 90, count: 25), in: folder, modifiedBase: 1_600_000_200)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_400)],
                                                      ofItemAtPath: a[2].path)
                let result = try await DuplicateFinder().scan(folder: folder)
                let cases: [(DuplicateSortKey, [URL])] = [(.size, [b[0], a[0], z[0]]),
                                                         (.name, [a[0], b[0], z[0]]),
                                                         (.modified, [z[0], b[0], a[0]])]
                for (key, expected) in cases {
                    let ascending = DuplicateResultFilter(sortKey: key, ascending: true).groups(from: result.groups)
                    let descending = DuplicateResultFilter(sortKey: key, ascending: false).groups(from: result.groups)
                    try require(ascending.map(\.keeper.url) == expected, "Ascending \(key) order was incorrect")
                    try require(descending.map(\.keeper.url) == Array(expected.reversed()), "Descending \(key) order was incorrect")
                    try require(ascending.allSatisfy { $0.files.count >= 2 }, "Sorting removed a group member")
                }
                try require(DuplicateResultFilter().groups(from: result.groups).map(\.keeper.url) == [z[0], a[0], b[0]],
                            "Default sorting did not retain descending reclaimable size")
                let alpha = try duplicateGroup(in: result, containing: a[0])
                var selection = DuplicateSelection()
                guard let custom = alpha.files.first(where: { $0.url == a[2] }) else {
                    throw RecoveryChecks.Failure(description: "Custom sort keeper sample missing")
                }
                selection.keep(custom, in: alpha)
                for ascending in [true, false] {
                    let sorted = DuplicateResultFilter(sortKey: .name, ascending: ascending)
                        .groups(from: result.groups, selection: selection)
                    let expected = ascending ? [b[0], a[2], z[0]] : [z[0], a[2], b[0]]
                    try require(sorted.map { selection.keeper(in: $0).url } == expected,
                                "Name sorting did not follow the custom keeper shown on the group")
                }
            }
        }),
        ("filtered duplicate select all moves only matching extra copies and preserves every keeper", {
            try await RecoveryChecks.fixture("duplicate-filtered-move") { f in
                let home = XcodeBuildMCPDerivedDataSupport.canonicalHomeDirectory(f.home)
                let environment = CleanupEnvironment(home: home, recoveryRoot: f.vault, isFixture: true, blockedReason: nil)
                let folder = home.appendingPathComponent("FilterSamples")
                let bytes = Data("matching safe cleanup sample".utf8)
                let a = try duplicateSamples(["Keep/original.txt", "Hit/matching.txt", "Other/unmatched.txt"], bytes: bytes, in: folder)
                let b = try duplicateSamples(["Second/keep.txt", "Second/copy.txt"], bytes: Data("second group".utf8), in: folder)
                let finder = DuplicateFinder(trashHandler: try requireSampleTrash(environment))
                let result = try await finder.scan(folder: folder)
                let filter = DuplicateResultFilter(query: "/Hit/")
                let visible = filter.groups(from: result.groups)
                try require(visible.count == 1 && visible[0].contains(a[0]), "A keeper outside the search was hidden from the group")
                var selection = DuplicateSelection()
                selection.selectAll(in: result.groups)
                let matching = filter.matchingCopyURLs(in: result.groups, selection: selection)
                selection.selectAll(in: result.groups, matching: matching)
                try require(selection.urls == [a[1]], "Filtered select all retained a hidden selection")
                let review = selection.groupsForReview(in: result.groups)
                try require(review.count == 1 && review[0].keeper.url == a[0] && review[0].files.map(\.url) == [a[0], a[1]],
                            "Review omitted the keeper or included a nonmatching copy")
                let report = try await finder.moveToTrash(group: review[0], selectedIDs: selection.urls)
                try require(report.failures.isEmpty && report.trashedFiles.map(\.url) == [a[1]], "The move differed from filtered review")
                try require(try Data(contentsOf: a[0]) == bytes && Data(contentsOf: a[2]) == bytes, "The keeper or unmatched copy changed")
                try require(b.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "A hidden group was modified")
                let rescanned = try await finder.scan(folder: folder)
                try require(rescanned.groups.count == 2 && rescanned.duplicateFileCount == 4, "Rescan lost retained groups after the filtered move")
            }
        }),
        ("duplicate filter changes clear hidden selections and never select a custom keeper", {
            try await RecoveryChecks.fixture("duplicate-filter-keeper") { f in
                let folder = f.home.appendingPathComponent("KeeperSamples")
                let urls = try duplicateSamples(["original.txt", "chosen-copy.txt", "other-copy.txt"], bytes: Data("keeper sample".utf8), in: folder)
                let result = try await DuplicateFinder().scan(folder: folder)
                let group = try duplicateGroup(in: result, containing: urls[0])
                var selection = DuplicateSelection()
                selection.selectAll(in: result.groups)
                let keeperOnly = DuplicateResultFilter(query: "original.txt")
                try require(keeperOnly.groups(from: result.groups).count == 1, "A keeper-only match hid the result group")
                let keeperMatches = keeperOnly.matchingCopyURLs(in: result.groups, selection: selection)
                selection.retainSelection(in: result.groups, matching: keeperMatches)
                try require(selection.urls.isEmpty && keeperMatches.isEmpty, "Filtering to only the keeper left hidden copies selected")
                guard let custom = group.files.first(where: { $0.url == urls[1] }) else {
                    throw RecoveryChecks.Failure(description: "Custom keeper sample missing")
                }
                selection.keep(custom, in: group)
                let copyFilter = DuplicateResultFilter(query: "copy.txt")
                selection.selectAll(in: result.groups, matching: copyFilter.matchingCopyURLs(in: result.groups, selection: selection))
                try require(selection.urls == [urls[2]] && selection.groupsForReview(in: result.groups).first?.keeper.url == custom.url,
                            "Filtered selection ignored the custom keeper")
                selection.selectAll(in: result.groups, matching: [custom.url, f.outside])
                try require(selection.urls.isEmpty, "A direct matching set selected a protected or unrelated file")
                selection.selectAll(in: result.groups)
                selection.retainSelection(in: [], matching: Set(urls))
                try require(selection.urls.isEmpty, "Removing all visible groups retained stale selections")
            }
        }),
        ("duplicate ignored groups persist within their exact scan scope and can be restored", {
            try await RecoveryChecks.fixture("duplicate-ignore-persistence") { f in
                let folder = f.home.appendingPathComponent("IgnoredSamples")
                let urls = try duplicateSamples(["original.txt", "copy.txt"], bytes: Data("ignored sample".utf8), in: folder)
                let finder = DuplicateFinder()
                let result = try await finder.scan(folder: folder)
                let group = try duplicateGroup(in: result, containing: urls[0])
                let store = DuplicateIgnoreStore(fileURL: f.root.appendingPathComponent("settings/duplicate-ignores.json"))
                var rules = try store.load()
                try require(rules.rules.isEmpty, "A new fixture inherited real ignore rules")
                let rule = rules.ignore(group, in: folder)
                try require(rules.ignore(group, in: folder).id == rule.id && rules.rules.count == 1,
                            "Repeating ignore created duplicate records")
                try require(!rules.contains(group, in: folder.deletingLastPathComponent()),
                            "An ignore rule crossed into a wider scan scope")
                try store.save(rules)
                let restartedStore = DuplicateIgnoreStore(fileURL: f.root.appendingPathComponent("settings/duplicate-ignores.json"))
                var restarted = try restartedStore.load()
                let fresh = try await finder.scan(folder: folder)
                try require(restarted.rules.count == 1 && restarted.contains(fresh.groups[0], in: folder), "Ignore did not survive loading and rescanning")
                try require(restarted.reconcile(fresh) == 0, "Unchanged files invalidated their ignored group")
                let otherFolder = f.home.appendingPathComponent("OtherSamples")
                _ = try duplicateSamples(["original.txt", "copy.txt"], bytes: Data("ignored sample".utf8), in: otherFolder)
                let other = try await finder.scan(folder: otherFolder)
                try require(!restarted.contains(other.groups[0], in: otherFolder), "A digest-only rule hid unrelated copies in another folder")
                try require(restarted.reconcile(other) == 0 && restarted.rules.count == 1, "Scanning another folder erased an unrelated rule")
                restarted.remove(id: rule.id)
                try restartedStore.save(restarted)
                let restored = try restartedStore.load()
                try require(restored.rules.isEmpty && !restored.contains(group, in: folder), "Undo did not persist or the group stayed ignored")
                try require(try Data(contentsOf: urls[0]) == Data("ignored sample".utf8) && Data(contentsOf: urls[1]) == Data("ignored sample".utf8),
                            "Ignoring or undoing changed sample files")
            }
        }),
        ("duplicate ignore expires when membership path timestamp or physical identity changes", {
            try await RecoveryChecks.fixture("duplicate-ignore-membership") { f in
                for mutation in ["added", "removed", "renamed", "timestamp", "replaced"] {
                    let folder = f.home.appendingPathComponent(mutation)
                    let data = Data("three matching copies".utf8)
                    let urls = try duplicateSamples(["original.txt", "copy-a.txt", "copy-b.txt"], bytes: data, in: folder)
                    let finder = DuplicateFinder()
                    let first = try await finder.scan(folder: folder)
                    var rules = DuplicateIgnoreRules()
                    _ = rules.ignore(first.groups[0], in: folder)
                    switch mutation {
                    case "added": try data.write(to: folder.appendingPathComponent("new-copy.txt"))
                    case "removed": try FileManager.default.removeItem(at: urls[2])
                    case "renamed": try FileManager.default.moveItem(at: urls[2], to: folder.appendingPathComponent("renamed.txt"))
                    case "timestamp":
                        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: urls[2].path)
                    default:
                        let date = first.groups[0].files.first { $0.url == urls[2] }!.modifiedAt!
                        try data.write(to: urls[2], options: .atomic)
                        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: urls[2].path)
                    }
                    let fresh = try await finder.scan(folder: folder)
                    try require(fresh.groups.count == 1 && !rules.contains(fresh.groups[0], in: folder), "The \(mutation) group remained ignored")
                    try require(rules.reconcile(fresh) == 1 && rules.rules.isEmpty, "The \(mutation) rule was not removed after rescan")
                }
            }
        }),
        ("duplicate ignore detects same-size content changes even when timestamps are restored", {
            try await RecoveryChecks.fixture("duplicate-ignore-content") { f in
                let folder = f.home.appendingPathComponent("ContentSamples")
                let before = Data(repeating: 65, count: 64)
                let after = Data(repeating: 66, count: 64)
                let urls = try duplicateSamples(["original.txt", "copy-a.txt", "copy-b.txt"], bytes: before, in: folder)
                let finder = DuplicateFinder()
                let initial = try await finder.scan(folder: folder)
                var rules = DuplicateIgnoreRules()
                _ = rules.ignore(initial.groups[0], in: folder)
                for file in initial.groups[0].files {
                    try after.write(to: file.url)
                    try FileManager.default.setAttributes([.modificationDate: file.modifiedAt!], ofItemAtPath: file.url.path)
                }
                let changed = try await finder.scan(folder: folder)
                try require(changed.groups.count == 1 && changed.groups[0].digest != initial.groups[0].digest,
                            "The same-size content mutation was not rescanned")
                try require(!rules.contains(changed.groups[0], in: folder) && rules.reconcile(changed) == 1,
                            "An ignored signature used only size and timestamp")
                for file in initial.groups[0].files {
                    try before.write(to: file.url)
                    try FileManager.default.setAttributes([.modificationDate: file.modifiedAt!], ofItemAtPath: file.url.path)
                }
                let restored = try await finder.scan(folder: folder)
                try require(rules.rules.isEmpty && !rules.contains(restored.groups[0], in: folder), "An expired rule revived after restoring earlier contents")
                try require(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "Ignore validation removed sample files")
            }
        }),
        ("duplicate ignore expires when one copy changes or all duplicates disappear", {
            try await RecoveryChecks.fixture("duplicate-ignore-disappear") { f in
                let folder = f.home.appendingPathComponent("PartialSamples")
                let urls = try duplicateSamples(["original.txt", "copy-a.txt", "copy-b.txt"], bytes: Data("old identical copies".utf8), in: folder)
                let finder = DuplicateFinder()
                let initial = try await finder.scan(folder: folder)
                var rules = DuplicateIgnoreRules()
                _ = rules.ignore(initial.groups[0], in: folder)
                try Data("a changed copy".utf8).write(to: urls[2])
                let changed = try await finder.scan(folder: folder)
                try require(changed.groups.count == 1 && changed.groups[0].files.count == 2
                            && !rules.contains(changed.groups[0], in: folder), "The unchanged subset inherited an obsolete whole-group ignore")
                try require(rules.reconcile(changed) == 1, "The changed member did not invalidate its prior rule")
                _ = rules.ignore(changed.groups[0], in: folder)
                try Data("another unique copy".utf8).write(to: urls[1])
                let empty = try await finder.scan(folder: folder)
                try require(empty.groups.isEmpty && rules.reconcile(empty) == 1 && rules.rules.isEmpty,
                            "A group without duplicates retained a stale ignore record")
            }
        }),
        ("duplicate ignore storage rejects corruption and symbolic links without changing targets", {
            try await RecoveryChecks.fixture("duplicate-ignore-corrupt") { f in
                let location = f.root.appendingPathComponent("ignore-rules.json")
                let store = DuplicateIgnoreStore(fileURL: location)
                let corrupt = Data("not valid JSON".utf8)
                try corrupt.write(to: location)
                try await RecoveryChecks.expectFailure { _ = try store.load() }
                try await RecoveryChecks.expectFailure { try store.save(DuplicateIgnoreRules()) }
                try require(try Data(contentsOf: location) == corrupt, "Reading corrupt rules overwrote the file")
                let unknownSchema = Data("{\"version\":999,\"value\":{\"rules\":[]}}".utf8)
                try unknownSchema.write(to: location)
                try await RecoveryChecks.expectFailure { _ = try store.load() }
                try await RecoveryChecks.expectFailure { try store.save(DuplicateIgnoreRules()) }
                try require(try Data(contentsOf: location) == unknownSchema, "Reading an unsupported schema overwrote the file")
                try FileManager.default.removeItem(at: location)
                try FileManager.default.createSymbolicLink(at: location, withDestinationURL: f.outside)
                try await RecoveryChecks.expectFailure { _ = try store.load() }
                try await RecoveryChecks.expectFailure { try store.save(DuplicateIgnoreRules()) }
                try require(try Data(contentsOf: f.outside) == f.preserved, "Ignore storage followed a symbolic link and changed its target")
            }
        }),
        ("duplicate review rechecks a custom keeper and reports partial moves", {
            try await RecoveryChecks.fixture("fixture-duplicate-partial") { f in
                let home = XcodeBuildMCPDerivedDataSupport.canonicalHomeDirectory(f.home)
                let environment = CleanupEnvironment(home: home, recoveryRoot: f.vault, isFixture: true, blockedReason: nil)
                let folder = home.appendingPathComponent("Duplicates")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let urls = ["01.txt", "02.txt", "03.txt"].map { folder.appendingPathComponent($0) }
                let data = Data("same contents".utf8)
                let changed = Data("contents after review".utf8)
                for url in urls { try data.write(to: url) }
                let keep = urls[2]
                let trash = try requireSampleTrash(environment)
                let finder = DuplicateFinder(trashHandler: { url in
                    try trash(url)
                    try changed.write(to: keep, options: .atomic)
                })
                func reviewGroup() async throws -> DuplicateGroup {
                    let result = try await finder.scan(folder: folder)
                    guard let group = result.groups.first, let file = group.files.first(where: { $0.url == keep }) else {
                        throw RecoveryChecks.Failure(description: "Sample group is missing")
                    }
                    var selection = DuplicateSelection()
                    selection.keep(file, in: group)
                    selection.selectAll(in: result.groups)
                    guard let review = selection.groupsForReview(in: result.groups).first else {
                        throw RecoveryChecks.Failure(description: "Review group is missing")
                    }
                    return review
                }
                let stale = try await reviewGroup()
                try changed.write(to: keep, options: .atomic)
                do {
                    _ = try await finder.moveToTrash(group: stale, selectedIDs: Set(urls.dropLast()))
                    throw RecoveryChecks.Failure(description: "A changed custom keeper passed review")
                } catch DuplicateFinderError.keeperChanged(let path) {
                    try require(path == keep.path, "The error named a different keeper")
                }
                try require(urls.dropLast().allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                            "Files moved despite the stale keeper")
                try data.write(to: keep, options: .atomic)
                let fresh = try await reviewGroup()
                let report = try await finder.moveToTrash(group: fresh, selectedIDs: Set(urls.dropLast()))
                try require(report.trashedFiles.count == 1 && report.failures.contains(where: { $0.url == keep }),
                            "The partial result lost the successful move or the keeper failure")
                let remaining = try urls.dropLast().filter { FileManager.default.fileExists(atPath: $0.path) }
                    .map { try Data(contentsOf: $0) }
                try require(remaining == [data] && Data(contentsOf: keep) == changed,
                            "A second file moved after the keeper changed")
            }
        }),
        ("photo review refuses a whole group and changed files", {
            try await RecoveryChecks.fixture("fixture-photo-selection") { f in
                let home = XcodeBuildMCPDerivedDataSupport.canonicalHomeDirectory(f.home)
                let fixture = CleanupEnvironment(home: home, recoveryRoot: f.vault, isFixture: true, blockedReason: nil)
                let photos = home.appendingPathComponent("Pictures")
                try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
                guard let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGPwj88HAAIeAR7lPwwAAAAAAElFTkSuQmCC") else {
                    throw RecoveryChecks.Failure(description: "Invalid embedded test image")
                }
                let originals = ["01-photo.png", "02-photo.png", "03-photo.png"].map { photos.appendingPathComponent($0) }
                for url in originals { try png.write(to: url) }
                let finder = SimilarPhotoFinder(trashHandler: try requireSampleTrash(fixture))
                let result = try await finder.scan(folder: photos)
                try require(result.groups.count == 1 && result.matchedPhotoCount == 3, "Test images did not group")
                try await RecoveryChecks.expectFailure {
                    _ = try await finder.moveToTrash(from: result, selected: Set(originals))
                }
                try Data("REPLACED AFTER SCAN".utf8).write(to: originals[1], options: .atomic)
                let refused = try await finder.moveToTrash(from: result, selected: [originals[1]])
                try require(refused.moved.isEmpty && refused.errors.count == 1, "Changed photo moved")
                let moved = try await finder.moveToTrash(from: result, selected: [originals[2]])
                try require(moved.moved == [originals[2]] && moved.errors.isEmpty, "Unchanged selected photo did not move")
                try require(try Data(contentsOf: originals[0]) == png, "Retained photo changed")
                try require(try Data(contentsOf: originals[1]) == Data("REPLACED AFTER SCAN".utf8), "Replacement changed")
            }
        }),
        ("photo progress is batched when decoding fails", {
            try await RecoveryChecks.fixture("fixture-photo-progress") { f in
                let home = XcodeBuildMCPDerivedDataSupport.canonicalHomeDirectory(f.home)
                let folder = home.appendingPathComponent("Pictures", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for index in 1...32 {
                    let file = folder.appendingPathComponent("invalid-\(index).png")
                    try Data("invalid image".utf8).write(to: file)
                }
                let updates = PhotoAnalysisUpdates()
                let result = try await SimilarPhotoFinder().scan(folder: folder) { progress in
                    if progress.phase == .analyzing { await updates.record(progress) }
                }
                let analyzing = await updates.progress
                try require(result.photosAnalyzed == 0 && result.skippedItems == 32 && result.groups.isEmpty,
                            "Undecodable photos changed scan totals")
                let expectedFiles = [1, 10, 20, 30, 32].map { "invalid-\($0).png" }
                try require(analyzing.compactMap { $0.currentURL?.lastPathComponent } == expectedFiles,
                            "Progress did not update on the first, every tenth, and final candidate")
            }
        }),
        ("leftover scan excludes generic cache names and installed apps", {
            try await RecoveryChecks.fixture("fixture-orphan-scope") { f in
                _ = try f.file("Generic Cache")
                _ = try f.file("org.cachora.active")
                _ = try f.file("org.cachora.retired")
                let home = XcodeBuildMCPDerivedDataSupport.canonicalHomeDirectory(f.home)
                let appInfo = home.appendingPathComponent("Applications/Active.app/Contents/Info.plist")
                try FileManager.default.createDirectory(at: appInfo.deletingLastPathComponent(), withIntermediateDirectories: true)
                let plist = try PropertyListSerialization.data(
                    fromPropertyList: ["CFBundleIdentifier": "org.cachora.active", "CFBundleName": "Active", "CFBundlePackageType": "APPL"],
                    format: .xml, options: 0)
                try plist.write(to: appInfo)
                let fixture = CleanupEnvironment(home: home, recoveryRoot: f.vault, isFixture: true, blockedReason: nil)
                let state = AppState(performStartupTasks: false, cleanupEnvironment: fixture)
                state.loadInstalledApps()
                for _ in 0..<500 where state.isLoadingApps { try await Task.sleep(nanoseconds: 10_000_000) }
                try require(state.installedApps.map(\.bundleIdentifier) == ["org.cachora.active"], "Installed sample app was not recognized")
                state.findOrphans()
                for _ in 0..<500 where state.isSearchingOrphans { try await Task.sleep(nanoseconds: 10_000_000) }
                try require(state.orphanedFiles.map(\.lastPathComponent) == ["org.cachora.retired"],
                            "The scan labeled a generic cache or a known app as a leftover")
            }
        }),
        ("Apple storage and backup tools accept system aliases but reject a linked sample path", {
            let root = URL(fileURLWithPath: "/private/tmp/cachora-apple-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                let f = RecoveryChecks.Fixture(root: root)
                try FileManager.default.createDirectory(at: f.outside.deletingLastPathComponent(), withIntermediateDirectories: true)
                try f.preserved.write(to: f.outside)
                let home = URL(fileURLWithPath: "/tmp/\(root.lastPathComponent)/home", isDirectory: true)
                try require(home.path.hasPrefix("/tmp/"), "Temporary alias was not exercised")
                let fixture = CleanupEnvironment(home: home, recoveryRoot: f.vault, isFixture: true, blockedReason: nil)
                let backupRoot = home.appendingPathComponent("Library/Application Support/MobileSync/Backup")
                let sample = backupRoot.appendingPathComponent("0000000000000000000000000000000000000001")
                try FileManager.default.createDirectory(at: sample, withIntermediateDirectories: true)
                let marker = Data("TEST DEVICE BACKUP".utf8)
                for name in ["Info.plist", "Manifest.plist", "Manifest.db"] { try marker.write(to: sample.appendingPathComponent(name)) }
                let status = try PropertyListSerialization.data(fromPropertyList: ["SnapshotState": "finished"],
                                                                format: .xml, options: 0)
                try status.write(to: sample.appendingPathComponent("Status.plist"))
                let service = DeviceBackupService(homeDirectory: home, trashHandler: try requireSampleTrash(fixture))
                let measured = try await AppleStorageService.scan(locations: [.init(kind: .deviceBackups, url: backupRoot)])
                try require(measured.first?.status == .complete && (measured.first?.allocatedBytes ?? 0) > 0,
                            "A valid sample backup was not measured")
                let result = try await service.scan()
                try require(result.backups.count == 1 && result.issues.isEmpty, "A finished sample backup was not listed")
                let move = try await service.trash(result.backups)
                try require(move.removedPaths == [sample.path] && move.errors.isEmpty, "The reviewed backup was not retained in sample Trash")
                let link = backupRoot.appendingPathComponent("linked")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.outside.deletingLastPathComponent())
                let linked = try await AppleStorageService.scan(locations: [.init(kind: .deviceBackups, url: link)])
                try require(linked.first?.status == .unavailable, "A user-created link was followed")
                try require(try Data(contentsOf: f.outside) == f.preserved, "External sentinel changed")
            }
        }),
        ("fixture scan, review and recovery agree on the macOS temporary path", {
            let parent = URL(fileURLWithPath: "/private/tmp/cachora-alias-\(UUID().uuidString)")
            let root = parent.appendingPathComponent("workspace")
            let cache = root.appendingPathComponent("home/Library/Caches")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: parent) }
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let sample = cache.appendingPathComponent("sample.bin")
            let data = Data(repeating: 42, count: 4096)
            try data.write(to: sample)
            try JSONSerialization.data(withJSONObject: ["purpose": "PureMac disposable recovery tests", "root": root.path])
                .write(to: root.appendingPathComponent(".puremac-fixture.json"))
            let linkedParent = parent.appendingPathComponent("linked-parent")
            try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: parent)
            try require((try? CleanupEnvironment.checkedFixture(root: root, below: linkedParent)) == nil,
                        "Fixture accepted a user-created directory alias")
            let environment = try CleanupEnvironment.checkedFixture(root: root, below: parent)
            let state = AppState(performStartupTasks: false, cleanupEnvironment: environment)
            state.startSmartScan()
            for _ in 0..<500 where state.scanState.isActive { try await Task.sleep(nanoseconds: 10_000_000) }
            guard let item = state.categoryResults[.userCache]?.items.first else {
                throw RecoveryChecks.Failure(description: "Temporary fixture cache was not scanned")
            }
            try require(RecoveryPathPolicy.accepts(item, home: environment.home), "Review rejected the temporary path spelling")
            state.cleanAll(itemIDs: [item.id])
            for _ in 0..<500 where state.scanState.isActive { try await Task.sleep(nanoseconds: 10_000_000) }
            guard let record = state.recoveryCenter.entries.first else {
                throw RecoveryChecks.Failure(description: "Temporary fixture recovery record is missing")
            }
            await state.recoveryCenter.restore(record.id)
            try require(try Data(contentsOf: sample) == data, "Temporary fixture content changed during recovery")
        }),
        ("full workspace reviews and restores a selected old test document", {
            try await RecoveryChecks.fixture("full-workspace-scan") { f in
                let sample = f.home.appendingPathComponent("Downloads/old-sample.bin")
                let marker = Data("DISPOSABLE-OLD-FILE".utf8)
                let size: UInt64 = 12 * 1024 * 1024
                try FileManager.default.createDirectory(at: sample.deletingLastPathComponent(), withIntermediateDirectories: true)
                try marker.write(to: sample)
                let writer = try FileHandle(forWritingTo: sample)
                try writer.truncate(atOffset: size)
                try writer.close()
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 978307200)],
                                                      ofItemAtPath: sample.path)

                let environment = CleanupEnvironment(home: f.home, recoveryRoot: f.vault, isFixture: false, blockedReason: nil)
                let state = AppState(performStartupTasks: false, cleanupEnvironment: environment)
                state.scanSingleCategory(.largeFiles)
                for _ in 0..<500 where state.scanState.isActive { try await Task.sleep(nanoseconds: 10_000_000) }
                guard let item = state.categoryResults[.largeFiles]?.items.first(where: { $0.path == sample.path }) else {
                    throw RecoveryChecks.Failure(description: "Full workspace failed to scan a non-cache category")
                }
                try require(!state.isItemSelected(item), "Document was automatically selected")
                state.cleanCategory(.largeFiles, itemIDs: [item.id])
                try require(FileManager.default.fileExists(atPath: sample.path), "Unselected document was moved")
                state.toggleItem(item)
                state.cleanCategory(.largeFiles, itemIDs: [item.id])
                for _ in 0..<500 where state.scanState.isActive { try await Task.sleep(nanoseconds: 10_000_000) }
                try require(state.lastRecoveryMovedCount == 1 && state.totalFreedSpace == 0, "Document did not move to Recovery")
                guard let record = state.recoveryCenter.entries.first else {
                    throw RecoveryChecks.Failure(description: "Document recovery record is missing")
                }
                await state.recoveryCenter.restore(record.id)
                let reader = try FileHandle(forReadingFrom: sample)
                defer { try? reader.close() }
                try require(try reader.read(upToCount: marker.count) == marker, "Restored document content changed")
                try require(try reader.seekToEnd() == size, "Restored document length changed")
            }
        }),
        ("Finder uninstall keeps the selected app and never moves its containing directory", {
            try await RecoveryChecks.fixture("uninstall-containing-directory") { f in
                let home = f.home.standardizedFileURL
                let parent = home.appendingPathComponent("Applications/Uninstall Sample")
                let app = parent.appendingPathComponent("Nested/Uninstall Sample.app")
                let info = app.appendingPathComponent("Contents/Info.plist")
                let related = home.appendingPathComponent("Library/Caches/org.cachora.uninstall.sample")
                let neighbor = parent.appendingPathComponent("keep.txt")
                let data = Data("UNRELATED SAMPLE".utf8)
                for directory in [info.deletingLastPathComponent(), related] {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                }
                let plist = try PropertyListSerialization.data(
                    fromPropertyList: ["CFBundleIdentifier": "org.cachora.uninstall.sample",
                                       "CFBundleName": "Uninstall Sample", "CFBundlePackageType": "APPL"],
                    format: .xml, options: 0)
                try plist.write(to: info)
                try data.write(to: neighbor)
                try data.write(to: related.appendingPathComponent("cache"))
                let fixture = CleanupEnvironment(home: home, recoveryRoot: f.vault, isFixture: true, blockedReason: nil)
                let trash = try requireSampleTrash(fixture)
                let normal = CleanupEnvironment(home: home, recoveryRoot: f.vault, isFixture: false, blockedReason: nil)
                var moved: [URL] = []
                let state = AppState(performStartupTasks: false,
                    locationsProvider: { Locations(sampleHome: home) },
                    appFileTrasher: { urls, completion in
                        var failed: [URL] = []
                        for url in urls {
                            do { try trash(url); moved.append(url) }
                            catch { failed.append(url) }
                        }
                        completion(moved, false, [], failed)
                    }, cleanupEnvironment: normal, scheduler: SchedulerService(defaults: nil))
                state.presentExternalUninstall(appPath: app.path)
                for _ in 0..<500 where state.selectedApp == nil {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                try require(state.discoveredFiles.map(\.path) == [app.path] && !state.isScanningAppFiles,
                            "Finder did not immediately offer just the selected bundle")
                guard let selected = state.selectedApp else {
                    throw RecoveryChecks.Failure(description: "Finder did not select the app")
                }
                state.scanForAppFiles(selected)
                for _ in 0..<500 where state.isScanningAppFiles { try await Task.sleep(nanoseconds: 10_000_000) }
                try require(state.discoveredFiles.contains(where: { $0.path == app.path }), "The bundle was removed from review")
                try require(state.discoveredFiles.contains(where: { $0.path == related.path }), "The related candidate was lost")
                try require(!state.discoveredFiles.contains(where: { $0.path == parent.path }), "Containing directory appeared")
                try require(state.selectedFiles.map(\.path) == [app.path], "Only the bundle should be preselected")

                state.removeSelectedFiles(confirmedURLs: [parent])
                try require(moved.isEmpty && state.removalError != nil, "Confirmation accepted the containing directory")
                state.removeSelectedFiles(confirmedURLs: state.selectedFiles)
                for _ in 0..<500 where state.isRemovingAppFiles { try await Task.sleep(nanoseconds: 10_000_000) }
                try require(moved.map(\.path) == [app.path] && !FileManager.default.fileExists(atPath: app.path),
                            "The selected bundle was not moved on its own")
                try require(try Data(contentsOf: neighbor) == data, "A sibling file changed")
                try require(try Data(contentsOf: related.appendingPathComponent("cache")) == data, "An unselected cache changed")
            }
        }),
        ("a stalled large-file read returns partial results and cannot pile up workers", {
            try await RecoveryChecks.fixture("large-file-stall") { f in
                let sample = try f.file("retained-sample.bin")
                let item = CleanableItem(name: sample.lastPathComponent, path: sample.path, size: 4096,
                                         category: .largeFiles, isSelected: false, lastModified: nil)
                let unblock = DispatchSemaphore(value: 0)
                let finished = DispatchSemaphore(value: 0)
                defer {
                    unblock.signal()
                    _ = finished.wait(timeout: .now() + 1)
                }
                let started = ProcessInfo.processInfo.systemUptime
                let partial = await LargeFileScan.run(at: f.home.path, inactivityTimeout: 0.35) { scan in
                    _ = scan.visit(sample.path)
                    scan.add(item)
                    _ = unblock.wait(timeout: .now() + 5)
                    finished.signal()
                }
                try require(ProcessInfo.processInfo.systemUptime - started < 3, "The caller waited for blocked I/O")
                try require(partial.items == [item] && partial.totalSize == item.size, "Partial findings were lost")
                try require(partial.issues.map(\.path) == [sample.path], "The stalled location was not reported")
                let retry = await LargeFileScan.run(at: f.home.path) { $0.add(item) }
                try require(retry.items.isEmpty && retry.issues.count == 1, "Another worker started during the stalled read")
                unblock.signal()
                var resumed = false
                for _ in 0..<100 where !resumed {
                    let next = await LargeFileScan.run(at: f.home.path) { $0.add(item) }
                    resumed = next.items == [item] && next.issues.isEmpty
                    if !resumed { try await Task.sleep(nanoseconds: 10_000_000) }
                }
                try require(resumed, "The scanner did not resume after the blocked read returned")
            }
        }),
        ("temporary directory aliases allow system junk and old sample files to round trip", {
            let root = URL(fileURLWithPath: "/private/tmp/cachora-cleanup-alias-\(UUID().uuidString)", isDirectory: true)
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: root) }
            let physicalHome = root.appendingPathComponent("home", isDirectory: true)
            let physicalOld = physicalHome.appendingPathComponent("Downloads/old-sample.bin")
            let physicalSystem = root.appendingPathComponent("system-sample.log")
            let data = Data(repeating: 55, count: 4096)
            try fm.createDirectory(at: physicalOld.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: physicalOld)
            try data.write(to: physicalSystem)
            let home = physicalHome.standardizedFileURL
            let oldFile = physicalOld.standardizedFileURL
            let systemFile = physicalSystem.standardizedFileURL
            let size: UInt64 = 12 * 1024 * 1024
            let handle = try FileHandle(forWritingTo: oldFile)
            try handle.truncate(atOffset: size)
            try handle.close()
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 978307200)], ofItemAtPath: oldFile.path)
            let store = RecoveryStore(root: root.appendingPathComponent("recovery"), allowedRoots: [root],
                pathValidator: { RecoveryPathPolicy.accepts(path: $0, category: $1, snapshot: $2, home: home) })
            let cleaner = CleaningEngine(homeDirectory: home, recoveryStore: store,
                                         fixtureBoundary: root.standardizedFileURL)
            let system = CleanableItem(name: systemFile.lastPathComponent, path: systemFile.path, size: Int64(data.count),
                                       category: .systemJunk, isSelected: false, lastModified: nil)
            try require(RecoveryPathPolicy.systemJunkRoots(home: home.path).contains("/tmp"), "The scan uses a different temporary root")
            let result = await ScanEngine(homeDirectory: home, samplesOnly: true).scanCategory(.largeFiles)
            guard let old = result.items.first(where: { $0.path == oldFile.path }) else {
                throw RecoveryChecks.Failure(description: "Temporary old file missing: \(result.items.map(\.path)); \(result.issues)")
            }
            let state = AppState(performStartupTasks: false,
                cleanupEnvironment: CleanupEnvironment(home: home, recoveryRoot: root.appendingPathComponent("recovery"),
                                                       isFixture: true, blockedReason: nil),
                scheduler: SchedulerService(defaults: nil))
            for item in [system, old] {
                try require(!item.isSelected && state.canRecover(item), "The temporary sample cannot be selected")
                let moved = await cleaner.cleanItems([item], progressHandler: { _ in })
                guard let entry = moved.recoveryEntries.first else {
                    throw RecoveryChecks.Failure(description: "Temporary sample did not move: \(moved.errors)")
                }
                try require(!fm.fileExists(atPath: item.path), "The sample still exists at its original location")
                _ = try await store.restore(entry.id)
                try require(fm.fileExists(atPath: item.path), "The original location was not restored")
            }
            try require(try Data(contentsOf: systemFile) == data, "The system sample changed")
            let vaultFile = root.appendingPathComponent("recovery/keep-in-vault.bin")
            try data.write(to: vaultFile)
            let vaultAlias = vaultFile.standardizedFileURL.path
            guard let vaultSnapshot = RecoverySnapshot.capture(vaultAlias) else {
                throw RecoveryChecks.Failure(description: "Vault sentinel missing")
            }
            try await RecoveryChecks.expectFailure {
                _ = try await store.stage(path: vaultAlias, name: vaultFile.lastPathComponent, category: "System Junk",
                                          bytes: Int64(data.count), expected: vaultSnapshot)
            }
            try require(try Data(contentsOf: vaultFile) == data, "Alias bypassed the vault exclusion")
            let reader = try FileHandle(forReadingFrom: oldFile)
            defer { try? reader.close() }
            try require(try reader.read(upToCount: data.count) == data && reader.seekToEnd() == size,
                        "The old sample changed")
        }),
    ] }

    private static func duplicateSamples(_ names: [String], bytes: Data, in folder: URL,
                                         modifiedBase: TimeInterval = 1_600_000_000) throws -> [URL] {
        let urls = names.map { folder.appendingPathComponent($0) }
        for (index, url) in urls.enumerated() {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modifiedBase + Double(index))],
                                                  ofItemAtPath: url.path)
        }
        return urls
    }

    private static func duplicateGroup(in result: DuplicateScanResult, containing url: URL) throws -> DuplicateGroup {
        guard let group = result.groups.first(where: { $0.contains(url) }) else {
            throw RecoveryChecks.Failure(description: "Expected sample duplicate group was missing")
        }
        return group
    }

    private static func requireSampleTrash(_ fixture: CleanupEnvironment) throws -> @Sendable (URL) throws -> Void {
        guard let trash = fixture.sampleTrash else {
            throw RecoveryChecks.Failure(description: "Sample Trash was unavailable")
        }
        return trash
    }
}

private actor SampleBrew {
    enum Cask: String {
        case first = #"{"name":"sample-a","installed_versions":["1.0"],"current_version":"2.0","pinned":false}"#
        case changedFirst = #"{"name":"sample-a","installed_versions":["1.0"],"current_version":"3.0","pinned":false}"#
        case second = #"{"name":"sample-b","installed_versions":["1.0"],"current_version":"2.0","pinned":false}"#
    }

    struct Reply {
        let arguments: [String]
        var json = ""
        var error = ""

        static func check(_ casks: [Cask]) -> Self {
            Self(arguments: ["outdated", "--cask", "--json=v2"],
                 json: "{\"casks\":[\(casks.map(\.rawValue).joined(separator: ","))]}")
        }

        static let failedCheck = Self(arguments: ["outdated", "--cask", "--json=v2"], error: "Sample check failed")

        static func info(_ tokens: [String]) -> Self {
            Self(arguments: ["info", "--json=v2", "--cask", "--"] + tokens, json: #"{"casks":[]}"#)
        }

        static func upgrade(_ tokens: [String], failed: Bool = false) -> Self {
            Self(arguments: ["upgrade", "--cask", "--"] + tokens, error: failed ? "Sample upgrade failed" : "")
        }
    }

    static let executable = URL(fileURLWithPath: "/cachora-test-bin/brew")
    private var replies: [Reply]
    private var unexpected: [[String]] = []

    init(_ replies: [Reply]) { self.replies = replies }

    @MainActor func updater(locateBrew: @escaping () -> URL? = { SampleBrew.executable }) -> ApplicationUpdater {
        ApplicationUpdater(locateBrew: locateBrew, runBrew: { url, arguments, _ in
            try await self.run(url, arguments: arguments)
        })
    }

    private func run(_ url: URL, arguments: [String]) throws -> BrewProcessOutput {
        guard url == Self.executable, let reply = replies.first, arguments == reply.arguments else {
            unexpected.append(arguments)
            throw RecoveryChecks.Failure(description: "Unexpected Homebrew command: \(arguments)")
        }
        replies.removeFirst()
        return BrewProcessOutput(stdout: Data(reply.json.utf8), stderr: Data(reply.error.utf8), status: reply.error.isEmpty ? 0 : 1)
    }

    func requireComplete() throws {
        guard replies.isEmpty && unexpected.isEmpty else {
            throw RecoveryChecks.Failure(description: "Pending Homebrew commands: \(replies.map(\.arguments)); unexpected: \(unexpected)")
        }
    }
}
