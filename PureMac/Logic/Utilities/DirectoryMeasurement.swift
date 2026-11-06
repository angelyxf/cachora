import Foundation

struct DirectoryMeasurement {
    var bytes: Int64 = 0
    var issues: [ScanIssue] = []
    var wasCancelled = false

    /// Counts hidden entries too: deleting a directory also deletes its dotfiles.
    /// Symbolic links are never followed. Unreadable entries remain explicit.
    static func measure(
        path: String,
        fileManager: FileManager = .default,
        isCancelled: @escaping () -> Bool = { Task.isCancelled },
        onPath: (String) -> Void = { _ in }
    ) -> DirectoryMeasurement {
        var result = DirectoryMeasurement()
        var seenIssues: Set<String> = []
        func record(_ url: URL, _ error: Error) {
            let issue = ScanIssue(path: url.path, error: error)
            if seenIssues.insert(issue.id).inserted { result.issues.append(issue) }
        }

        let root = URL(fileURLWithPath: path, isDirectory: true)
        do {
            let attributes = try fileManager.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                result.issues.append(ScanIssue(
                    path: path, kind: .readFailure,
                    detail: String(localized: "This location is not a regular directory; symbolic links are not followed.")
                ))
                return result
            }
        } catch {
            // An optional application/cache that is not installed is not a scan failure.
            if !ScanIssue.isMissingFile(error) { record(root, error) }
            return result
        }

        if isCancelled() {
            result.wasCancelled = true
            return result
        }
        guard fileManager.isReadableFile(atPath: path) else {
            record(root, CocoaError(.fileReadNoPermission))
            return result
        }

        let keys: [URLResourceKey] = [
            .totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, error in
                record(url, error)
                return !isCancelled()
            }
        ) else {
            record(root, CocoaError(.fileReadUnknown))
            return result
        }

        for case let file as URL in enumerator {
            if isCancelled() {
                result.wasCancelled = true
                break
            }
            onPath(file.path)
            do {
                let values = try file.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isRegularFile == true else { continue }
                if let bytes = values.totalFileAllocatedSize ?? values.fileSize {
                    result.bytes += Int64(bytes)
                }
            } catch {
                record(file, error)
            }
        }
        if isCancelled() { result.wasCancelled = true }
        return result
    }
}
