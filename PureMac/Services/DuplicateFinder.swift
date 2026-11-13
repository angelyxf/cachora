import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

struct DuplicateFileIdentity: Codable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let flags: UInt32

    var physicalID: DuplicatePhysicalFileID {
        DuplicatePhysicalFileID(device: device, inode: inode)
    }
}

struct DuplicatePhysicalFileID: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct DuplicateFile: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    let modifiedAt: Date?
    let digest: String
    let identity: DuplicateFileIdentity

    var id: URL { url }
}

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    let digest: String
    let files: [DuplicateFile]

    var id: String { digest }
    var keeper: DuplicateFile { files[0] }
    var fileSize: Int64 { files[0].size }
    var reclaimableSize: Int64 { fileSize * Int64(max(0, files.count - 1)) }

    func contains(_ url: URL) -> Bool {
        files.contains { $0.url == url }
    }
}

struct DuplicateSelection {
    private(set) var urls: Set<URL> = []
    private var keptURLs: [String: URL] = [:]

    func keeper(in group: DuplicateGroup) -> DuplicateFile {
        guard let url = keptURLs[group.id],
              let file = group.files.first(where: { $0.url == url }) else { return group.keeper }
        return file
    }

    mutating func keep(_ file: DuplicateFile, in group: DuplicateGroup) {
        guard group.contains(file.url) else { return }
        keptURLs[group.id] = file.url == group.keeper.url ? nil : file.url
        urls.remove(file.url)
    }

    mutating func setSelected(_ selected: Bool, url: URL, in group: DuplicateGroup) {
        guard url != keeper(in: group).url, group.contains(url) else { return }
        if selected {
            urls.insert(url)
        } else {
            urls.remove(url)
        }
    }

    func allCopiesSelected(in group: DuplicateGroup) -> Bool {
        let keptURL = keeper(in: group).url
        return group.files.allSatisfy { $0.url == keptURL || urls.contains($0.url) }
    }

    mutating func toggleCopies(in group: DuplicateGroup) {
        let copies = copyURLs(in: group)
        if copies.isSubset(of: urls) {
            urls.subtract(copies)
        } else {
            urls.formUnion(copies)
        }
    }

    mutating func selectAll(in groups: [DuplicateGroup]) {
        urls = groups.reduce(into: Set<URL>()) { $0.formUnion(copyURLs(in: $1)) }
    }

    /// Replaces the selection, so hidden copies cannot remain selected after a filtered Select All.
    mutating func selectAll(in groups: [DuplicateGroup], matching matches: Set<URL>) {
        selectAll(in: groups)
        urls.formIntersection(matches)
    }

    mutating func retainSelection(in groups: [DuplicateGroup], matching matches: Set<URL>) {
        let selectable = groups.reduce(into: Set<URL>()) { $0.formUnion(copyURLs(in: $1)) }
        urls.formIntersection(selectable.intersection(matches))
    }

    mutating func clear() {
        urls.removeAll()
    }

    func groupsForReview(in groups: [DuplicateGroup]) -> [DuplicateGroup] {
        groups.compactMap { group in
            let keptFile = keeper(in: group)
            let selected = group.files.filter { $0.url != keptFile.url && urls.contains($0.url) }
            guard !selected.isEmpty else { return nil }
            return DuplicateGroup(digest: group.digest, files: [keptFile] + selected)
        }
    }

    mutating func removeMoved(_ moved: Set<URL>, remainingGroups: Set<String>) {
        urls.subtract(moved)
        keptURLs = keptURLs.filter { remainingGroups.contains($0.key) }
    }

    private func copyURLs(in group: DuplicateGroup) -> Set<URL> {
        let keptURL = keeper(in: group).url
        return Set(group.files.lazy.map(\.url).filter { $0 != keptURL })
    }
}

enum DuplicateFileKind: String, CaseIterable, Identifiable, Sendable {
    case all, images, videos, audio, documents, archives, other

    var id: String { rawValue }

    func matches(_ url: URL) -> Bool {
        self == .all || Self.classify(url) == self
    }

