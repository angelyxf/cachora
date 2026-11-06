import Foundation
import Darwin

#if canImport(XCTest)
import XCTest
@testable import PureMac

final class DirectoryMeasurementTests: XCTestCase {
    func testHiddenFilesAndDirectoriesAreIncluded() throws { try MeasurementChecks.hiddenFiles() }
    func testUnreadableRootHasUnknownSize() throws { try MeasurementChecks.unreadableRoot() }
    func testUnreadableChildPreservesReadableBytesAndIssue() throws { try MeasurementChecks.unreadableChild() }
    func testSymbolicLinksAreNotFollowed() throws { try MeasurementChecks.symbolicLinks() }
    func testMissingOptionalDirectoryIsNotAnError() throws { try MeasurementChecks.missingDirectory() }
    func testCancellationStopsEnumeration() throws { try MeasurementChecks.cancellation() }
    func testUnderlyingPermissionErrorIsRecognized() throws { try MeasurementChecks.underlyingPermission() }
}
#else
/// The same regression cases can run with Command Line Tools, without XCTest.
@main
enum MeasurementTestRunner {
    static func main() {
        let cases: [(String, () throws -> Void)] = [
            ("hidden files and directories", MeasurementChecks.hiddenFiles),
            ("unreadable root", MeasurementChecks.unreadableRoot),
            ("partial directory", MeasurementChecks.unreadableChild),
            ("symbolic links", MeasurementChecks.symbolicLinks),
            ("optional missing directory", MeasurementChecks.missingDirectory),
            ("cancellation", MeasurementChecks.cancellation),
            ("underlying permission error", MeasurementChecks.underlyingPermission),
        ]
        for (name, test) in cases {
            do {
                try test()
            } catch {
                print("FAIL: \(name): \(error)")
                exit(1)
            }
            print("PASS: \(name)")
        }
        print("Passed \(cases.count) scan regression cases. No user data was changed.")
    }
}
#endif

private enum MeasurementChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-Measurement-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.resolvingSymlinksInPath())
    }

    private static func write(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 32_768).write(to: url)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func hiddenFiles() throws {
        try fixture { root in
            let hidden = root.appendingPathComponent(".cache-entry")
            let nested = root.appendingPathComponent(".hidden/nested")
            try write(hidden)
            try write(nested)
            var visited: Set<String> = []
            let result = DirectoryMeasurement.measure(path: root.path, onPath: { visited.insert(canonical($0)) })
            try require(result.bytes >= 65_536, "Hidden data was omitted from the size")
            try require(visited.contains(canonical(hidden.path)) && visited.contains(canonical(nested.path)), "Hidden subtree was not visited")
            try require(result.issues.isEmpty, "Readable hidden files produced an error")
        }
    }

    static func unreadableRoot() throws {
        try fixture { root in
            try write(root.appendingPathComponent("keep"))
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
            let result = DirectoryMeasurement.measure(path: root.path)
            try require(result.bytes == 0, "Unreadable root unexpectedly measured")
            try require(result.issues.contains { $0.path == root.path && $0.kind == .permissionDenied }, "Unreadable root was presented as empty")
        }
    }

    static func unreadableChild() throws {
        try fixture { root in
            let denied = root.appendingPathComponent("denied")
            try write(root.appendingPathComponent("visible"))
            try write(denied.appendingPathComponent("keep"))
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
            let result = DirectoryMeasurement.measure(path: root.path)
            try require(result.bytes >= 32_768, "Readable data was lost when another subtree failed")
            try require(result.issues.contains { canonical($0.path) == canonical(denied.path) && $0.kind == .permissionDenied }, "Skipped subtree was not reported")
        }
    }

    static func symbolicLinks() throws {
        try fixture { root in
            let cache = root.appendingPathComponent("cache")
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try write(outside.appendingPathComponent("preserve"))
            let link = cache.appendingPathComponent("redirect")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            var visited: [String] = []
            let result = DirectoryMeasurement.measure(path: cache.path, onPath: { visited.append($0) })
            try require(result.bytes == 0 && result.issues.isEmpty, "Symbolic link target was counted")
            try require(!visited.contains { $0.hasSuffix("preserve") }, "Symbolic link was traversed")
            let linkedRoot = DirectoryMeasurement.measure(path: link.path)
            try require(linkedRoot.bytes == 0 && !linkedRoot.issues.isEmpty, "A linked scan root was followed")
        }
    }

    static func missingDirectory() throws {
        try fixture { root in
            let result = DirectoryMeasurement.measure(path: root.appendingPathComponent("not-installed").path)
            try require(result.bytes == 0 && result.issues.isEmpty, "Missing optional application was reported as a failure")
        }
    }

    static func cancellation() throws {
        try fixture { root in
            for index in 0..<12 { try write(root.appendingPathComponent("entry-\(index)")) }
            var visited = 0
            let result = DirectoryMeasurement.measure(
                path: root.path, isCancelled: { visited > 0 }, onPath: { _ in visited += 1 }
            )
            try require(result.wasCancelled && visited == 1, "Cancellation did not stop enumeration promptly")
        }
    }

    static func underlyingPermission() throws {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        try require(ScanIssue(path: "/fixture", error: error).kind == .permissionDenied,
                    "Underlying permission error was misclassified")
    }
}
