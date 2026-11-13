import SwiftUI

enum AppUpdateIdentityMatcher {
    static func baseToken(_ token: String) -> String {
        let cask = token.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? token
        return cask.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? cask
    }

    static func normalizedKey(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }

    static func matchingIndex(for token: String, appNames: [String]) -> Int? {
        let key = normalizedKey(baseToken(token))
        guard !key.isEmpty else { return nil }
        let matches = appNames.indices.filter { normalizedKey(appNames[$0]) == key }
        return matches.count == 1 ? matches[0] : nil
    }

    static func fallbackDisplayName(for token: String) -> String {
        let words = baseToken(token)
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? token : words.joined(separator: " ")
    }

    static func shouldShowTokenDetail(_ token: String) -> Bool {
        token.contains("@") || token.contains("/")
    }
}

@MainActor
struct AppUpdatesView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var updater: ApplicationUpdater
    @State private var showingUpgradeConfirmation = false
    @State private var confirmationSelection: [ManagedAppUpdate] = []
    private let permitsPackageOperations: Bool

    init() {
        self.init(updater: ApplicationUpdater())
    }

    init(updater: ApplicationUpdater, permitsPackageOperations: Bool = true) {
        _updater = StateObject(wrappedValue: updater)
        self.permitsPackageOperations = permitsPackageOperations
    }

    private var canCheckHomebrew: Bool { permitsPackageOperations && updater.isHomebrewAvailable }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if canCheckHomebrew {
                        sourceCard
                        homebrewResults
                    }
                    appStoreCard
                    sourceNote("For apps downloaded from a website, check for updates in the app or on the developer’s website.", systemImage: "globe")
                    if !canCheckHomebrew {
                        sourceNote(
                            updater.isHomebrewAvailable
                                ? "Open the regular app to check or upgrade Homebrew apps."
                                : "Homebrew is an optional tool for managing Mac software. Apps installed through Homebrew can be updated here.",
                            systemImage: "shippingbox"
                        )
                    }
                }
                .padding(24)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("App Updates")
        .toolbar {
            if canCheckHomebrew {
                ToolbarItem {
                    Button {
                        Task { await updater.checkForUpdates() }
                    } label: {
                        Label("Check Homebrew Apps", systemImage: "arrow.clockwise")
                    }
                    .disabled(updater.isBusy)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if canCheckHomebrew && updater.hasCurrentResults && !updater.updates.isEmpty {
                upgradeBar
            }
        }
        .alert("Upgrade selected apps?", isPresented: $showingUpgradeConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button(upgradeConfirmationLabel(count: confirmationSelection.count)) {
                let selection = confirmationSelection
                Task { await updater.upgrade(selection) }
            }
        } message: {
            Text(upgradeConfirmationMessage)
        }
        .onAppear {
            updater.refreshAvailability()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            IconTile(systemName: "arrow.down.app.fill", tint: Tint.accent, size: 48, corner: 13, vivid: true)
                .accessibilityHidden(true)
            Text("App Updates")
                .font(.system(size: 25, weight: .bold))
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var sourceCard: some View {
        CardSurface(padding: 16, elevation: .flat, tint: Tint.accent) {
            HStack(spacing: 12) {
                IconTile(systemName: "shippingbox.fill", tint: Tint.accent, size: 32, corner: 9)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Updates from Homebrew")
                        .font(.system(size: 14, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Review and update apps installed as Homebrew casks.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let date = updater.lastCheckedAt {
                        Text(String(format: String(localized: "Last checked: %@"), date.formatted(date: .abbreviated, time: .shortened)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Check Homebrew Apps") {
                    Task { await updater.checkForUpdates() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Tint.accent)
                .disabled(updater.isBusy)
                .help("Checking asks Homebrew to refresh its package data as needed and contacts Homebrew's configured sources. Cachora only lists cask apps managed by this Homebrew installation.")
            }
        }
    }

    @ViewBuilder
    private var homebrewResults: some View {
        switch updater.phase {
        case .checking:
            progressCard("Checking Homebrew casks")
        case .upgrading:
            progressCard("Updating…")
        case .verifying:
            progressCard("Verifying Homebrew updates…")
        case .checkFailed(let detail):
            statusCard(
                "Couldn't check for updates",
                message: String(localized: "Check Homebrew apps again to see which updates are still available."),
                systemImage: "exclamationmark.triangle.fill", tint: Tint.red, detail: detail
            )
        case .upgradeFailed(let detail):
            statusCard(
                "Update failed",
                message: String(localized: "Check Homebrew apps again to see which updates are still available."),
                systemImage: "exclamationmark.triangle.fill", tint: Tint.red, detail: detail
            )
        case .needsVerification(let detail):
            statusCard(
                "Update result unverified",
                message: String(localized: "Check Homebrew apps again to verify the installed versions."),
                systemImage: "questionmark.circle.fill", tint: Tint.orange, detail: detail
            )
        case .updatesRemaining(let count):
            statusCard(
                "Updates still available",
                message: count == 1
                    ? String(localized: "Homebrew finished, but 1 selected app still reports an update.")
                    : String(localized: "Homebrew finished, but \(count) selected apps still report updates."),
                systemImage: "exclamationmark.circle.fill", tint: Tint.orange
            )
        case .completed(let count):
            statusCard(
                "Update complete",
                message: count == 1
                    ? String(localized: "Homebrew updated the selected app.")
                    : String(localized: "Homebrew updated the \(count) selected apps."),
                systemImage: "checkmark.circle.fill", tint: Tint.green
            )
        case .ready where updater.updates.isEmpty:
            statusCard("No Homebrew app updates found", systemImage: "list.bullet", tint: .secondary)
        case .idle, .ready:
            EmptyView()
        }

        if !updater.isBusy && !updater.updates.isEmpty {
            updatesCard
        }
    }

    private var updatesCard: some View {
        CardSurface(padding: 0, elevation: .standard) {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(updater.hasCurrentResults ? updateCountTitle : String(localized: "Previous results"))
                            .font(.headline)
                        Text(updater.hasCurrentResults
                             ? String(localized: "Select the apps Homebrew should upgrade.")
                             : String(localized: "Check Homebrew apps again before updating."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)

                Divider()

                LazyVStack(spacing: 0) {
                    ForEach(Array(updater.updates.enumerated()), id: \.element.id) { index, update in
                        updateRow(update)
                        if index < updater.updates.count - 1 {
                            Divider()
                                .padding(.leading, 56)
                        }
                    }
                }
            }
        }
    }

    private func updateRow(_ update: ManagedAppUpdate) -> some View {
        let app = installedApp(for: update.token)
        let presentation = updater.caskPresentations[update.token]
        let displayName = app?.appName
            ?? presentation?.displayName
            ?? AppUpdateIdentityMatcher.fallbackDisplayName(for: update.token)

        return HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { updater.selectedTokens.contains(update.token) },
                set: { updater.setSelected($0, token: update.token) }
            ))
            .labelsHidden()
            .toggleStyle(AnimatedCheckboxStyle(tint: Tint.accent))
            .disabled(update.isPinned || !updater.hasCurrentResults)
            .accessibilityLabel("Select \(displayName)")

            appIcon(app?.icon ?? presentation?.icon, isPinned: update.isPinned)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if update.isPinned {
                        StatusChip(label: String(localized: "Pinned"), systemImage: "pin.fill", tint: Tint.orange)
                    }
                }
                Text(updateDetail(update))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if presentation?.isBundleMissing == true {
                    Text("App bundle missing")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Tint.orange)
                }
            }

            Spacer(minLength: 18)

            VStack(alignment: .trailing, spacing: 3) {
                Text("Available")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(update.currentVersion)
                    .font(.system(.callout, design: .monospaced, weight: .medium))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func appIcon(_ icon: NSImage?, isPinned: Bool) -> some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
        } else {
            IconTile(systemName: "app.fill", tint: isPinned ? Tint.orange : Tint.accent, size: 32, corner: 8)
        }
    }

    private func installedApp(for token: String) -> InstalledApp? {
        let names = appState.installedApps.map(\.appName)
        guard let index = AppUpdateIdentityMatcher.matchingIndex(for: token, appNames: names) else { return nil }
        return appState.installedApps[index]
    }

    private func displayName(for token: String) -> String {
        installedApp(for: token)?.appName
            ?? updater.caskPresentations[token]?.displayName
            ?? AppUpdateIdentityMatcher.fallbackDisplayName(for: token)
    }

    private func updateDetail(_ update: ManagedAppUpdate) -> String {
        let installed = String(localized: "Installed \(update.installedVersion)")
        guard AppUpdateIdentityMatcher.shouldShowTokenDetail(update.token) else { return installed }
        return String(localized: "\(update.token)  ·  \(installed)")
    }

    private var appStoreCard: some View {
        CardSurface(padding: 16, elevation: canCheckHomebrew ? .flat : .standard) {
            HStack(spacing: 12) {
                IconTile(systemName: "storefront.fill", tint: Tint.blue, size: 32, corner: 9)
                    .accessibilityHidden(true)
                Text(verbatim: "App Store")
                    .font(.headline)
                Spacer()
                if canCheckHomebrew {
                    appStoreButton.buttonStyle(.bordered)
                } else {
                    appStoreButton.buttonStyle(.borderedProminent).tint(Tint.accent)
                }
            }
        }
    }

    private var appStoreButton: some View {
        Button("Open App Store Updates") {
            updater.openAppStoreUpdates()
        }
    }

    private func sourceNote(_ text: LocalizedStringKey, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private func progressCard(_ title: LocalizedStringKey) -> some View {
        CardSurface(padding: 16, elevation: .flat) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(title).font(.headline)
                Spacer()
            }
        }
    }

    private func statusCard(
        _ title: LocalizedStringKey, message: String? = nil, systemImage: String, tint: Color, detail: String? = nil
    ) -> some View {
        CardSurface(padding: 16, elevation: .flat) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(systemName: systemImage, tint: tint, size: 28, corner: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    if let message {
                        Text(verbatim: message).font(.callout).foregroundStyle(.secondary)
                    }
                    if let detail, !detail.isEmpty {
                        DisclosureGroup("Details") {
                            Text(verbatim: String(detail.prefix(2_000)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                Spacer()
            }
        }
    }

    private var upgradeBar: some View {
        HStack {
            Text(updater.selectedCount == 0 ? String(localized: "Select apps to update") : selectedCountTitle)
                .font(.callout.weight(.medium))
                .foregroundStyle(updater.selectedCount == 0 ? Color.secondary : Color.primary)
            Spacer()
            Button {
                confirmationSelection = updater.selectedUpdates
                showingUpgradeConfirmation = true
            } label: {
                Text(upgradeConfirmationLabel(count: updater.selectedCount))
            }
            .buttonStyle(.borderedProminent)
            .tint(Tint.accent)
            .disabled(!updater.canUpgradeSelection)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var updateCountTitle: String {
        updater.updates.count == 1 ? String(localized: "1 update available") : String(localized: "\(updater.updates.count) updates available")
    }

    private var selectedCountTitle: String {
        updater.selectedCount == 1 ? String(localized: "1 app selected") : String(localized: "\(updater.selectedCount) apps selected")
    }

    private func upgradeConfirmationLabel(count: Int) -> String {
        count == 1 ? String(localized: "Upgrade 1 App") : String(localized: "Upgrade \(count) Apps")
    }

    private var upgradeConfirmationMessage: String {
        let versions = confirmationSelection.map {
            String(localized: "\(displayName(for: $0.token)) \($0.installedVersion) to \($0.currentVersion)")
        }
        let selectionSummary: String
        if versions.count <= 5 {
            selectionSummary = versions.joined(separator: ", ")
        } else {
            selectionSummary = versions.prefix(5).joined(separator: ", ") + String(localized: ", and \(versions.count - 5) more")
        }
        return String(localized: "Homebrew will upgrade \(selectionSummary). It may quit running apps and remove superseded cask versions as part of its normal upgrade process.")
    }
}