    private static func classify(_ url: URL) -> Self {
        let ext = url.pathExtension.lowercased()
        // Launch Services can return dynamic UTIs before its type database is available.
        // Keep common extensions deterministic in that case and avoid repeated lookups.
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "svg", "raw", "dng", "avif", "ico": return .images
        case "mp4", "mov", "m4v", "avi", "mkv", "webm", "mpeg", "mpg", "3gp": return .videos
        case "mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "ogg", "opus", "alac", "caf": return .audio
        case "zip", "7z", "rar", "tar", "gz", "bz2", "xz", "tgz", "zst": return .archives
        case "txt", "md", "markdown", "rst", "pdf", "doc", "docx", "pages", "odt", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "rtf", "csv", "json", "yaml", "yml", "xml", "log", "html", "css", "swift", "py", "js", "ts", "c", "cpp", "h", "sh", "sql": return .documents
        default: break
        }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .movie) { return .videos }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) { return .archives }
        if type.conforms(to: .text) || type.conforms(to: .pdf)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .presentation)
            || ["doc", "docx", "pages", "odt", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "rtf"].contains(url.pathExtension.lowercased()) {
            return .documents
        }
        return .other
    }
}

enum DuplicateSortKey: String, CaseIterable, Identifiable, Sendable {
    case size, name, modified

    var id: String { rawValue }
}

struct DuplicateResultFilter: Equatable, Sendable {
    var query = ""
    var kind: DuplicateFileKind = .all
    var sortKey: DuplicateSortKey = .size
    var ascending = false

    var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || kind != .all
    }

    func matches(_ file: DuplicateFile) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return kind.matches(file.url) && (text.isEmpty || file.url.path.localizedStandardContains(text))
    }

    /// Keeps whole groups intact. The caller can show matching rows plus the protected copy.
    func groups(from groups: [DuplicateGroup], selection: DuplicateSelection = DuplicateSelection()) -> [DuplicateGroup] {
        groups.filter { !$0.files.isEmpty && $0.files.contains(where: matches) }.sorted { left, right in
            let comparison: ComparisonResult
            switch sortKey {
            case .size:
                comparison = compare(left.reclaimableSize, right.reclaimableSize)
            case .name:
                comparison = selection.keeper(in: left).url.lastPathComponent
                    .localizedStandardCompare(selection.keeper(in: right).url.lastPathComponent)
            case .modified:
                // A group is dated by its newest member, independently of the chosen protected copy.
                comparison = compare(left.files.compactMap(\.modifiedAt).max() ?? .distantPast,
                                     right.files.compactMap(\.modifiedAt).max() ?? .distantPast)
            }
            if comparison != .orderedSame {
                return comparison == (ascending ? .orderedAscending : .orderedDescending)
            }
            return selection.keeper(in: left).url.path < selection.keeper(in: right).url.path
        }
    }

    func matchingCopyURLs(in groups: [DuplicateGroup], selection: DuplicateSelection) -> Set<URL> {
        groups.reduce(into: Set<URL>()) { matches, group in
            guard !group.files.isEmpty else { return }
            let keeper = selection.keeper(in: group).url
            matches.formUnion(group.files.lazy.filter { $0.url != keeper && self.matches($0) }.map(\.url))
        }
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : lhs < rhs ? .orderedAscending : .orderedDescending
    }
}

struct DuplicateIgnoredFile: Codable, Hashable, Sendable {
    let url: URL
    let size: Int64
    let digest: String
    let identity: DuplicateFileIdentity

    init(_ file: DuplicateFile) {
        url = file.url.standardizedFileURL
        size = file.size
        digest = file.digest
        identity = file.identity
    }
}

struct DuplicateIgnoreRule: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let folder: URL
    let files: [DuplicateIgnoredFile]
    let createdAt: Date

    init(group: DuplicateGroup, folder: URL, createdAt: Date = Date()) {
        id = UUID()
        self.folder = folder.standardizedFileURL
        files = group.files.map(DuplicateIgnoredFile.init).sorted { $0.url.path < $1.url.path }
        self.createdAt = createdAt
    }

    func matches(_ group: DuplicateGroup, in folder: URL) -> Bool {
        self.folder == folder.standardizedFileURL
            && files.first?.digest == group.digest && files.count == group.files.count
            && files == group.files.map(DuplicateIgnoredFile.init).sorted { $0.url.path < $1.url.path }
    }
}

struct DuplicateIgnoreRules: Codable, Equatable, Sendable {
    private(set) var rules: [DuplicateIgnoreRule] = []

