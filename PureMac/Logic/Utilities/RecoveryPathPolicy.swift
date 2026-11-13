import Foundation

/// Applied both before a move and when loading an untrusted recovery record.
/// A container's Documents or an AI model cannot masquerade as a cache.
enum RecoveryPathPolicy {
    private static let systemLogRoots = ["/private/var/log", "/var/log"]

    static func systemJunkRoots(home: String) -> [String] {
        ["/Library/Caches", "/Library/Logs", home + "/Library/Logs",
         "/private/tmp", "/private/var/tmp"].map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    static func isSystemLogPath(_ path: String) -> Bool {
        let normalized = (path as NSString).standardizingPath
        return systemLogRoots.contains { normalized == $0 || RecoveryFileSystem.inside(normalized, $0) }
    }

    static func accepts(_ item: CleanableItem, home: URL) -> Bool {
        guard !item.isActionItem, !isSystemLogPath(item.path), let snapshot = item.recoverySnapshot else { return false }
        return accepts(path: item.path, category: item.category.rawValue, snapshot: snapshot, home: home)
    }

    static func accepts(path: String, category: String, snapshot: RecoverySnapshot, home: URL) -> Bool {
        let base = home.path
        guard path == (path as NSString).standardizingPath,
              !ProviderPaths.isProviderOwned(path, homeDirectory: home) else { return false }
        func within(_ roots: [String], whole: Bool = false) -> Bool {
            roots.contains { (whole && path == $0) || RecoveryFileSystem.inside(path, $0) }
        }
        switch category {
        case "AI Apps":
            return [".ollama/logs", ".ollama/history", ".lmstudio/server-logs", ".lmstudio/conversations",
                    "Library/Caches/ollama", "Library/Caches/com.electron.ollama", "Library/WebKit/com.electron.ollama",
                    "Library/Saved Application State/com.electron.ollama.savedState"].map { base + "/" + $0 }.contains(path)
        case "Large & Old Files":
            return snapshot.isRegularFile && within([base + "/Downloads", base + "/Documents", base + "/Desktop"])
        case "User Cache":
            if within([base + "/Library/Caches", base + "/Library/HTTPStorages"]) { return true }
            if within([base + "/.cache/pip"], whole: true) { return true }
            for (prefix, suffix) in [(base + "/Library/Containers/", "/Data/Library/Caches"),
                                     (base + "/Library/Group Containers/", "/Library/Caches")] {
                if path.hasPrefix(prefix) {
                    let remainder = String(path.dropFirst(prefix.count))
                    guard let slash = remainder.firstIndex(of: "/") else { continue }
                    let cache = prefix + String(remainder[..<slash]) + suffix
                    if within([String(cache)], whole: true) { return true }
                }
            }
            return false
        case "System Junk":
            // Older recovery records may still refer to system logs.
            return within(systemJunkRoots(home: base)) || within(systemLogRoots)
        case "Trash Bins": return within([base + "/.Trash"])
        case "Mail Files":
            return within([base + "/Library/Mail Downloads", base + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"])
        case "Xcode Junk":
            return within(["Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/Archives",
                "Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/Xcode/watchOS DeviceSupport",
                "Library/Developer/Xcode/tvOS DeviceSupport", "Library/Developer/Xcode/UserData/Previews",
                "Library/Developer/CoreSimulator/Caches", "Library/Developer/XCTestDevices",
                "Library/Caches/com.apple.dt.Xcode", "Library/Caches/org.swift.swiftpm",
                "Library/org.swift.swiftpm"].map { base + "/" + $0 }, whole: true)
        case "Node Cache":
            return within([".npm", ".pnpm-store", ".cache/yarn", ".cache/pnpm", ".local/share/pnpm/store", "Library/pnpm/store"].map { base + "/" + $0 }, whole: true)
        case "Brew Cache": return within([base + "/Library/Caches/Homebrew"], whole: true)
        case "Docker Cache":
            return within([".docker/cli-plugins/.cache", ".docker/buildx/cache", ".orbstack/log"].map { base + "/" + $0 }, whole: true)
        default: return false
        }
    }
}
