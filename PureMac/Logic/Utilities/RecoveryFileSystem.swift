import CryptoKit
import Darwin
import Foundation

enum RecoveryFailure: LocalizedError {
    case unsafePath, changed, recoveryCopyChanged, copyDestinationExists, copyDestinationInvalid
    case unverified, conflict, missing, busy, invalidRecord, unsupported, cancelled
    case system(String, Int32)

    var errorDescription: String? {
        switch self {
        case .unsafePath: return String(localized: "Recovery refused an unsafe path or symbolic link.")
        case .changed: return String(localized: "The file changed after review. Scan again before cleaning.")
        case .recoveryCopyChanged: return String(localized: "The recovery copy changed. Review it and save a separate copy.")
        case .copyDestinationExists: return String(localized: "An item already exists there. Choose a new name or location.")
        case .copyDestinationInvalid: return String(localized: "Choose a new location outside the recovery storage and original path.")
        case .unverified: return String(localized: "Not all files could be verified. The item was kept in place.")
        case .conflict: return String(localized: "An item already exists at the original location. Both copies were kept.")
        case .missing: return String(localized: "The recovery copy is missing. No other file was changed.")
        case .busy: return String(localized: "Recovery is busy in another operation. Try again shortly.")
        case .invalidRecord: return String(localized: "The recovery record is invalid. Its files were kept for review.")
        case .unsupported: return String(localized: "This cleanup action cannot be restored and is not available in recoverable cleanup.")
        case .cancelled: return String(localized: "The operation stopped. Completed moves remain in Recovery.")
        case .system(let operation, let code): return operation + ": " + String(cString: strerror(code))
        }
    }
}

struct RecoverySnapshot: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let treeDigest: String?
    let changeSeconds: Int64?
    let changeNanoseconds: Int64?

    init(_ value: stat, treeDigest: String? = nil, trackChanges: Bool = false) {
        device = value.st_dev
        inode = value.st_ino
        mode = value.st_mode
        size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        self.treeDigest = treeDigest
        changeSeconds = trackChanges ? Int64(value.st_ctimespec.tv_sec) : nil
        changeNanoseconds = trackChanges ? Int64(value.st_ctimespec.tv_nsec) : nil
    }

    static func capture(_ path: String, includeTree: Bool = true) -> RecoverySnapshot? {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              let parent = try? RecoveryFileSystem.directory((path as NSString).deletingLastPathComponent) else { return nil }
        defer { close(parent) }
        return try? RecoveryFileSystem.snapshot(at: parent, name: (path as NSString).lastPathComponent, includeTree: includeTree)
    }

    var isDirectory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    var isRegularFile: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }
    func sameObject(as other: Self) -> Bool {
        device == other.device && inode == other.inode && mode & UInt16(S_IFMT) == other.mode & UInt16(S_IFMT)
    }
}

/// All mutation uses open directory descriptors and no-follow path components.
/// A rename is exclusive: neither cleanup nor restore can overwrite another file.
enum RecoveryFileSystem {
    static func canonicalExisting(_ path: String) throws -> String {
        guard let buffer = realpath(path, nil) else { throw RecoveryFailure.system("realpath", errno) }
        defer { free(buffer) }
        return String(cString: buffer)
    }