    func contains(_ group: DuplicateGroup, in folder: URL) -> Bool {
        rules.contains { $0.matches(group, in: folder) }
    }

    @discardableResult
    mutating func ignore(_ group: DuplicateGroup, in folder: URL) -> DuplicateIgnoreRule {
        if let existing = rules.first(where: { $0.matches(group, in: folder) }) { return existing }
        let rule = DuplicateIgnoreRule(group: group, folder: folder)
        rules.append(rule)
        return rule
    }

    mutating func remove(id: UUID) {
        rules.removeAll { $0.id == id }
    }

    /// Only reconcile a completed scan of the same root. Different roots do not invalidate each other.
    /// Full snapshots ensure adding/removing/renaming/replacing/editing any member revokes the rule.
    @discardableResult
    mutating func reconcile(_ result: DuplicateScanResult) -> Int {
        let previousCount = rules.count
        rules.removeAll { rule in
            rule.folder == result.folder.standardizedFileURL
                && !result.groups.contains { rule.matches($0, in: result.folder) }
        }
        return previousCount - rules.count
    }
}

enum DuplicateIgnoreStoreError: Error {
    case invalidFile
    case unsupportedVersion
    case tooLarge
}

/// The caller supplies an application-owned path, or a separate disposable path for fixture runs.
/// No file is created until Save. Writes are atomic; decoding failures are surfaced to the caller.
struct DuplicateIgnoreStore {
    let fileURL: URL
    private static let maximumBytes = 8 * 1024 * 1024

    private struct Document: Codable {
        let version: Int
        let value: DuplicateIgnoreRules
    }

    func load() throws -> DuplicateIgnoreRules {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // fileExists follows symlinks; a dangling link must still be rejected.
            if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw DuplicateIgnoreStoreError.invalidFile
            }
            return DuplicateIgnoreRules()
        }
        let attributes = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
            throw DuplicateIgnoreStoreError.invalidFile
        }
        guard (attributes.fileSize ?? 0) <= Self.maximumBytes else { throw DuplicateIgnoreStoreError.tooLarge }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= Self.maximumBytes else { throw DuplicateIgnoreStoreError.tooLarge }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1 else { throw DuplicateIgnoreStoreError.unsupportedVersion }
        return document.value
    }

    func save(_ value: DuplicateIgnoreRules) throws {
        let data = try JSONEncoder().encode(Document(version: 1, value: value))
        guard data.count <= Self.maximumBytes else { throw DuplicateIgnoreStoreError.tooLarge }
        // Preserve an unreadable, corrupt, or newer-version store for diagnosis instead of overwriting it.
        _ = try load()
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let parentAttributes = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentAttributes.isDirectory == true, parentAttributes.isSymbolicLink != true else {
            throw DuplicateIgnoreStoreError.invalidFile
        }
        if let attributes = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
                throw DuplicateIgnoreStoreError.invalidFile
            }
        }
        try data.write(to: fileURL, options: .atomic)
    }
}

enum DuplicateSkipReason: String, Hashable, Sendable {
    case symbolicLink
    case package
    case cloudPlaceholder
    case hardLink
    case inaccessible
    case changedDuringScan
    case unreadable

    var label: String {
        switch self {
        case .symbolicLink: return String(localized: "Symbolic link")
        case .package: return String(localized: "Package contents")
        case .cloudPlaceholder: return String(localized: "Cloud-only file")
        case .hardLink: return String(localized: "Hard-linked copy")
        case .inaccessible: return String(localized: "Access denied")
        case .changedDuringScan: return String(localized: "Changed during scan")
        case .unreadable: return String(localized: "Could not read")
        }
    }
}

struct DuplicateSkippedFile: Identifiable, Hashable, Sendable {
    let url: URL
    let reason: DuplicateSkipReason
    let detail: String?

    var id: String { "\(reason.rawValue):\(url.path)" }
}

struct DuplicateScanResult: Hashable, Sendable {
    let folder: URL
    let groups: [DuplicateGroup]
    let skippedFiles: [DuplicateSkippedFile]
    let filesInspected: Int
    let bytesHashed: Int64

    var duplicateFileCount: Int { groups.reduce(0) { $0 + $1.files.count } }
    var reclaimableSize: Int64 { groups.reduce(0) { $0 + $1.reclaimableSize } }
}

