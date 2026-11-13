import Foundation

enum OrphanSafetyPolicy {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    // Conservative allowlist: only volatile data directories.
    static let allowedRoots: [String] = [
        "\(home)/Library/Caches",
        "\(home)/Library/Logs",
        "\(home)/Library/Saved Application State",
        "\(home)/Library/HTTPStorages",
        "\(home)/Library/WebKit",
        "\(home)/Library/Application Support/CrashReporter",
        "/Library/Caches",
        "/Library/Logs",
    ]

    private static let blockedFragments: [String] = [
        "/Library/Preferences",
        "/Library/PreferencePanes",
        "/Library/Containers",
        "/Library/Group Containers",
        "/Library/Application Scripts",
        "/Library/LaunchAgents",
        "/Library/LaunchDaemons",
        "/Library/PrivilegedHelperTools",
        "/Library/Keychains",
        "/Library/Mail",
        "/Library/Safari",
        "/Library/Messages",
        "/Library/Calendars",
        "/Library/Accounts",
        "/Library/Mobile Documents",
        "/Library/CloudStorage",
    ]

    static func sampleRoots(home: URL) -> [String] {
        ["Library/Caches", "Library/Logs"].map { home.appendingPathComponent($0).path }
    }

    static func candidateBundleIdentifier(for url: URL) -> String? {
        let artifactSuffixes: Set<String> = ["log", "savedstate", "cache", "plist"]
        let identifier = artifactSuffixes.contains(url.pathExtension.lowercased())
            ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        let labels = identifier.split(separator: ".", omittingEmptySubsequences: false)
        let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let identifierCharacters = letters.union(CharacterSet(charactersIn: "0123456789-"))
        guard labels.count >= 3,
              labels[0].count >= 2,
              labels[0].unicodeScalars.allSatisfy(letters.contains),
              labels.allSatisfy({ label in
                  !label.isEmpty && label.unicodeScalars.allSatisfy(identifierCharacters.contains)
              }) else { return nil }
        return identifier
    }

    static func isSafeCandidate(_ url: URL, sampleHome: URL? = nil) -> Bool {
        let path = normalizedPath(url)
        let lowerPath = path.lowercased()

        // Belt-and-suspenders: reject any high-risk home dotpath (defined in
        // Conditions.swift). The allowedRoots filter below would catch most
        // of these, but this early block keeps the rule obvious.
        for root in highRiskHomeDotPaths {
            if path == root || path.hasPrefix(root + "/") {
                return false
            }
        }

        // Require the match to land STRICTLY inside the allowed root, not at a
        // sibling like /tmpfoo. Trailing "/" prevents hasPrefix from matching
        // sibling directories whose names merely start with the root name.
        let roots = sampleHome.map { sampleRoots(home: $0) } ?? allowedRoots
        guard roots.contains(where: { root in
            let rootPath = sampleHome == nil ? root : normalizedPath(URL(fileURLWithPath: root))
            let rootWithSlash = rootPath.lowercased() + "/"
            return lowerPath.hasPrefix(rootWithSlash)
        }) else {
            return false
        }
        if sampleHome != nil && RecoverySnapshot.capture(url.path) == nil { return false }

        if blockedFragments.contains(where: { lowerPath.contains($0.lowercased()) }) {
            return false
        }

        let name = url.lastPathComponent.lowercased()
        if name.hasPrefix("com.apple.") || name == ".globalpreferences.plist" {
            return false
        }

        return true
    }

    private static func normalizedPath(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        return standardized.resolvingSymlinksInPath().path
    }
}
