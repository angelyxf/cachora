import CryptoKit
import Darwin
import Foundation

enum RecoveryFailure: LocalizedError {
    case unsafePath, changed, unverified, conflict, missing, busy, invalidRecord, unsupported, cancelled
    case system(String, Int32)

    var errorDescription: String? {
        switch self {
        case .unsafePath: return String(localized: "Recovery refused an unsafe path or symbolic link.")
        case .changed: return String(localized: "The file changed after review. Scan again before cleaning.")
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

    init(_ value: stat, treeDigest: String? = nil) {
        device = value.st_dev
        inode = value.st_ino
        mode = value.st_mode
        size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        self.treeDigest = treeDigest
    }

    static func capture(_ path: String) -> RecoverySnapshot? {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              let parent = try? RecoveryFileSystem.directory((path as NSString).deletingLastPathComponent) else { return nil }
        defer { close(parent) }
        return try? RecoveryFileSystem.snapshot(at: parent, name: (path as NSString).lastPathComponent)
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
    static func normalized(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw RecoveryFailure.unsafePath
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func canonicalExisting(_ path: String) throws -> String {
        guard let buffer = realpath(path, nil) else { throw RecoveryFailure.system("realpath", errno) }
        defer { free(buffer) }
        return String(cString: buffer)
    }

    static func inside(_ path: String, _ root: String) -> Bool {
        path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func directory(_ path: String, create: Bool = false) throws -> Int32 {
        let path = try normalized(path)
        var walkPath = path
        // Foundation commonly returns /var for the system-managed /private/var
        // alias. Accept only these verified OS aliases, never user-made links.
        for (alias, target) in [("/var", "/private/var"), ("/tmp", "/private/tmp")] {
            if path == alias || inside(path, alias) {
                guard try canonicalExisting(alias) == target else { throw RecoveryFailure.unsafePath }
                walkPath = target + path.dropFirst(alias.count)
                break
            }
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw RecoveryFailure.system("open", errno) }
        do {
            for component in walkPath.split(separator: "/").map(String.init) {
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
        var value = stat()
        guard fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { throw RecoveryFailure.missing }
            throw RecoveryFailure.system("read metadata", errno)
        }
        let snapshot = RecoverySnapshot(value)
        guard snapshot.isDirectory || snapshot.isRegularFile else { throw RecoveryFailure.unsafePath }
        if snapshot.isDirectory && includeTree {
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw RecoveryFailure.system("verify directory", errno) }
            defer { close(child) }
            var opened = stat()
            guard fstat(child, &opened) == 0, RecoverySnapshot(opened) == snapshot else { throw RecoveryFailure.changed }
            var digest = SHA256()
            for entry in try names(in: child) {
                if Task.isCancelled { throw RecoveryFailure.cancelled }
                let item = try self.snapshot(at: child, name: entry)
                let metadata = "\(entry.utf8.count):\(entry):\(item.device):\(item.inode):\(item.mode):\(item.size):\(item.modifiedSeconds):\(item.modifiedNanoseconds):\(item.treeDigest ?? "")"
                digest.update(data: Data(metadata.utf8))
            }
            var after = stat()
            guard fstat(child, &after) == 0, RecoverySnapshot(after) == snapshot else { throw RecoveryFailure.changed }
            return RecoverySnapshot(value, treeDigest: digest.finalize().map { String(format: "%02x", $0) }.joined())
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

    /// Only called for an explicitly confirmed object inside the private recovery store.
    static func erase(at parent: Int32, name: String, expected: RecoverySnapshot) throws {
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
            for entry in try names(in: child) {
                var metadata = stat()
                guard fstatat(child, entry, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw RecoveryFailure.system("read recovery copy", errno)
                }
                if metadata.st_mode & UInt16(S_IFMT) == UInt16(S_IFLNK) {
                    // Unlinking the link itself never traverses its destination.
                    guard unlinkat(child, entry, 0) == 0 else { throw RecoveryFailure.system("delete link", errno) }
                } else {
                    try erase(at: child, name: entry, expected: RecoverySnapshot(metadata))
                }
            }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw RecoveryFailure.system("delete recovery directory", errno) }
        } else {
            guard unlinkat(parent, name, 0) == 0 else { throw RecoveryFailure.system("delete recovery file", errno) }
        }
        _ = fsync(parent)
    }
}