struct DuplicateScanProgress: Hashable, Sendable {
    enum Phase: String, Hashable, Sendable {
        case discovering
        case hashing
    }

    let phase: Phase
    let filesInspected: Int
    let filesToHash: Int
    let filesHashed: Int
    let bytesHashed: Int64
    let currentURL: URL?

    var fractionCompleted: Double? {
        guard phase == .hashing, filesToHash > 0 else { return nil }
        return min(1, Double(filesHashed) / Double(filesToHash))
    }
}

struct DuplicateTrashFailure: Identifiable, Hashable, Sendable {
    let url: URL
    let message: String

    var id: URL { url }
}

struct DuplicateTrashReport: Hashable, Sendable {
    let trashedFiles: [DuplicateFile]
    let failures: [DuplicateTrashFailure]
    var cancelled = false

    var bytesMovedToTrash: Int64 { trashedFiles.reduce(0) { $0 + $1.size } }
}

enum DuplicateFinderError: LocalizedError, Equatable {
    case invalidFolder(String)
    case invalidSelection(String)
    case keeperChanged(String)
    case fileChanged(String)
    case contentChanged(String)

    var errorDescription: String? {
        switch self {
        case .invalidFolder(let path):
            return String(localized: "The selected folder cannot be scanned: \(path)")
        case .invalidSelection(let path):
            return String(localized: "The protected copy cannot be moved to Trash: \(path)")
        case .keeperChanged(let path):
            return String(localized: "The copy marked Keep is missing or changed: \(path)")
        case .fileChanged(let path):
            return String(localized: "A selected file is missing or changed: \(path)")
        case .contentChanged(let path):
            return String(localized: "A selected file no longer matches its kept copy: \(path)")
        }
    }
}

