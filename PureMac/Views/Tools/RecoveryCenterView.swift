import SwiftUI

struct RecoveryCenterView: View {
    @ObservedObject var model: RecoveryCenterModel
    var showCloseButton = true
    @Environment(\.dismiss) private var dismiss
    @State private var pendingPurge: RecoveryEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Recovery", systemImage: "clock.arrow.circlepath")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }.disabled(model.busy)
                if showCloseButton { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy) }
            }
            Text("Cleanup moves files here first. Retained copies still use disk space. Permanent deletion cannot be undone.")
                .font(.callout).foregroundStyle(.secondary)
            Text("\(ByteCountFormatter.string(fromByteCount: model.retainedBytes, countStyle: .file)) retained")
                .font(.headline).monospacedDigit()
            if model.busy { ProgressView().controlSize(.small) }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
            }
            if let message = model.message {
                Label(message, systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
            if !model.warnings.isEmpty {
                DisclosureGroup("Recovery records need review") {
                    ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning).font(.caption).textSelection(.enabled)
                    }
                }
            }
            if model.entries.isEmpty {
                Spacer()
                Text("No recovery records yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(model.entries) { entry in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.name).font(.headline)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)).monospacedDigit()
                        }
                        Text(entry.originalPath).font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                        HStack(spacing: 12) {
                            Text(status(entry.state)).font(.caption).foregroundStyle(.secondary)
                            Text(entry.created, style: .date).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Restore") { Task { await model.restore(entry.id) } }
                                .buttonStyle(.bordered)
                                .disabled(!entry.canRestore || model.busy)
                                .accessibilityLabel(String(localized: "Restore") + " " + entry.name)
                            Button("Permanently delete…", role: .destructive) { pendingPurge = entry }
                                .buttonStyle(.bordered)
                                .disabled(!entry.canPurge || model.busy)
                                .accessibilityLabel(String(localized: "Permanently delete…") + " " + entry.name)
                        }
                        if let note = entry.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("recovery.entry." + entry.id.uuidString)
                }.listStyle(.inset)
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 480)
        .task { await model.refresh() }
        .interactiveDismissDisabled(model.busy)
        .confirmationDialog("Permanently delete this recovery copy?", isPresented: Binding(
            get: { pendingPurge != nil }, set: { if !$0 { pendingPurge = nil } }
        ), titleVisibility: .visible) {
            if let entry = pendingPurge {
                Button("Permanently delete", role: .destructive) {
                    pendingPurge = nil
                    Task { await model.purge(entry.id, confirmed: true) }
                }
            }
            Button("Cancel", role: .cancel) { pendingPurge = nil }
        } message: {
            Text("The retained copy will be deleted permanently. It cannot be restored afterward.")
        }
    }

    private func status(_ state: RecoveryEntry.State) -> String {
        switch state {
        case .stored: return String(localized: "Ready to restore")
        case .restored: return String(localized: "Restored")
        case .purged: return String(localized: "Permanently deleted")
        case .purgeFailed: return String(localized: "Deletion incomplete; review required")
        case .missing: return String(localized: "Recovery copy unavailable")
        case .failed: return String(localized: "No file moved")
        default: return String(localized: "Checking interrupted operation")
        }
    }
}

/// Uses the same review, cleanup engine and recovery view as the normal app,
/// while exposing no tools that could reach real documents or system data.
struct RecoveryFixtureView: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Test mode — disposable files only", systemImage: "testtube.2")
                .font(.headline).padding(.horizontal, 24).padding(.top, 18)
            Text(appState.cleanupEnvironment.home.deletingLastPathComponent().path)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.horizontal, 24)
            TabView {
                CategoryDetailView(category: .userCache).tabItem { Label("Test files", systemImage: "folder") }
                RecoveryCenterView(model: appState.recoveryCenter, showCloseButton: false)
                    .tabItem { Label("Recovery", systemImage: "clock.arrow.circlepath") }
            }
        }.frame(minWidth: 960, minHeight: 640)
        .alert("Cleanup needs review", isPresented: Binding(
            get: { appState.cleanError != nil }, set: { if !$0 { appState.cleanError = nil } }
        )) {
            Button("OK") { appState.cleanError = nil }
        } message: { Text(appState.cleanError ?? "") }
    }
}
