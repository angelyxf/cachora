import SwiftUI

/// A deliberately small first release. Legacy tools remain in the source,
/// but this product exposes only the recoverable cache flow.
struct BetaMainView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection = "cache"

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 32)).foregroundStyle(Tint.teal)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: ProductIdentity.name).font(.headline)
                        Text("Free beta").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 18).padding(.top, 24)
                List(selection: $selection) {
                    Section("Caches") {
                        Label("Application caches", systemImage: "internaldrive").tag("cache")
                        if !appState.cleanupEnvironment.isFixture {
                            Label("Node package caches", systemImage: "leaf").tag("node")
                            Label("Homebrew cache", systemImage: "shippingbox").tag("brew")
                        }
                    }
                    Section {
                        Label("Recovery", systemImage: "clock.arrow.circlepath").tag("recovery")
                        Label("About this beta", systemImage: "info.circle").tag("about")
                    }
                }.listStyle(.sidebar)
                Text("Review first. Restore when needed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.bottom, 24)
            }.navigationSplitViewColumnWidth(min: 220, ideal: 248)
        } detail: {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Label(appState.cleanupEnvironment.isFixture ? "Test mode — disposable files only" : "Free beta", systemImage: "testtube.2")
                            .font(.caption.weight(.semibold))
                        Text("Manual scans. Files move to Recovery before deletion.").font(.caption)
                        Spacer()
                    }
                    if appState.cleanupEnvironment.isFixture {
                        Text(appState.cleanupEnvironment.home.deletingLastPathComponent().path)
                            .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    }
                }.padding(14).background(Tint.teal.opacity(0.08))
                Group {
                    switch selection {
                    case "node": CategoryDetailView(category: .nodeCache)
                    case "brew": CategoryDetailView(category: .brewCache)
                    case "recovery": RecoveryCenterView(model: appState.recoveryCenter, showCloseButton: false)
                    case "about": BetaAboutView(allowNetwork: !appState.cleanupEnvironment.isFixture)
                    default: CategoryDetailView(category: .userCache)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .navigationTitle(ProductIdentity.name)
        .tint(Tint.teal)
        .alert("Cleanup needs review", isPresented: Binding(
            get: { appState.cleanError != nil }, set: { if !$0 { appState.cleanError = nil } }
        )) { Button("OK", role: .cancel) { appState.cleanError = nil } }
        message: { Text(appState.cleanError ?? "") }
    }
}

struct BetaAboutView: View {
    var allowNetwork = true
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 48)).foregroundStyle(Tint.teal).accessibilityHidden(true)
                Text(verbatim: ProductIdentity.name).font(.largeTitle.weight(.semibold))
                Text("Version \(AppConstants.appVersion)").font(.subheadline).foregroundStyle(.secondary)
                Label("Your files stay on this Mac", systemImage: "lock.shield")
                Text("Scans and recovery records stay on your Mac. This beta has no analytics, account, payment, or automatic cleanup. Checking for updates contacts GitHub only when you choose it.")
                Text("Recovery copies still use disk space. Permanent deletion cannot be undone. Recovery is not a separate backup.")
                    .foregroundStyle(.secondary)
                Divider()
                if allowNetwork { AppUpdateSettingsView() }
                Divider()
                Text("Built on PureMac (MIT). An independent community project.").font(.caption)
                Link("Upstream source and license", destination: URL(string: "https://github.com/momenbasel/PureMac")!)
                if let repository = ProductIdentity.releaseChannel?.releasesURL.deletingLastPathComponent() {
                    Link("Project and feedback", destination: repository)
                }
            }.padding(32).frame(maxWidth: 760, alignment: .leading)
        }
    }
}