actor DuplicateFinder {
    typealias ProgressHandler = @Sendable (DuplicateScanProgress) async -> Void
    typealias TrashHandler = (URL) throws -> Void
    typealias PreTrashHandler = (URL) throws -> Void

    private struct Candidate: Sendable {
        let url: URL
        let identity: DuplicateFileIdentity
        let modifiedAt: Date?
    }

    private struct DigestKey: Hashable {
        let size: Int64
        let digest: String
    }

    private let fileManager: FileManager
    private let trashHandler: TrashHandler
    private let preTrashHandler: PreTrashHandler?

    init(
        fileManager: FileManager = .default,
        trashHandler: TrashHandler? = nil,
        preTrashHandler: PreTrashHandler? = nil
    ) {
        self.fileManager = fileManager
        self.preTrashHandler = preTrashHandler
        self.trashHandler = trashHandler ?? { url in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        }
    }

    func scan(
        folder rawFolder: URL,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> DuplicateScanResult {
        let folder = rawFolder.standardizedFileURL
        guard Self.identity(at: folder) != nil, Self.isDirectory(at: folder) else {
            throw DuplicateFinderError.invalidFolder(folder.path)
        }
        guard !Self.isSymbolicLink(at: folder), !Self.isPackage(at: folder), !Self.isCloudPlaceholder(at: folder) else {
            throw DuplicateFinderError.invalidFolder(folder.path)
        }
        var candidatesBySize: [Int64: [Candidate]] = [:]
        var seenPhysicalFiles: [DuplicatePhysicalFileID: URL] = [:]
        var skipped: [DuplicateSkippedFile] = []
        var filesInspected = 0
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .contentModificationDateKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { url, error in
                skipped.append(DuplicateSkippedFile(
                    url: url.standardizedFileURL,
                    reason: .inaccessible,
                    detail: error.localizedDescription
                ))
                return true
            }
        ) else {
            throw DuplicateFinderError.invalidFolder(folder.path)
        }

        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let normalizedURL = url.standardizedFileURL
            if Self.isSymbolicLink(at: normalizedURL) {
                enumerator.skipDescendants()
                skipped.append(DuplicateSkippedFile(url: normalizedURL, reason: .symbolicLink, detail: nil))
                continue
            }
            if Self.isPackage(at: normalizedURL) {
                enumerator.skipDescendants()
                skipped.append(DuplicateSkippedFile(url: normalizedURL, reason: .package, detail: nil))
                continue
            }
            if Self.isCloudPlaceholder(at: normalizedURL) {
                enumerator.skipDescendants()
                skipped.append(DuplicateSkippedFile(url: normalizedURL, reason: .cloudPlaceholder, detail: nil))
                continue
            }
            guard let identity = Self.identity(at: normalizedURL), Self.isRegularFile(at: normalizedURL) else {
                continue
            }

            filesInspected += 1
            if let firstURL = seenPhysicalFiles[identity.physicalID] {
                skipped.append(DuplicateSkippedFile(
                    url: normalizedURL,
                    reason: .hardLink,
                    detail: String(localized: "Shares storage with \(firstURL.lastPathComponent)")
                ))
            } else {
                seenPhysicalFiles[identity.physicalID] = normalizedURL
                let modifiedAt = try? normalizedURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                candidatesBySize[identity.size, default: []].append(Candidate(
                    url: normalizedURL,
                    identity: identity,
                    modifiedAt: modifiedAt
                ))
            }

            if filesInspected == 1 || filesInspected.isMultiple(of: 64) {
                await progress(DuplicateScanProgress(
                    phase: .discovering,
                    filesInspected: filesInspected,
                    filesToHash: 0,
                    filesHashed: 0,
                    bytesHashed: 0,
                    currentURL: normalizedURL
                ))
            }
        }

        try Task.checkCancellation()
        let candidates = candidatesBySize
            .filter { $0.value.count > 1 }
            .values
            .flatMap { $0 }
            .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        var filesByDigest: [DigestKey: [DuplicateFile]] = [:]
        var filesHashed = 0
        var bytesHashed: Int64 = 0

        await progress(DuplicateScanProgress(
            phase: .hashing,
            filesInspected: filesInspected,
            filesToHash: candidates.count,
            filesHashed: 0,
            bytesHashed: 0,
            currentURL: candidates.first?.url
        ))

        for candidate in candidates {
            try Task.checkCancellation()
            do {
                let digest = try Self.hashFile(at: candidate.url)
                if Self.identity(at: candidate.url) != candidate.identity {
                    skipped.append(DuplicateSkippedFile(url: candidate.url, reason: .changedDuringScan, detail: nil))
                } else {
                    let file = DuplicateFile(
                        url: candidate.url,
                        size: candidate.identity.size,
                        modifiedAt: candidate.modifiedAt,
                        digest: digest,
                        identity: candidate.identity
                    )
                    filesByDigest[DigestKey(size: candidate.identity.size, digest: digest), default: []].append(file)
                    bytesHashed += candidate.identity.size
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skipped.append(DuplicateSkippedFile(
                    url: candidate.url,
                    reason: .unreadable,
                    detail: error.localizedDescription
                ))
            }
            filesHashed += 1
            await progress(DuplicateScanProgress(
                phase: .hashing,
                filesInspected: filesInspected,
                filesToHash: candidates.count,
                filesHashed: filesHashed,
                bytesHashed: bytesHashed,
                currentURL: candidate.url
            ))
        }

        let groups = filesByDigest.values
            .filter { $0.count > 1 }
            .map { files -> DuplicateGroup in
                let sortedFiles = files.sorted {
                    if $0.modifiedAt != $1.modifiedAt {
                        return ($0.modifiedAt ?? .distantFuture) < ($1.modifiedAt ?? .distantFuture)
                    }
                    return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
                }
                return DuplicateGroup(digest: sortedFiles[0].digest, files: sortedFiles)
            }
            .sorted {
                if $0.reclaimableSize != $1.reclaimableSize {
                    return $0.reclaimableSize > $1.reclaimableSize
                }
                return $0.keeper.url.path.localizedStandardCompare($1.keeper.url.path) == .orderedAscending
            }
        let uniqueSkipped = Dictionary(grouping: skipped, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }

        return DuplicateScanResult(
            folder: folder,
            groups: groups,
            skippedFiles: uniqueSkipped,
            filesInspected: filesInspected,
            bytesHashed: bytesHashed
        )
    }

    func moveToTrash(group: DuplicateGroup, selectedIDs: Set<URL>) throws -> DuplicateTrashReport {
        guard !selectedIDs.contains(group.keeper.url) else {
            throw DuplicateFinderError.invalidSelection(group.keeper.url.path)
        }
        let selectedFiles = group.files.filter { selectedIDs.contains($0.url) }
        guard selectedFiles.count == selectedIDs.count else {
            let unknownPath = selectedIDs.first { !group.contains($0) }?.path ?? "Unknown file"
            throw DuplicateFinderError.invalidSelection(unknownPath)
        }
        guard !selectedFiles.isEmpty else {
            return DuplicateTrashReport(trashedFiles: [], failures: [])
        }

        try Self.validateKeeper(group.keeper, expectedDigest: group.digest)
        var selectedPhysicalIDs: Set<DuplicatePhysicalFileID> = [group.keeper.identity.physicalID]
        for file in selectedFiles {
            try Self.validateSelectedFile(file, expectedDigest: group.digest)
            guard selectedPhysicalIDs.insert(file.identity.physicalID).inserted else {
                throw DuplicateFinderError.fileChanged(file.url.path)
            }
        }

        var trashed: [DuplicateFile] = []
        var failures: [DuplicateTrashFailure] = []
        for file in selectedFiles {
            do {
                try Self.validateKeeper(group.keeper, expectedDigest: group.digest)
                try Self.validateSelectedFile(file, expectedDigest: group.digest)
                try preTrashHandler?(file.url)
                try Self.validateKeeper(group.keeper, expectedDigest: group.digest)
                try Self.validateSelectedFile(file, expectedDigest: group.digest)
                try trashHandler(file.url)
                trashed.append(file)
            } catch is CancellationError {
                return DuplicateTrashReport(trashedFiles: trashed, failures: failures, cancelled: true)
            } catch {
                failures.append(DuplicateTrashFailure(url: file.url, message: error.localizedDescription))
            }
        }
        do {
            try Self.validateKeeper(group.keeper, expectedDigest: group.digest)
        } catch is CancellationError {
            return DuplicateTrashReport(trashedFiles: trashed, failures: failures, cancelled: true)
        } catch {
            guard !trashed.isEmpty else { throw error }
            failures.append(DuplicateTrashFailure(url: group.keeper.url, message: error.localizedDescription))
        }
        return DuplicateTrashReport(trashedFiles: trashed, failures: failures)
    }

    private static func validateKeeper(_ file: DuplicateFile, expectedDigest: String) throws {
        guard identity(at: file.url) == file.identity, !isCloudPlaceholder(at: file.url) else {
            throw DuplicateFinderError.keeperChanged(file.url.path)
        }
        do {
            guard try hashFile(at: file.url) == expectedDigest else {
                throw DuplicateFinderError.keeperChanged(file.url.path)
            }
            guard identity(at: file.url) == file.identity, !isCloudPlaceholder(at: file.url) else {
                throw DuplicateFinderError.keeperChanged(file.url.path)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DuplicateFinderError {
            throw error
        } catch {
            throw DuplicateFinderError.keeperChanged(file.url.path)
        }
    }

    private static func validateSelectedFile(_ file: DuplicateFile, expectedDigest: String) throws {
        guard identity(at: file.url) == file.identity, !isCloudPlaceholder(at: file.url) else {
            throw DuplicateFinderError.fileChanged(file.url.path)
        }
        do {
            guard try hashFile(at: file.url) == expectedDigest else {
                throw DuplicateFinderError.contentChanged(file.url.path)
            }
            guard identity(at: file.url) == file.identity, !isCloudPlaceholder(at: file.url) else {
                throw DuplicateFinderError.fileChanged(file.url.path)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DuplicateFinderError {
            throw error
        } catch {
            throw DuplicateFinderError.fileChanged(file.url.path)
        }
    }

    private static func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func identity(at url: URL) -> DuplicateFileIdentity? {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return nil }
        return DuplicateFileIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            size: Int64(information.st_size),
            modifiedSeconds: Int64(information.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(information.st_mtimespec.tv_nsec),
            flags: information.st_flags
        )
    }

    private static func isRegularFile(at url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFREG
    }

    private static func isDirectory(at url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFDIR
    }

    private static func isSymbolicLink(at url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFLNK
    }

    private static func isPackage(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    private static func isCloudPlaceholder(at url: URL) -> Bool {
        if url.pathExtension.lowercased() == "icloud" { return true }
        if let identity = identity(at: url), isDatalessFile(flags: identity.flags) { return true }
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]) else { return false }
        guard values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
            && values.ubiquitousItemDownloadingStatus != .downloaded
    }

    static func isDatalessFile(flags: UInt32) -> Bool {
        flags & UInt32(SF_DATALESS) != 0
    }
}
