import Foundation

enum CleanupExclusions {
    static let defaultsKey = "settings.cleaning.excludedPaths"

    static func paths(in defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: defaultsKey) ?? []
    }

    static func add(_ path: String, in defaults: UserDefaults = .standard) {
        guard path.hasPrefix("/"), !path.contains("\0") else { return }
        var values = Set(paths(in: defaults))
        values.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
        defaults.set(values.sorted(), forKey: defaultsKey)
    }

    static func excludes(_ path: String, paths: [String]) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let candidates = [candidate.path, resolvedPath(candidate)]
        return paths.contains { excluded in
            guard excluded.hasPrefix("/") else { return false }
            let url = URL(fileURLWithPath: excluded).standardizedFileURL
            return [url.path, resolvedPath(url)].contains { root in
                candidates.contains { candidate in
                    root == "/" || candidate == root || candidate.hasPrefix(root + "/")
                        || root.hasPrefix(candidate + "/")
                }
            }
        }
    }

    static func isGeneratedTestRoot(_ path: String) -> Bool {
        if path.hasSuffix("/build-local/test-workspaces") || path.hasSuffix("/build-local/.retired-test-artifacts") {
            return true
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent == "/private/tmp" || parent == "/tmp" else { return false }
        let name = (path as NSString).lastPathComponent
        for prefix in ["cachora-fixture-", "cachora-ui-"] where name.hasPrefix(prefix) {
            let suffix = name.dropFirst(prefix.count)
            return suffix.count == 8 && suffix.utf8.allSatisfy {
                (97...122).contains($0) || (48...57).contains($0) || $0 == 95
            }
        }
        return false
    }

    private static func resolvedPath(_ url: URL) -> String {
        var ancestor = url
        var suffix: [String] = []
        while ancestor.path != "/", !FileManager.default.fileExists(atPath: ancestor.path) {
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        return suffix.reversed().reduce(ancestor.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1)
        }.standardizedFileURL.path
    }
}
