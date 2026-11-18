import SwiftUI

struct TrashSelection: Identifiable, Sendable {
    let id = UUID()
    let urls: Set<URL>
    private(set) var snapshots: [URL: RecoverySnapshot] = [:]

    init(urls: Set<URL>) { self.urls = urls }

    func reviewed() async -> Self {
        let worker = Task.detached(priority: .userInitiated) {
            var review = self
            for url in urls {
                if Task.isCancelled { break }
                review.snapshots[url] = RecoveryFileSystem.trashReviewSnapshot(url)
            }
            return review
        }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }

    func subset(_ urls: Set<URL>) -> Self {
        var selection = Self(urls: self.urls.intersection(urls))
        selection.snapshots = snapshots.filter { selection.urls.contains($0.key) }
        return selection
    }

    func requireUnchanged(_ url: URL) throws {
        guard let snapshot = snapshots[url], RecoveryFileSystem.trashReviewSnapshot(url) == snapshot else {
            throw RecoveryFailure.changed
        }
    }

    func changedURLs() -> [URL] {
        urls.sorted { $0.path < $1.path }.filter { (try? requireUnchanged($0)) == nil }
    }

    static func changedMessage(_ urls: [URL]) -> String {
        let paths = urls.prefix(4).map(\.path).joined(separator: "\n")
        let message = String(localized: "Some files changed or could not be verified. Review the current files and confirm again.")
        return message + "\n\n" + paths + (urls.count > 4 ? "\n…" : "")
    }
}

struct TrashReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    let selection: TrashSelection
    let isFixture: Bool
    var details: LocalizedStringKey?
    var retainedURLs: [URL] = []
    var verifyFiles = false
    let confirm: (TrashSelection) -> Void
    @State private var reviewedSelection: TrashSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.weight(.semibold))
            Text(isFixture
                 ? "Selected items move to a Trash folder inside the test workspace."
                 : "Review the paths before moving the selected items to the Trash.")
                .foregroundStyle(.secondary)
            if let details { Text(details).font(.callout).foregroundStyle(.secondary) }
            if verifyFiles {
                if let reviewedSelection {
                    if reviewedSelection.snapshots.count != selection.urls.count {
                        Label("Some files could not be verified. Cancel and review the selection again.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout)
                    }
                } else {
                    ProgressView("Checking selected files…").controlSize(.small)
                }
            }
            List {
                let moving = selection.urls.sorted { $0.path < $1.path }
                if retainedURLs.isEmpty {
                    pathRows(moving)
                } else {
                    Section("Copies to move") {
                        pathRows(moving)
                    }
                    Section("Copies to keep") {
                        pathRows(retainedURLs)
                    }
                }
            }
            .frame(minHeight: retainedURLs.isEmpty ? 140 : 300, maxHeight: retainedURLs.isEmpty ? 260 : 320)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash") {
                    guard let confirmed = verifyFiles ? reviewedSelection : selection else { return }
                    dismiss()
                    confirm(confirmed)
                }
                .buttonStyle(.borderedProminent)
                .tint(Tint.red)
                .disabled(selection.urls.isEmpty || (verifyFiles && reviewedSelection?.snapshots.count != selection.urls.count))
            }
        }
        .padding(24)
        .frame(width: 600)
        .task(id: selection.id) {
            guard verifyFiles else { return }
            let review = await selection.reviewed()
            if !Task.isCancelled { reviewedSelection = review }
        }
    }

    private func pathRows(_ urls: [URL]) -> some View {
        ForEach(urls, id: \.self) { url in
            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent).font(.callout.weight(.semibold))
                Text(url.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if verifyFiles, let reviewedSelection, reviewedSelection.snapshots[url] == nil {
                    Text("Could not verify this file").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
