import Darwin
import Foundation

struct RecoveryEntry: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case prepared, stored, restoring, restored, purging, purged, failed, missing, purgeFailed
        case copyChanged
    }
    var version = 1
    let id: UUID
    let batchID: UUID
    let originalPath: String
    let name: String
    let category: String
    let bytes: Int64
    let snapshot: RecoverySnapshot
    let created: Date
    var state: State
    var note: String?

    var canRestore: Bool { state == .stored }
    var canPurge: Bool { state == .stored || state == .purgeFailed }
    var canSaveCopy: Bool { state == .copyChanged }
}

struct RecoveryCatalog: Sendable {
    var entries: [RecoveryEntry] = []
    var warnings: [String] = []
}

enum RecoveryCheckpoint: Sendable {
    case beforePrepare, afterMove, afterRestore, beforePurge
}

actor RecoveryStore {
    let root: URL
    private let allowedRoots: [String]
    private let allowedRootItems: Set<String>
    private let copyDestinationRoot: URL?
    private let pathValidator: (@Sendable (String, String, RecoverySnapshot) -> Bool)?
    private let fault: (@Sendable (RecoveryCheckpoint) throws -> Void)?

    init(root: URL, allowedRoots: [URL], allowedRootItems: [URL] = [],
         copyDestinationRoot: URL? = nil,
         pathValidator: (@Sendable (String, String, RecoverySnapshot) -> Bool)? = nil,
         fault: (@Sendable (RecoveryCheckpoint) throws -> Void)? = nil) {
        self.root = root
        self.allowedRoots = allowedRoots.compactMap { try? RecoveryFileSystem.directoryWalkPath($0.path) }
        self.allowedRootItems = Set(allowedRootItems.compactMap { try? RecoveryFileSystem.directoryWalkPath($0.path) })
        self.copyDestinationRoot = copyDestinationRoot
        self.pathValidator = pathValidator
        self.fault = fault
    }

    struct Outcome: Sendable { let entry: RecoveryEntry; let warning: String? }

    private func validateOriginal(_ path: String, category: String, snapshot: RecoverySnapshot) throws {
        let original = try RecoveryFileSystem.directoryWalkPath(path, requireNormalized: true)
        let vault = try RecoveryFileSystem.directoryWalkPath(root.path)
        guard (allowedRoots.contains(where: { RecoveryFileSystem.inside(original, $0) }) || allowedRootItems.contains(original)),
              !RecoveryFileSystem.inside(original, vault), original != vault,
              !RecoveryFileSystem.inside(vault, original) else { throw RecoveryFailure.unsafePath }
        guard snapshot.isDirectory || snapshot.isRegularFile,
              pathValidator?(path, category, snapshot) ?? true else { throw RecoveryFailure.unsafePath }
    }

    private func withStore<T>(_ body: (Int32, Int32) throws -> T) throws -> T {
        let rootFD = try RecoveryFileSystem.directory(root.path, create: true)
        defer { close(rootFD) }
        var metadata = stat()
        guard fstat(rootFD, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else {
            throw RecoveryFailure.unsafePath
        }
        let lock = openat(rootFD, "operation.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw RecoveryFailure.system("open recovery lock", errno) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw RecoveryFailure.busy }
        defer { flock(lock, LOCK_UN) }
        var lockMetadata = stat()
        guard fstat(lock, &lockMetadata) == 0, lockMetadata.st_uid == getuid(),
              lockMetadata.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG) else { throw RecoveryFailure.unsafePath }
        for name in ["entries", "objects"] {
            guard mkdirat(rootFD, name, 0o700) == 0 || errno == EEXIST else {
                throw RecoveryFailure.system("create recovery directory", errno)
            }
        }
        let records = openat(rootFD, "entries", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard records >= 0 else { throw RecoveryFailure.unsafePath }
        defer { close(records) }
        let objects = openat(rootFD, "objects", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard objects >= 0 else { throw RecoveryFailure.unsafePath }
        defer { close(objects) }
        return try body(records, objects)
    }

    private func save(_ entry: RecoveryEntry, records: Int32) throws {
        try RecoveryFileSystem.write(JSONEncoder().encode(entry), at: records, name: entry.id.uuidString + ".json")
    }

    private func load(_ id: UUID, records: Int32) throws -> RecoveryEntry {
        let entry = try JSONDecoder().decode(RecoveryEntry.self,
            from: RecoveryFileSystem.read(at: records, name: id.uuidString + ".json"))
        guard entry.id == id, entry.version == 1 else { throw RecoveryFailure.invalidRecord }
        guard entry.bytes >= 0 else { throw RecoveryFailure.invalidRecord }
        try validateOriginal(entry.originalPath, category: entry.category, snapshot: entry.snapshot)
        return entry
    }

    func stage(path: String, name: String, category: String, bytes: Int64,
               expected: RecoverySnapshot, batchID: UUID = UUID()) throws -> Outcome {
        try validateOriginal(path, category: category, snapshot: expected)
        if Task.isCancelled { throw RecoveryFailure.cancelled }
        return try withStore { records, objects in
            let parentPath = (path as NSString).deletingLastPathComponent
            let source = try RecoveryFileSystem.directory(parentPath)
            defer { close(source) }
            let leaf = (path as NSString).lastPathComponent
            let current = try RecoveryFileSystem.snapshot(at: source, name: leaf)
            guard current == expected else { throw RecoveryFailure.changed }
            var entry = RecoveryEntry(id: UUID(), batchID: batchID, originalPath: path,
                name: name, category: category, bytes: max(0, bytes), snapshot: current,
                created: Date(), state: .prepared)
            try fault?(.beforePrepare)
            try save(entry, records: records)
            // Recheck immediately before the descriptor-relative, exclusive move.
            guard try RecoveryFileSystem.snapshot(at: source, name: leaf) == expected else {
                entry.state = .failed
                try save(entry, records: records)
                throw RecoveryFailure.changed
            }
            do {
                try RecoveryFileSystem.move(from: source, name: leaf, to: objects, target: entry.id.uuidString)
            } catch {
                entry.state = .failed
                entry.note = error.localizedDescription
                try? save(entry, records: records)
                throw error
            }
            entry.state = .stored
            do {
                try fault?(.afterMove)
                try save(entry, records: records)
                return Outcome(entry: entry, warning: nil)
            } catch {
                return Outcome(entry: entry, warning: String(localized: "The file is in Recovery. Its interrupted record will be checked on reload."))
            }
        }
    }

    func catalog() throws -> RecoveryCatalog {
        try withStore { records, objects in
            var result = RecoveryCatalog()
            for name in try RecoveryFileSystem.names(in: records) where name.hasSuffix(".json") {
                try Task.checkCancellation()
                guard let id = UUID(uuidString: String(name.dropLast(5))) else {
                    result.warnings.append(String(localized: "An unrecognized recovery record was kept for review."))
                    continue
                }
                do {
                    var entry = try load(id, records: records)
                    let hasPayload = [.prepared, .restoring, .purging, .stored].contains(entry.state)
                    let stored = hasPayload
                        ? try? RecoveryFileSystem.snapshot(at: objects, name: id.uuidString, includeTree: false)
                        : nil
                    if entry.state == .prepared || entry.state == .restoring || entry.state == .purging {
                        if let stored, stored.sameObject(as: entry.snapshot) {
                            entry.state = entry.state == .purging ? .purgeFailed : .stored
                        } else if stored == nil,
                                  let original = RecoverySnapshot.capture(entry.originalPath),
                                  original.sameObject(as: entry.snapshot) {
                            entry.state = entry.state == .restoring ? .restored : .failed
                        } else if stored == nil && entry.state == .purging {
                            entry.state = .purged
                        } else {
                            entry.state = .missing
                        }
                        try save(entry, records: records)
                    }
                    if entry.state == .stored {
                        // The on-disk record stays compatible with older builds. A fresh catalog
                        // derives the copy status from the verified object, including directory contents.
                        if let stored, stored.sameObject(as: entry.snapshot) {
                            let verified = stored.isDirectory
                                ? try? RecoveryFileSystem.snapshot(at: objects, name: id.uuidString)
                                : stored
                            if let verified, verified.sameObject(as: entry.snapshot) {
                                if verified != entry.snapshot { entry.state = .copyChanged }
                            } else {
                                entry.state = .missing
                            }
                        } else {
                            entry.state = .missing
                        }
                    }
                    result.entries.append(entry)
                } catch {
                    result.warnings.append(name + ": " + error.localizedDescription)
                }
            }
            result.entries.sort { $0.created > $1.created }
            return result
        }
    }

    func restore(_ id: UUID) throws -> Outcome {
        try withStore { records, objects in
            var entry = try load(id, records: records)
            guard entry.canRestore else { throw RecoveryFailure.invalidRecord }
            let stored = try RecoveryFileSystem.snapshot(at: objects, name: id.uuidString)
            guard stored == entry.snapshot else { throw RecoveryFailure.recoveryCopyChanged }
            let original = try RecoveryFileSystem.directoryWalkPath(entry.originalPath)
            let parentPath = (original as NSString).deletingLastPathComponent
            // Recreate missing parents inside an approved root only, never a root itself.
            guard let root = allowedRoots.filter({ RecoveryFileSystem.inside(original, $0) || (allowedRootItems.contains(original) && original == $0) })
                .max(by: { $0.count < $1.count }) else { throw RecoveryFailure.unsafePath }
            let approvedPath = root == original ? (root as NSString).deletingLastPathComponent : root
            let approved = try RecoveryFileSystem.directory(approvedPath)
            close(approved)
            let parent = try RecoveryFileSystem.directory(parentPath, create: true)
            defer { close(parent) }
            let leaf = (entry.originalPath as NSString).lastPathComponent
            var metadata = stat()
            if fstatat(parent, leaf, &metadata, AT_SYMLINK_NOFOLLOW) == 0 { throw RecoveryFailure.conflict }
            guard errno == ENOENT else { throw RecoveryFailure.system("check restore destination", errno) }
            entry.state = .restoring
            try save(entry, records: records)
            do {
                try RecoveryFileSystem.move(from: objects, name: id.uuidString, to: parent, target: leaf)
            } catch {
                entry.state = .stored
                try? save(entry, records: records)
                throw error
            }
            entry.state = .restored
            do {
                try fault?(.afterRestore)
                try save(entry, records: records)
                return Outcome(entry: entry, warning: nil)
            } catch {
                return Outcome(entry: entry, warning: String(localized: "The file was restored. Its interrupted record will be checked on reload."))
            }
        }
    }

    func saveCopy(_ id: UUID, to destination: URL) throws {
        guard destination.isFileURL else { throw RecoveryFailure.copyDestinationInvalid }
        let target = try RecoveryFileSystem.directoryWalkPath(destination.path)
        let vault = try RecoveryFileSystem.directoryWalkPath(root.path).lowercased()
        let targetKey = target.lowercased()
        guard target != "/", targetKey != vault, !RecoveryFileSystem.inside(targetKey, vault) else {
            throw RecoveryFailure.copyDestinationInvalid
        }
        if let copyDestinationRoot {
            let sample = try RecoveryFileSystem.directoryWalkPath(copyDestinationRoot.path)
            guard RecoveryFileSystem.inside(target, sample) else { throw RecoveryFailure.copyDestinationInvalid }
        }
        try withStore { records, objects in
            let entry = try load(id, records: records)
            let original = try RecoveryFileSystem.directoryWalkPath(entry.originalPath)
            guard entry.state == .stored, original.lowercased() != targetKey else {
                throw RecoveryFailure.copyDestinationInvalid
            }
            let current = try RecoveryFileSystem.snapshot(at: objects, name: id.uuidString)
            guard current.sameObject(as: entry.snapshot) else { throw RecoveryFailure.unverified }
            let parent = try RecoveryFileSystem.directory((target as NSString).deletingLastPathComponent)
            defer { close(parent) }
            try RecoveryFileSystem.saveCopy(from: objects, name: id.uuidString, expected: entry.snapshot,
                                          to: parent, target: (target as NSString).lastPathComponent)
        }
    }

    func purge(_ id: UUID, confirmed: Bool) throws -> RecoveryEntry {
        guard confirmed else { throw RecoveryFailure.unsupported }
        return try withStore { records, objects in
            var entry = try load(id, records: records)
            guard entry.canPurge else { throw RecoveryFailure.invalidRecord }
            let current = try RecoveryFileSystem.snapshot(at: objects, name: id.uuidString)
            guard entry.state == .purgeFailed ? current.sameObject(as: entry.snapshot) : current == entry.snapshot else {
                throw RecoveryFailure.changed
            }
            try fault?(.beforePurge)
            entry.state = .purging
            try save(entry, records: records)
            do {
                try RecoveryFileSystem.erase(at: objects, name: id.uuidString, expected: current)
            } catch {
                entry.state = .purgeFailed
                entry.note = error.localizedDescription
                try? save(entry, records: records)
                throw error
            }
            entry.state = .purged
            try save(entry, records: records)
            return entry
        }
    }
}
