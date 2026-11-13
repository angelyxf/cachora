import SwiftUI

struct OrphanListView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedOrphans: Set<URL> = []
    @State private var isRemoving = false
    @State private var pendingRemoval: TrashSelection?
    @State private var removalErrorMessage: String?
    /// Orphan sizes computed off the main thread. Orphans are exactly the large
    /// leftovers (multi-GB Caches/Containers/Application Support), and their
    /// size is a recursive directory walk — calling it from `body` would re-walk
    /// every realized row on each selection toggle and beachball the UI. We walk
    /// once off-main per result set and rows read the cached value.
    @State private var sizeCache: [URL: Int64] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if appState.isSearchingOrphans {
                VStack(spacing: 16) {
                    ProgressView(LocalizedStringKey("Scanning for orphaned files..."))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 300)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.orphanedFiles.isEmpty {
                EmptyStateView("Review possible app leftovers", systemImage: "checkmark.circle",
                               description: "Check for cache and log files with an app identifier that no installed app claims.",
                               action: { appState.findOrphans() }, actionLabel: "Scan for Orphans", tint: Tint.accent)
            } else {
                List {
                    // No .staggered(): List is lazy, so a delayed-reveal would
                    // blank each row as it scrolls in. The removal transition
                    // below still gives the sweep-out on delete.
                    ForEach(Array(appState.orphanedFiles.enumerated()), id: \.element) { _, fileURL in
                        OrphanRowView(
                            fileURL: fileURL,
                            isSelected: orphanBinding(for: fileURL),
                            fileSize: sizeCache[fileURL],
                            onReveal: { revealInFinder(fileURL) },
                            onCopyPath: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(fileURL.path, forType: .string)
                            },
                            onIgnore: { ignoreOrphans([fileURL]) },
                            onTrash: {
                                pendingRemoval = TrashSelection(urls: [fileURL])
                            }
                        )
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .opacity,
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                )
                        )
                    }
                }
            }
        }
        .navigationTitle(orphanedFilesTitle)
        .task(id: appState.orphanedFiles) {
            // Recompute off the main thread whenever the orphan set changes
            // (new scan, removals). FileSizeCalculator is a plain static helper
            // with no main-actor isolation, so it runs safely on a detached
            // background task; the result is applied back on the main actor.
            let urls = appState.orphanedFiles
            let sizes = await Task.detached(priority: .utility) { () -> [URL: Int64] in
                var out: [URL: Int64] = [:]
                for url in urls {
                    out[url] = FileSizeCalculator.size(of: url) ?? 0
                }
                return out
            }.value
            sizeCache = sizes
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Scan for Orphans") {
                    selectedOrphans.removeAll()
                    appState.findOrphans()
                }
                .disabled(isRemoving || appState.isSearchingOrphans || appState.isLoadingApps)

                if !selectedOrphans.isEmpty {
                    Button(ignoreSelectedLabel) {
                        ignoreOrphans(Array(selectedOrphans))
                    }
                    .disabled(isRemoving)

                    Button(removeSelectedLabel, role: .destructive) {
                        pendingRemoval = TrashSelection(urls: selectedOrphans)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isRemoving)
                }
            }
        }
        .sheet(item: $pendingRemoval) { selection in
            TrashReviewSheet(title: "Remove selected leftovers?", selection: selection,
                             isFixture: appState.cleanupEnvironment.isFixture,
                             details: "App matching is an estimate. Review the files before moving them.") { batch in
                Task { await removeSelectedOrphans(batch) }
            }
        }
        .alert("Some files could not be removed", isPresented: Binding(
            get: { removalErrorMessage != nil },
            set: { if !$0 { removalErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalErrorMessage ?? "")
        }
    }

    private var orphanedFilesTitle: String {
        String(format: String(localized: "Orphaned Files (%lld)"), Int64(appState.orphanedFiles.count))
    }

    private var removeSelectedLabel: String {
        String(format: String(localized: "Remove Selected (%lld)"), Int64(selectedOrphans.count))
    }

    private var ignoreSelectedLabel: String {
        String(format: String(localized: "Ignore Selected (%lld)"), Int64(selectedOrphans.count))
    }

    /// Persist the given URLs to the ignore list (so future scans skip them)
    /// and drop them from the local selection.
    private func ignoreOrphans(_ urls: [URL]) {
        appState.ignoreOrphans(urls)
        selectedOrphans.subtract(urls)
    }

    private func orphanBinding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { selectedOrphans.contains(url) },
            set: { selected in
                if selected {
                    selectedOrphans.insert(url)
                } else {
                    selectedOrphans.remove(url)
                }
            }
        )
    }

    private func removeSelectedOrphans(_ batch: Set<URL>) async {
        guard !isRemoving else { return }
        isRemoving = true
        defer { isRemoving = false }

        let urlsToRemove = batch.intersection(appState.orphanedFiles)
        let sampleHome = appState.cleanupEnvironment.sampleHome
        let sampleTrash = appState.cleanupEnvironment.sampleTrash
        var failedPaths: [String] = []
        var removedURLs: Set<URL> = []

        for url in urlsToRemove {
            guard OrphanSafetyPolicy.isSafeCandidate(url, sampleHome: sampleHome) else {
                failedPaths.append("\(url.path) (\(String(localized: "blocked by safety policy")))")
                continue
            }

            let outcome = await Task.detached(priority: .userInitiated) {
                Self.removeOrphan(url, sampleHome: sampleHome, sampleTrash: sampleTrash)
            }.value
            switch outcome {
            case .removed:
                removedURLs.insert(url)
            case .failed:
                failedPaths.append(url.path)
            }
        }

        // Sweep removed rows out (per-row transitions are attached in the
        // List above); plain assignment under Reduce Motion.
        if reduceMotion {
            appState.orphanedFiles.removeAll { removedURLs.contains($0) }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                appState.orphanedFiles.removeAll { removedURLs.contains($0) }
            }
        }
        selectedOrphans.subtract(removedURLs)

        if !failedPaths.isEmpty {
            let preview = failedPaths.prefix(3).joined(separator: "\n")
            let suffix = failedPaths.count > 3 ? "\n…" : ""
            removalErrorMessage = String(
                format: String(localized: "%lld item(s) failed to delete.\n\n%@"),
                Int64(failedPaths.count),
                preview + suffix
            )
        }
    }

    private enum OrphanRemoveOutcome: Sendable {
        case removed
        case failed
    }

    private nonisolated static func removeOrphan(_ url: URL, sampleHome: URL?,
                                                sampleTrash: (@Sendable (URL) throws -> Void)?) -> OrphanRemoveOutcome {
        guard OrphanSafetyPolicy.isSafeCandidate(url, sampleHome: sampleHome) else { return .failed }
        do {
            if let sampleTrash {
                try sampleTrash(url)
            } else {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            return .removed
        } catch {
            // A failed Trash move leaves the item in place in every release channel.
            return .failed
        }
    }

    private func revealInFinder(_ url: URL) {
        // activateFileViewerSelecting handles sandbox-bookmarked paths and
        // missing files better than selectFile(_:inFileViewerRootedAtPath:),
        // which silently no-ops when the path is unreachable from Finder's
        // current scope. If the target itself was removed since the scan,
        // fall back to opening the enclosing directory so the user lands
        // somewhere useful instead of nothing happening.
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let parent = url.deletingLastPathComponent()
        if fm.fileExists(atPath: parent.path) {
            NSWorkspace.shared.open(parent)
        }
    }


}

// MARK: - Row

/// Orphan row extracted to its own struct so hover highlight and the springy
/// checkbox are per-row state.
private struct OrphanRowView: View {
    let fileURL: URL
    @Binding var isSelected: Bool
    let fileSize: Int64?
    let onReveal: () -> Void
    let onCopyPath: () -> Void
    let onIgnore: () -> Void
    let onTrash: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Toggle(isOn: $isSelected) {
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                    .resizable()
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(fileURL.lastPathComponent)
                        .lineLimit(1)
                    Text(fileURL.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                // Hover-revealed Finder shortcut; stays in the layout so the
                // trailing size never shifts sideways.
                Button {
                    onReveal()
                } label: {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
                .opacity(hovering ? 1 : 0)
                .scaleEffect(reduceMotion ? 1 : (hovering ? 1 : 0.8))
                .allowsHitTesting(hovering)

                if let size = fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(AnimatedCheckboxStyle(tint: Tint.pink))
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Reveal in Finder") { onReveal() }
            Button("Copy Path") { onCopyPath() }
            Divider()
            Button("Always Ignore") { onIgnore() }
            Button("Move to Trash", role: .destructive) { onTrash() }
        }
    }
}
