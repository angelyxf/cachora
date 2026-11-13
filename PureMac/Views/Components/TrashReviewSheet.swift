import SwiftUI

struct TrashSelection: Identifiable {
    let id = UUID()
    let urls: Set<URL>
}

struct TrashReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    let selection: TrashSelection
    let isFixture: Bool
    var details: LocalizedStringKey?
    var retainedURLs: [URL] = []
    let confirm: (Set<URL>) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.weight(.semibold))
            Text(isFixture
                 ? "Selected items move to a Trash folder inside the test workspace."
                 : "Review the paths before moving the selected items to the Trash.")
                .foregroundStyle(.secondary)
            if let details { Text(details).font(.callout).foregroundStyle(.secondary) }
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
                    dismiss()
                    confirm(selection.urls)
                }
                .buttonStyle(.borderedProminent)
                .tint(Tint.red)
                .disabled(selection.urls.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 600)
    }

    private func pathRows(_ urls: [URL]) -> some View {
        ForEach(urls, id: \.self) { url in
            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent).font(.callout.weight(.semibold))
                Text(url.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)
        }
    }
}
