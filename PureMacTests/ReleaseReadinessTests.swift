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
            for name in ["PureMac-0.2.0.zip", "CleanerBeta-cli.zip", "CleanerBeta-fixture.zip", "CleanerBeta-0.2.0-source.zip", "CleanerBeta-0.2.0.txt", "../CleanerBeta-0.2.0.zip"] {
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
        ("public beta exposes cache categories only", {
            for category in CleaningCategory.allCases {
                try require(BetaCapabilities.permits(category, enabled: true) == [.userCache, .nodeCache, .brewCache].contains(category), "Beta scope expanded")
            }
        }),
        ("beta engine keeps unsupported test documents and AI history", {
            try await RecoveryChecks.fixture("beta-boundary") { f in
                let source = try f.file()
                let history = f.home.appendingPathComponent(".ollama/history")
                try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("TEST-HISTORY-KEEP".utf8).write(to: history)
                let engine = CleaningEngine(homeDirectory: f.home, recoveryStore: f.store(), fixtureBoundary: f.home, publicBeta: true)
                let rows = [CleanableItem(name: "history", path: history.path, size: 17, category: .aiApps, isSelected: true, lastModified: nil),
                            CleanableItem(name: "cache", path: source.path, size: 4096, category: .userCache, isSelected: true, lastModified: nil)]
                let result = await engine.cleanItems(rows) { _ in }
                try require(result.itemsCleaned == 1 && result.errors.count == 1, "Beta cleaned an unsupported category")
                try require(try Data(contentsOf: history) == Data("TEST-HISTORY-KEEP".utf8), "Test history changed")
                _ = try await f.store().restore(result.recoveryEntries[0].id)
                try require(FileManager.default.fileExists(atPath: source.path), "Beta cache failed to restore")
            }
        }),
    ] }
}
