import AppKit
import SwiftUI

struct AppUpdateSettingsView: View {
    @ObservedObject private var updater = UpdateService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cachora Updates")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Checks this project's releases on GitHub when requested.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if updater.isChecking { ProgressView().controlSize(.small) }
                Button("Check for Cachora Updates") { updater.checkForUpdates() }
                    .disabled(updater.isChecking)
                    .accessibilityIdentifier("settings.checkForUpdates")
            }

            status

            if let checked = updater.lastChecked {
                Text(String(format: String(localized: "Last checked: %@"), checked.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Text("Download an update from this project's release page, quit the app, then replace it in Applications.")
                .font(.caption).foregroundStyle(.secondary)
            if let url = UpdateService.releasesURL {
                Link("View releases", destination: url)
            } else {
                Text("Updates are not configured for this build yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var status: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .checking:
            Label("Checking for updates…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .available(let release):
            VStack(alignment: .leading, spacing: 8) {
                Label(String(format: String(localized: "Version %@ is available"), release.tagName), systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(Tint.accent)
                Link("Open release page", destination: release.htmlURL)
            }
        case .upToDate:
            Label("You're using the latest available version for this channel.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Tint.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Couldn't check for updates", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Tint.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