    static func inside(_ path: String, _ root: String) -> Bool {
        path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func checkDirectory(_ path: String) throws {
        close(try directory(path))
    }

    static func directoryWalkPath(_ path: String, requireNormalized: Bool = false) throws -> String {
        let components = path.unicodeScalars.split(separator: "/").map(String.init)
        guard path.unicodeScalars.first == "/", !path.utf8.contains(0),
              !components.contains("."), !components.contains("..") else { throw RecoveryFailure.unsafePath }
        // Foundation can change the spelling of /private/tmp depending on
        // whether the file exists. Check the path syntax before resolving aliases.
        let normalized = "/" + components.joined(separator: "/")
        guard !requireNormalized || path == normalized else { throw RecoveryFailure.unsafePath }
        for (alias, target) in [("/var", "/private/var"), ("/tmp", "/private/tmp")]
        where normalized == alias || inside(normalized, alias) {
            guard try canonicalExisting(alias) == target else { throw RecoveryFailure.unsafePath }
            return target + normalized.dropFirst(alias.count)
        }
        return normalized
    }

    static func directory(_ path: String, create: Bool = false) throws -> Int32 {
        let walkPath = try directoryWalkPath(path)
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw RecoveryFailure.system("open", errno) }
        do {
            for component in walkPath.unicodeScalars.split(separator: "/").map(String.init) {
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && create {
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else {
                        throw RecoveryFailure.system("mkdir", errno)
                    }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw RecoveryFailure.system("open directory", errno) }
                close(fd)
                fd = next
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    static func snapshot(at fd: Int32, name: String, includeTree: Bool = true) throws -> RecoverySnapshot {
        try snapshot(at: fd, name: name, includeTree: includeTree, trackChanges: false, allowLink: false)
    }

    static func trashReviewSnapshot(_ url: URL) -> RecoverySnapshot? {
        guard url.isFileURL,
              let path = try? directoryWalkPath(url.path),
              let parent = try? directory((path as NSString).deletingLastPathComponent) else { return nil }
        defer { close(parent) }
        return try? snapshot(at: parent, name: (path as NSString).lastPathComponent,
                             includeTree: true, trackChanges: true, allowLink: false)
    }

    private static func snapshot(at fd: Int32, name: String, includeTree: Bool,
                                 trackChanges: Bool, allowLink: Bool) throws -> RecoverySnapshot {
        var value = stat()
        guard fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { throw RecoveryFailure.missing }
            throw RecoveryFailure.system("read metadata", errno)
        }
        let snapshot = RecoverySnapshot(value, trackChanges: trackChanges)
        let isLink = value.st_mode & UInt16(S_IFMT) == UInt16(S_IFLNK)
        guard snapshot.isDirectory || snapshot.isRegularFile || (allowLink && isLink) else {
            throw RecoveryFailure.unsafePath
        }
        if snapshot.isDirectory && includeTree {
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw RecoveryFailure.system("verify directory", errno) }
            defer { close(child) }
            var opened = stat()
            guard fstat(child, &opened) == 0, RecoverySnapshot(opened, trackChanges: trackChanges) == snapshot else {
                throw RecoveryFailure.changed
            }
            var digest = SHA256()
            for entry in try names(in: child) {
                if Task.isCancelled { throw RecoveryFailure.cancelled }
                // Framework links inside application bundles are reviewed as links, never followed.
                let item = try self.snapshot(at: child, name: entry, includeTree: true,
                                             trackChanges: trackChanges, allowLink: trackChanges)
                let metadata = "\(entry.utf8.count):\(entry):\(item.device):\(item.inode):\(item.mode):\(item.size):\(item.modifiedSeconds):\(item.modifiedNanoseconds):\(item.treeDigest ?? "")"
                digest.update(data: Data(metadata.utf8))
                if let seconds = item.changeSeconds, let nanoseconds = item.changeNanoseconds {
                    digest.update(data: Data(":\(seconds):\(nanoseconds)".utf8))
                }
            }
            var after = stat()
            guard fstat(child, &after) == 0, RecoverySnapshot(after, trackChanges: trackChanges) == snapshot else {
                throw RecoveryFailure.changed
            }
            return RecoverySnapshot(value, treeDigest: digest.finalize().map { String(format: "%02x", $0) }.joined(),
                                    trackChanges: trackChanges)
        }
        return snapshot
    }

    static func names(in fd: Int32) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { throw RecoveryFailure.system("dup", errno) }
        guard let stream = fdopendir(copy) else { close(copy); throw RecoveryFailure.system("list", errno) }
        defer { closedir(stream) }
        var names: [String] = []
        errno = 0
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw RecoveryFailure.system("list", errno) }
        return names.sorted()
    }

    static func move(from sourceFD: Int32, name: String, to targetFD: Int32, target: String) throws {
        guard renameatx_np(sourceFD, name, targetFD, target, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST || errno == ENOTEMPTY { throw RecoveryFailure.conflict }
            throw RecoveryFailure.system("move", errno)
        }
        _ = fsync(sourceFD)
        _ = fsync(targetFD)
    }

    /// Write to a private staging directory on the destination volume, then publish the whole copy exclusively.
    static func saveCopy(from sourceFD: Int32, name: String, expected: RecoverySnapshot,
                         to targetFD: Int32, target: String) throws {
        var destination = stat()
        guard fstatat(targetFD, target, &destination, AT_SYMLINK_NOFOLLOW) != 0 else {
            throw RecoveryFailure.copyDestinationExists
        }
        guard errno == ENOENT else { throw RecoveryFailure.system("check copy destination", errno) }

        let before = try snapshot(at: sourceFD, name: name, includeTree: true, trackChanges: true, allowLink: false)
        guard before.sameObject(as: expected) else { throw RecoveryFailure.unverified }
        let staging = ".cachora-copy-" + UUID().uuidString
        guard mkdirat(targetFD, staging, 0o700) == 0 else { throw RecoveryFailure.system("prepare copy", errno) }
        let staged = try snapshot(at: targetFD, name: staging, includeTree: false)
        defer { try? erase(at: targetFD, name: staging, expected: staged, temporaryCopy: true) }
        let stagingFD = openat(targetFD, staging, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stagingFD >= 0 else { throw RecoveryFailure.system("open copy staging directory", errno) }
        defer { close(stagingFD) }
        var opened = stat()
        guard fstat(stagingFD, &opened) == 0, RecoverySnapshot(opened).sameObject(as: staged) else {
            throw RecoveryFailure.changed
        }
        try copyNode(from: sourceFD, name: name, to: stagingFD, target: "copy")
        guard try snapshot(at: sourceFD, name: name, includeTree: true, trackChanges: true, allowLink: false) == before else {
            throw RecoveryFailure.recoveryCopyChanged
        }
        do {
            try move(from: stagingFD, name: "copy", to: targetFD, target: target)
        } catch RecoveryFailure.conflict {
            throw RecoveryFailure.copyDestinationExists
        }
    }

    private static func copyNode(from sourceFD: Int32, name: String, to targetFD: Int32, target: String) throws {
        if Task.isCancelled { throw CancellationError() }
        let before = try snapshot(at: sourceFD, name: name, includeTree: false, trackChanges: true, allowLink: false)
        let source = openat(sourceFD, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | (before.isDirectory ? O_DIRECTORY : 0))
        guard source >= 0 else { throw RecoveryFailure.system("open recovery copy", errno) }
        defer { close(source) }
        var opened = stat()
        guard fstat(source, &opened) == 0, RecoverySnapshot(opened, trackChanges: true) == before else {
            throw RecoveryFailure.recoveryCopyChanged
        }
        let destination: Int32
        if before.isDirectory {
            guard mkdirat(targetFD, target, 0o700) == 0 else { throw RecoveryFailure.system("create copy folder", errno) }
            destination = openat(targetFD, target, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        } else {
            destination = openat(targetFD, target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard destination >= 0 else { throw RecoveryFailure.system("create recovery copy", errno) }
        defer { close(destination) }
        if before.isDirectory {
            for child in try names(in: source) {
                try copyNode(from: source, name: child, to: destination, target: child)
            }
        }
        let flags = copyfile_flags_t(before.isDirectory ? COPYFILE_METADATA : COPYFILE_ALL)
        guard fcopyfile(source, destination, nil, flags) == 0 else {
            throw RecoveryFailure.system("copy recovery item", errno)
        }
        guard fstat(source, &opened) == 0, RecoverySnapshot(opened, trackChanges: true) == before else {
            throw RecoveryFailure.recoveryCopyChanged
        }
    }

    static func read(at fd: Int32, name: String) throws -> Data {
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw RecoveryFailure.system("read record", errno) }
        defer { close(file) }
        var value = stat()
        guard fstat(file, &value) == 0, value.st_uid == getuid(),
              value.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG), value.st_size <= 1_048_576 else {
            throw RecoveryFailure.invalidRecord
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw RecoveryFailure.system("read record", errno)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    static func write(_ data: Data, at fd: Int32, name: String) throws {
        let temporary = "." + UUID().uuidString + ".tmp"
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw RecoveryFailure.system("write record", errno) }
        defer { close(file); unlinkat(fd, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw RecoveryFailure.system("write record", errno)
                }
                guard count > 0 else { throw RecoveryFailure.system("write record", EIO) }
                written += count
            }
        }
        guard fsync(file) == 0 else { throw RecoveryFailure.system("sync record", errno) }
        guard renameat(fd, temporary, fd, name) == 0 else { throw RecoveryFailure.system("save record", errno) }
        _ = fsync(fd)
    }

    /// Only called for a confirmed recovery object or a staging directory created for a new copy.
    static func erase(at parent: Int32, name: String, expected: RecoverySnapshot, temporaryCopy: Bool = false) throws {
        let current = try snapshot(at: parent, name: name, includeTree: false)
        guard current.sameObject(as: expected) else { throw RecoveryFailure.changed }
        if current.isDirectory {
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw RecoveryFailure.system("open recovery copy", errno) }
            defer { close(child) }
            var value = stat()
            guard fstat(child, &value) == 0, RecoverySnapshot(value).sameObject(as: current) else {
                throw RecoveryFailure.changed
            }
            if temporaryCopy { _ = fchmod(child, 0o700) }
            for entry in try names(in: child) {
                var metadata = stat()
                guard fstatat(child, entry, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw RecoveryFailure.system("read recovery copy", errno)
                }
                if metadata.st_mode & UInt16(S_IFMT) == UInt16(S_IFLNK) {
                    // Unlinking the link itself never traverses its destination.
                    guard unlinkat(child, entry, 0) == 0 else { throw RecoveryFailure.system("delete link", errno) }
                } else {
                    try erase(at: child, name: entry, expected: RecoverySnapshot(metadata), temporaryCopy: temporaryCopy)
                }
            }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw RecoveryFailure.system("delete recovery directory", errno) }
        } else {
            guard unlinkat(parent, name, 0) == 0 else { throw RecoveryFailure.system("delete recovery file", errno) }
        }
        _ = fsync(parent)
    }
}
