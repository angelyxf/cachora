import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var permission = PermissionCoordinator.shared
    @State private var selectedSection: AppSection? = .cleaning(.smartScan)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var cleanupExpanded = false
    @State private var advancedToolsExpanded = false
    @FocusState private var focusedSection: AppSection?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private static let cleanupCategories: [CleaningCategory] = [
        .systemJunk,
        .userCache,
        .mailAttachments,
        .trashBins,
        .largeFiles
    ]

    private static let advancedCategories: [CleaningCategory] = [
        .aiApps,
        .xcodeJunk,
        .brewCache,
        .nodeCache,
        .dockerCache
    ].filter(CleaningCategory.scannable.contains)

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .disabled(appState.duplicateMoveInProgress)
                .navigationSplitViewColumnWidth(min: 232, ideal: 248, max: 288)
        } detail: {
            detailContainer
        }
        .frame(minWidth: 960, minHeight: 640)
        .tint(Tint.accent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { selectSection(.settings) } label: {
                    Label("Settings", systemImage: selectedSection == .settings ? "gearshape.fill" : "gearshape")
                        .labelStyle(.iconOnly)
                }
                .help("Settings")
                .focused($focusedSection, equals: .settings)
                .accessibilityIdentifier(accessibilityIdentifier(for: .settings))
                .disabled(appState.duplicateMoveInProgress)
                .accessibilityAddTraits(selectedSection == .settings ? .isSelected : [])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !appState.cleanupEnvironment.isFixture else { return }
            appState.checkFullDiskAccess()
            permission.refreshStatus()
        }
        .onChange(of: appState.pendingExternalApp) { app in
            guard app != nil else { return }
            selectSection(.apps)
            appState.pendingExternalApp = nil
        }
        .onChange(of: appState.showUpdateSettings) { showUpdates in
            if showUpdates { selectSection(.settings) }
        }
        .onAppear {
            if appState.showUpdateSettings {
                selectSection(.settings)
            } else if appState.pendingExternalApp != nil {
                selectSection(.apps)
                appState.pendingExternalApp = nil
            } else if let selectedSection {
                focusedSection = selectedSection
            }
        }
        .onChange(of: appState.cleanErrorIsFDAFixable) { isFDAFixable in
            guard isFDAFixable, !appState.cleanupEnvironment.isFixture else { return }
            let pending = appState.pendingPermissionRetryItems
            appState.cleanError = nil
            appState.cleanErrorIsFDAFixable = false
            appState.requestFullDiskAccessAndRetry(
                items: pending,
                context: .cleanup(failedCount: pending.count)
            )
        }
        .alert("Couldn't clean everything", isPresented: Binding(
            get: { appState.cleanError != nil && !appState.cleanErrorIsFDAFixable },
            set: { if !$0 { appState.cleanError = nil } }
        )) {
            Button("OK", role: .cancel) { appState.cleanError = nil }
        } message: {
            Text(appState.cleanError ?? "")
        }
        .sheet(isPresented: Binding(
            get: { permission.isRequesting && permission.presentation == .mainWindow },
            set: { if !$0 && permission.presentation == .mainWindow { permission.dismiss(callRetry: false) } }
        )) {
            PermissionSheet()
        }
    }

    private var sidebar: some View {
        List {
            Section {
                navRow(
                    section: .cleaning(.smartScan),
                    label: "Overview",
                    icon: "internaldrive",
                    tint: Tint.accent,
                    badge: dashboardBadge,
                    emphasized: true
                )
                navRow(
                    section: .recovery,
                    label: "Recovery",
                    icon: "clock.arrow.circlepath",
                    tint: Tint.accent,
                    badge: nil
                )
                navRow(
                    section: .protection,
                    label: "Protection",
                    icon: "shield.checkered",
                    tint: Tint.accent,
                    badge: nil
                )
                navRow(
                    section: .performance,
                    label: "Performance",
                    icon: "gauge.with.dots.needle.67percent",
                    tint: Tint.cyan,
                    badge: nil
                )
                navRow(
                    section: .appleFeatures,
                    label: "Apple Features",
                    icon: "switch.2",
                    tint: Tint.accent,
                    badge: nil
                )
            } header: {
                sectionLabel("Care")
            }

            Section {
                navRow(
                    section: .apps,
                    label: "Uninstaller",
                    icon: "app.dashed",
                    tint: Tint.blue,
                    badge: appState.installedApps.isEmpty ? nil : "\(appState.installedApps.count)"
                )
                navRow(
                    section: .appUpdates,
                    label: "App Updates",
                    icon: "arrow.triangle.2.circlepath",
                    tint: Tint.accent,
                    badge: nil
                )
                navRow(
                    section: .orphans,
                    label: "Leftovers",
                    icon: "doc.questionmark",
                    tint: Tint.orange,
                    badge: appState.orphanedFiles.isEmpty ? nil : "\(appState.orphanedFiles.count)"
                )
            } header: {
                sectionLabel("Applications")
            }

            Section {
                navRow(
                    section: .spaceExplorer,
                    label: "Space Explorer",
                    icon: "square.3.layers.3d.down.right",
                    tint: Tint.accent,
                    badge: nil
                )
                navRow(
                    section: .duplicates,
                    label: "Duplicate Finder",
                    icon: "doc.on.doc",
                    tint: Tint.purple,
                    badge: nil
                )
                navRow(
                    section: .similarPhotos,
                    label: "Similar Photos",
                    icon: "photo.stack",
                    tint: Tint.pink,
                    badge: nil
                )
                DisclosureGroup(isExpanded: $cleanupExpanded) {
                    ForEach(Self.cleanupCategories) { category in
                        navRow(
                            section: .cleaning(category),
                            label: LocalizedStringKey(category.rawValue),
                            icon: category.icon,
                            tint: category.color,
                            badge: sizeBadge(for: category)
                        )
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "trash.slash")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text("Cleanup")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(sidebarLabelColor)
                    }
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                .tint(.secondary)
                .listRowInsets(rowInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                DisclosureGroup(isExpanded: $advancedToolsExpanded) {
                    ForEach(Self.advancedCategories) { category in
                        navRow(
                            section: .cleaning(category),
                            label: LocalizedStringKey(category.rawValue),
                            icon: category.icon,
                            tint: category.color,
                            badge: sizeBadge(for: category)
                        )
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text("Developer Cleanup")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(sidebarLabelColor)
                    }
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                .tint(.secondary)
                .listRowInsets(rowInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } header: {
                sectionLabel("Tools")
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 35)
        .scrollContentBackground(.hidden)
        .background(sidebarBackground)
        .navigationTitle(Text(verbatim: ProductIdentity.name))
        .onMoveCommand(perform: moveSelection)
        .onChange(of: selectedSection) { section in
            guard case let .cleaning(category)? = section else { return }
            withAnimation(reduceMotion ? nil : MotionTokens.gentle) {
                if Self.cleanupCategories.contains(category) {
                    cleanupExpanded = true
                }
                if Self.advancedCategories.contains(category) {
                    advancedToolsExpanded = true
                }
            }
        }
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12)
    }

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    private func navRow(
        section: AppSection,
        label: LocalizedStringKey,
        icon: String,
        tint: Color,
        badge: String?,
        emphasized: Bool = false
    ) -> some View {
        Button {
            selectSection(section)
        } label: {
            SidebarNavRow(
                label: label,
                icon: icon,
                tint: tint,
                badge: badge,
                isSelected: selectedSection == section,
                emphasized: emphasized
            )
        }
        .buttonStyle(.plain)
        .focused($focusedSection, equals: section)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(accessibilityIdentifier(for: section))
        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
        .listRowInsets(rowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var visibleSections: [AppSection] {
        var sections: [AppSection] = [
            .cleaning(.smartScan),
            .recovery,
            .protection,
            .performance,
            .appleFeatures,
            .apps,
            .appUpdates,
            .orphans,
            .spaceExplorer,
            .duplicates,
            .similarPhotos
        ]
        if cleanupExpanded {
            sections.append(contentsOf: Self.cleanupCategories.map(AppSection.cleaning))
        }
        if advancedToolsExpanded {
            sections.append(contentsOf: Self.advancedCategories.map(AppSection.cleaning))
        }
        return sections
    }

    private func selectSection(_ section: AppSection) {
        guard !appState.duplicateMoveInProgress else { return }
        selectedSection = section
        focusedSection = section
    }

    private func accessibilityIdentifier(for section: AppSection) -> String {
        switch section {
        case .recovery: return "sidebar.recovery"
        case .apps: return "sidebar.uninstaller"
        case .orphans: return "sidebar.leftovers"
        case .spaceExplorer: return "sidebar.spaceExplorer"
        case .duplicates: return "sidebar.duplicates"
        case .similarPhotos: return "sidebar.similarPhotos"
        case .protection: return "sidebar.protection"
        case .performance: return "sidebar.performance"
        case .appleFeatures: return "sidebar.appleFeatures"
        case .settings: return "toolbar.settings"
        case .appUpdates: return "sidebar.appUpdates"
        case .cleaning(let category): return "sidebar.cleaning.\(category.id)"
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let sections = visibleSections
        guard !sections.isEmpty else { return }
        let current = focusedSection ?? selectedSection
        let currentIndex = current.flatMap(sections.firstIndex(of:))
        let targetIndex: Int

        switch direction {
        case .up:
            targetIndex = max(0, (currentIndex ?? sections.count) - 1)
        case .down:
            targetIndex = min(sections.count - 1, (currentIndex ?? -1) + 1)
        default:
            return
        }

        selectSection(sections[targetIndex])
    }

    private var dashboardBadge: String? {
        guard appState.totalJunkSize > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: appState.totalJunkSize, countStyle: .file)
    }

    private func sizeBadge(for category: CleaningCategory) -> String? {
        guard let size = appState.categoryResults[category]?.totalSize, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private var sidebarBackground: some View {
        Color(nsColor: colorScheme == .dark ? .underPageBackgroundColor : .windowBackgroundColor)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(width: 0.5)
            }
            .ignoresSafeArea()
    }

    private var sidebarLabelColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.90) : Color.black.opacity(0.84)
    }

    @ViewBuilder
    private var detailContainer: some View {
        VStack(spacing: 0) {
            if appState.cleanupEnvironment.isFixture {
                Label("Test mode — file moves use samples; system status is live", systemImage: "testtube.2")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(.regularMaterial)
            } else if selectedSection != .settings && selectedSection != .recovery && selectedSection != .appUpdates
                        && !appState.hasFullDiskAccess && !appState.fdaBannerDismissed {
                accessBanner
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            detailView
                .id(selectedSection)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selectedSection)
        .animation(reduceMotion ? nil : MotionTokens.gentle, value: appState.fdaBannerDismissed)
        .animation(reduceMotion ? nil : MotionTokens.gentle, value: appState.hasFullDiskAccess)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientBackdrop())
    }

    @ViewBuilder
    private var detailView: some View {
        let sampleHome = appState.cleanupEnvironment.sampleHome
        let sampleTrash = appState.cleanupEnvironment.sampleTrash
        switch selectedSection {
        case .recovery:
            RecoveryCenterView(model: appState.recoveryCenter)
        case .apps:
            AppListView()
        case .orphans:
            OrphanListView()
        case .spaceExplorer:
            SpaceExplorerView(sampleFolder: sampleHome?.appendingPathComponent("Documents/Sample Files"))
        case .duplicates:
            DuplicateFinderView(finder: DuplicateFinder(trashHandler: sampleTrash),
                                sampleFolder: sampleHome?.appendingPathComponent("Documents/Sample Files"))
        case .similarPhotos:
            SimilarPhotosView(finder: SimilarPhotoFinder(trashHandler: sampleTrash),
                              sampleFolder: sampleHome?.appendingPathComponent("Pictures"))
        case .protection:
            ProtectionView()
        case .performance:
            PerformanceView(allowsSnapshotRemoval: sampleHome == nil)
        case .appleFeatures:
            AppleFeaturesView(sampleHome: sampleHome, sampleTrash: sampleTrash)
        case .appUpdates:
            AppUpdatesView(updater: appState.applicationUpdater, permitsPackageOperations: sampleHome == nil)
        case .settings:
            SettingsView()
        case .cleaning(let category):
            if category == .smartScan {
                DashboardView { selectSection($0) }
            } else {
                CategoryDetailView(category: category)
            }
        case nil:
            EmptyStateView(
                "Cachora",
                systemImage: "internaldrive",
                description: "Select a tool from the sidebar."
            )
        }
    }

    private var accessBanner: some View {
        HStack(spacing: 12) {
            IconTile(systemName: "lock.shield", tint: Tint.orange, size: 32, corner: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access is off")
                    .font(.system(size: 13, weight: .semibold))
                Text("Protected caches and app containers will be skipped.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Set up") {
                permission.requestAccess(context: .general) {
                    appState.checkFullDiskAccess()
                }
            }
            .accentButtonStyle()
            .controlSize(.regular)
            Button {
                appState.fdaBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Tint.orange.opacity(0.075))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Tint.orange.opacity(0.18), lineWidth: 0.5)
        }
    }
}

private struct SidebarNavRow: View {
    let label: LocalizedStringKey
    let icon: String
    let tint: Color
    let badge: String?
    let isSelected: Bool
    let emphasized: Bool

    private let rowShape = RoundedRectangle(cornerRadius: 9, style: .continuous)
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Tint.accent : .secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(label)
                .font(.system(size: 12.5, weight: isSelected || emphasized ? .semibold : .regular))
                .foregroundStyle(labelColor)
                .lineLimit(1)
            Spacer(minLength: 5)
            if let badge {
                Text(badge)
                    .font(.system(size: 9.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? tint : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .padding(.horizontal, 8)
        .background {
            if isSelected {
                selectionBackground
            } else if hovering {
                rowShape.fill(Color.primary.opacity(0.035))
            }
        }
        .contentShape(rowShape)
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: isSelected)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var selectionBackground: some View {
        #if canImport(SwiftUI, _version: 7.0)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(Tint.accent.opacity(0.20)), in: rowShape)
        } else {
            materialSelection
        }
        #else
        materialSelection
        #endif
    }

    private var materialSelection: some View {
        rowShape.fill(.regularMaterial)
            .overlay {
                rowShape.fill(Tint.accent.opacity(colorScheme == .dark ? 0.18 : 0.12))
            }
    }

    private var labelColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.91) : Color.black.opacity(0.84)
    }
}

