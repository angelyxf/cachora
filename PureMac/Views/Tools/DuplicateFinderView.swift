import AppKit
import SwiftUI

struct DuplicateFinderView: View {
    @EnvironmentObject private var appState: AppState
    private enum ScreenState: Equatable {
        case idle
        case scanning
        case finished
        case failed(String)
    }

    private let finder: DuplicateFinder
    private let sampleFolder: URL?
    private let ignoreStore: DuplicateIgnoreStore
    @State private var state: ScreenState = .idle
    @State private var result: DuplicateScanResult?
    @State private var selectedFolder: URL?
    @State private var progress = DuplicateScanProgress(
        phase: .discovering,
        filesInspected: 0,
        filesToHash: 0,
        filesHashed: 0,
        bytesHashed: 0,
        currentURL: nil
    )
    @State private var selection = DuplicateSelection()
    @State private var expandedGroupIDs: Set<String> = []
    @State private var scanGeneration = UUID()
    @State private var scanTask: Task<Void, Never>?
    @State private var trashTask: Task<Void, Never>?
    @State private var isMovingToTrash = false
    @State private var pendingTrash: DuplicateTrashReview?
    @State private var actionMessage: ActionMessage?
    @State private var filter = DuplicateResultFilter()
    @State private var ignored = DuplicateIgnoreRules()
    @State private var didLoadIgnored = false
    @State private var showIgnored = false
    @State private var ignoreError: String?
    @State private var invalidatedIgnoreCount = 0

    init(finder: DuplicateFinder = DuplicateFinder(), sampleFolder: URL? = nil) {
        self.finder = finder
        self.sampleFolder = sampleFolder
        self.ignoreStore = DuplicateIgnoreStore(fileURL: CleanupEnvironment.current.recoveryRoot
            .deletingLastPathComponent().appendingPathComponent("DuplicateIgnoreRules.json"))
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                header
                if let ignoreError {
                    HStack {
                        Text(ignoreError).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") { loadIgnored() }
                    }
                }
                content
                if let result, !result.groups.isEmpty {
                    selectionBar(result)
                }
            }
            .padding(24)
        }
        .sheet(item: $pendingTrash) { review in
            TrashReviewSheet(title: "Move selected duplicates to Trash?", selection: review.selection,
                             isFixture: sampleFolder != nil,
                             details: "\(review.selection.urls.count) selected · \(format(review.size))",
                             retainedURLs: review.groups.map(\.keeper.url)) { _ in
                moveSelectedToTrash(review)
            }
        }
        .sheet(isPresented: $showIgnored) { ignoredGroupsSheet }
        .onAppear { if !didLoadIgnored { loadIgnored() } }
        .onChange(of: filter.query) { _ in updateFilterSelection() }
        .onChange(of: filter.kind) { _ in updateFilterSelection() }
        .alert(item: $actionMessage) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.detail),
                dismissButton: .default(Text("OK"))
            )
        }
        .onDisappear {
            if !isMovingToTrash { scanGeneration = UUID() }
            scanTask?.cancel()
            trashTask?.cancel()
        }
    }

    private var header: some View {
        CardSurface(padding: 18, elevation: .flat, tint: Tint.accent) {
            HStack(spacing: 14) {
                IconTile(systemName: "square.on.square", tint: Tint.accent, size: 42, corner: 11)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Duplicate Finder")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(headerSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 16)
                Button { showIgnored = true } label: {
                    Text("Ignored groups (\(ignored.rules.count))")
                }
                .buttonStyle(.bordered)
                .disabled(isMovingToTrash || state == .scanning)
                .accessibilityIdentifier("duplicates.ignored")
                if state == .scanning {
                    Button("Cancel", role: .cancel) {
                        scanTask?.cancel()
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Stops scanning without changing any files")
                } else {
                    Button {
                        chooseFolder()
                    } label: {
                        Label(sampleFolder != nil ? "Scan test files" : result == nil ? "Choose Folder" : "Scan Another Folder",
                              systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Tint.accent)
                    .disabled(isMovingToTrash)
                    .accessibilityHint("Opens a folder picker")
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            idleState
        case .scanning:
            scanningState
        case .failed(let message):
            failureState(message)
        case .finished:
            if let result, result.groups.isEmpty {
                emptyResult(result)
            } else if let result {
                resultContent(result)
            } else {
                idleState
            }
        }
    }

    private var idleState: some View {
        CardSurface(padding: 0, elevation: .flat) {
            VStack(spacing: 15) {
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Tint.accent.opacity(0.09))
                        .frame(width: 116, height: 100)
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 44, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Tint.accent)
                }
                Text("Find copies that are exactly the same")
                    .font(.system(size: 18, weight: .semibold))
                Text("Choose a folder. Cachora compares file sizes and SHA-256 content hashes. Nothing is selected or removed automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                Button {
                    chooseFolder()
                } label: {
                    Label("Choose a Folder", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .tint(Tint.accent)
                .controlSize(.large)
                .disabled(isMovingToTrash)
                .padding(.top, 3)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var scanningState: some View {
        CardSurface(padding: 28, elevation: .flat, tint: Tint.accent) {
            VStack(spacing: 20) {
                Spacer()
                ZStack {
                    Circle()
                        .stroke(Tint.accent.opacity(0.14), lineWidth: 9)
                        .frame(width: 104, height: 104)
                    if let fraction = progress.fractionCompleted {
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(Tint.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 104, height: 104)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Tint.accent)
                    }
                    Image(systemName: progress.phase == .discovering ? "folder" : "number")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(Tint.accent)
                }
                VStack(spacing: 7) {
                    Text(progress.phase == .discovering ? "Looking through files" : "Verifying possible matches")
                        .font(.system(size: 18, weight: .semibold))
                    Text(progressSummary)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let currentURL = progress.currentURL {
                        Text(currentURL.path)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 520)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(progressSummary)
        }
    }

    private func failureState(_ message: String) -> some View {
        CardSurface(padding: 0, elevation: .flat, tint: Tint.red) {
            VStack(spacing: 14) {
                Spacer()
                IconTile(systemName: "exclamationmark.triangle.fill", tint: Tint.red, size: 54, corner: 14)
                Text("Scan could not finish")
                    .font(.system(size: 18, weight: .semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                HStack {
                    if let folder = selectedFolder {
                        Button("Try Again") { startScan(folder) }
                            .buttonStyle(.borderedProminent)
                            .tint(Tint.accent)
                            .disabled(isMovingToTrash)
                    }
                    Button("Choose Another Folder") { chooseFolder() }
                        .buttonStyle(.bordered)
                        .disabled(isMovingToTrash)
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func emptyResult(_ result: DuplicateScanResult) -> some View {
        CardSurface(padding: 0, elevation: .flat) {
            VStack(spacing: 14) {
                Spacer()
                IconTile(systemName: "checkmark.seal.fill", tint: Tint.green, size: 58, corner: 16)
                Text("No exact duplicates found")
                    .font(.system(size: 19, weight: .semibold))
                Text("Inspected \(result.filesInspected.formatted()) files in \(result.folder.lastPathComponent). \(skippedSummary(result.skippedFiles))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
                Button("Scan Again") { startScan(result.folder) }
                    .buttonStyle(.bordered)
                    .disabled(isMovingToTrash)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func resultContent(_ result: DuplicateScanResult) -> some View {
        let groups = filter.groups(from: activeGroups, selection: selection)
        return VStack(spacing: 12) {
            summaryCard(result)
            filterBar
            ScrollView {
                LazyVStack(spacing: 14) {
                    if invalidatedIgnoreCount > 0 {
                        Text("\(invalidatedIgnoreCount) ignore records expired. Scan results have been checked again.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if groups.isEmpty {
                        VStack(spacing: 10) {
                            Text(activeGroups.isEmpty ? "All duplicate groups are ignored" : "No matching files")
                                .font(.headline)
                            Text("Change the filters or undo an ignored group to review more files.")
                                .foregroundStyle(.secondary)
                            if filterIsActive { Button("Reset Filters") { resetFilters() } }
                        }
                        .padding(28).frame(maxWidth: .infinity)
                    }
                    ForEach(groups) { group in
                        groupCard(group)
                    }
                    recommendationCard
                    if !result.skippedFiles.isEmpty {
                        skippedCard(result.skippedFiles)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recommendationCard: some View {
        CardSurface(padding: 14, elevation: .flat) {
            VStack(alignment: .leading, spacing: 7) {
                Label("Suggested action", systemImage: "lightbulb")
                    .font(.callout.weight(.semibold))
                Text("Keep one file in each group. Cachora suggests the earliest modified file, using the path to break ties.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Review and restore instructions") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Open Details to check the full paths and modification dates. Use Keep This File to change the file you want to keep.")
                        Text("Select extra copies, then review the move and keep lists before confirming.")
                        Text("To restore a moved copy, move it from the Trash back to its original folder.")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                }
                .font(.callout)
                .accessibilityIdentifier("duplicates.instructions")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var activeGroups: [DuplicateGroup] {
        guard let result else { return [] }
        return result.groups.filter { !ignored.contains($0, in: result.folder) }
    }

    private var filterIsActive: Bool {
        !filter.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filter.kind != .all
    }

    private var matchingCopies: Set<URL> {
        filter.matchingCopyURLs(in: activeGroups, selection: selection)
    }

    private var filterBar: some View {
        CardSurface(padding: 12, elevation: .flat) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search file names or paths", text: $filter.query)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search file names or paths")
                        .accessibilityIdentifier("duplicates.search")
                    if filterIsActive {
                        Button("Reset Filters") { resetFilters() }.buttonStyle(.borderless)
                    }
                }
                HStack(spacing: 12) {
                    Picker("File type", selection: $filter.kind) {
                        ForEach(DuplicateFileKind.allCases, id: \.self) { kind in
                            Text(kindLabel(kind)).tag(kind)
                        }
                    }
                    .accessibilityIdentifier("duplicates.type")
                    Picker("Sort by", selection: $filter.sortKey) {
                        Text("Reviewable Size").tag(DuplicateSortKey.size)
                        Text("Name").tag(DuplicateSortKey.name)
                        Text("Modification Date").tag(DuplicateSortKey.modified)
                    }
                    .accessibilityIdentifier("duplicates.sort")
                    Button { filter.ascending.toggle() } label: {
                        Label(filter.ascending ? "Ascending" : "Descending",
                              systemImage: filter.ascending ? "arrow.up" : "arrow.down")
                    }
                    .accessibilityIdentifier("duplicates.order")
                    .fixedSize()
                }
                Text("Only matching extra copies can be selected. Changing filters deselects hidden files; the kept copy stays visible.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(isMovingToTrash)
    }

    private func kindLabel(_ kind: DuplicateFileKind) -> String {
        switch kind {
        case .all: return String(localized: "All File Types")
        case .images: return String(localized: "Images")
        case .videos: return String(localized: "Videos")
        case .audio: return String(localized: "Audio")
        case .documents: return String(localized: "Documents")
        case .archives: return String(localized: "Archives")
        case .other: return String(localized: "Other Files")
        }
    }

    private var ignoredGroupsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Ignored duplicate groups").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { showIgnored = false }.keyboardShortcut(.cancelAction)
            }
            Text("Ignored groups stay hidden in future scans of the same folder. Changed files or group members will be reviewed again after rescanning.")
                .font(.callout).foregroundStyle(.secondary)
            if let ignoreError { Text(ignoreError).font(.caption).foregroundStyle(.secondary) }
            if ignored.rules.isEmpty {
                Text("No ignored groups").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(ignored.rules) { rule in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("\(rule.files.count) ignored files").font(.headline)
                                    Spacer()
                                    Button("Undo Ignore") { undoIgnore(rule.id) }
                                        .accessibilityIdentifier("duplicates.undoIgnore")
                                }
                                Text(rule.folder.path).font(.caption).foregroundStyle(.secondary)
                                ForEach(rule.files, id: \.url) { file in
                                    Text(file.url.path).font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }
                }
            }
            Text("Undo makes the group available in the current results or the next scan. It does not select or move files.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 620, height: 460)
    }

    private func loadIgnored() {
        do {
            ignored = try ignoreStore.load()
            didLoadIgnored = true
            ignoreError = nil
            updateFilterSelection()
        } catch {
            didLoadIgnored = false
            ignoreError = String(localized: "Could not load ignored groups. All scan results remain available.")
        }
    }

    private func saveIgnored(_ updated: DuplicateIgnoreRules) -> Bool {
        guard didLoadIgnored else { loadIgnored(); return false }
        do {
            try ignoreStore.save(updated)
            ignored = updated
            ignoreError = nil
            return true
        } catch {
            ignoreError = String(localized: "Could not save ignored groups. Your ignore settings were not changed.")
            return false
        }
    }

    private func ignoreGroup(_ group: DuplicateGroup) {
        guard let result, !isMovingToTrash else { return }
        var updated = ignored
        updated.ignore(group, in: result.folder)
        if saveIgnored(updated) { updateFilterSelection() }
    }

    private func undoIgnore(_ id: UUID) {
        var updated = ignored
        updated.remove(id: id)
        _ = saveIgnored(updated)
    }

    private func updateFilterSelection() {
        selection.retainSelection(in: activeGroups, matching: matchingCopies)
    }

    private func resetFilters() {
        filter.query = ""
        filter.kind = .all
    }

    private func summaryCard(_ result: DuplicateScanResult) -> some View {
        let groups = filter.groups(from: activeGroups, selection: selection)
        let matchingFiles = groups.flatMap(\.files).filter { filter.matches($0) }
        let copyURLs = filter.matchingCopyURLs(in: groups, selection: selection)
        return CardSurface(padding: 14, elevation: .flat) {
            HStack(spacing: 0) {
                summaryMetric(value: groups.count.formatted(), label: "Duplicate groups", icon: "square.stack.3d.up", tint: Tint.accent)
                Divider().frame(height: 38)
                summaryMetric(value: matchingFiles.count.formatted(), label: "Matching files", icon: "doc.on.doc", tint: Tint.purple)
                Divider().frame(height: 38)
                summaryMetric(value: format(matchingFiles.reduce(0) { $0 + (copyURLs.contains($1.url) ? $1.size : 0) }), label: "Available to review", icon: "internaldrive", tint: Tint.green)
                Spacer(minLength: 10)
                Button("Rescan") { startScan(result.folder) }
                    .buttonStyle(.bordered)
                    .disabled(isMovingToTrash)
            }
        }
    }

    private func summaryMetric(value: String, label: LocalizedStringKey, icon: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            IconTile(systemName: icon, tint: tint, size: 30, corner: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
    }

    private func groupCard(_ group: DuplicateGroup) -> some View {
        let keeper = selection.keeper(in: group)
        let expanded = expandedGroupIDs.contains(group.id)
        let files = group.files.filter { $0.url == keeper.url || filter.matches($0) }
        let copies = filter.matchingCopyURLs(in: [group], selection: selection)
        let allSelected = !copies.isEmpty && copies.isSubset(of: selection.urls)
        return CardSurface(padding: 0, elevation: .flat, tint: Tint.accent) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    IconTile(systemName: "doc.on.doc.fill", tint: Tint.accent, size: 34, corner: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep \(keeper.url.lastPathComponent)")
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(group.files.count) exact copies · \(format(group.fileSize)) each")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(allSelected ? "Clear" : "Select copies") {
                        for url in copies { selection.setSelected(!allSelected, url: url, in: group) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isMovingToTrash || copies.isEmpty)
                    Button("Ignore This Group") { ignoreGroup(group) }
                        .buttonStyle(.borderless)
                        .disabled(isMovingToTrash || !didLoadIgnored)
                        .accessibilityIdentifier("duplicates.ignoreGroup")
                    Button {
                        toggleExpanded(group)
                    } label: {
                        Label("Details", systemImage: expanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(expanded ? "Collapse duplicate group" : "Expand duplicate group")
                }
                .padding(14)

                if expanded {
                    Divider()
                    VStack(spacing: 0) {
                        if files.count < group.files.count {
                            Text("\(group.files.count - files.count) nonmatching files hidden")
                                .font(.caption).foregroundStyle(.secondary).padding(8)
                        }
                        ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                            fileRow(file, in: group, isKeeper: file.url == keeper.url)
                            if index < files.count - 1 {
                                Divider().padding(.leading, 49)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func fileRow(_ file: DuplicateFile, in group: DuplicateGroup, isKeeper: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            if isKeeper {
                Image(systemName: "lock.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityLabel("Protected copy")
            } else {
                Toggle("", isOn: selectionBinding(for: file.url, in: group))
                    .labelsHidden()
                    .toggleStyle(AnimatedCheckboxStyle(tint: Tint.accent))
                    .disabled(isMovingToTrash)
                    .accessibilityLabel("Select \(file.url.lastPathComponent)")
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(file.url.lastPathComponent)
                        .font(.system(size: 13, weight: isKeeper ? .semibold : .regular))
                        .lineLimit(1)
                    if isKeeper {
                        Text(file.url == group.keeper.url ? "Suggested to keep" : "Keep")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if isKeeper && !filter.matches(file) {
                    Text("Kept copy shown for reference; outside the filter")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(file.url.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Text(format(file.size))
                    if let modifiedAt = file.modifiedAt {
                        Text("Modified \(modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 5) {
                if !isKeeper {
                    Button("Keep This File") {
                        selection.keep(file, in: group)
                        updateFilterSelection()
                    }
                    .disabled(isMovingToTrash)
                    .accessibilityLabel("Keep \(file.url.lastPathComponent)")
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                }
                .accessibilityLabel("Reveal \(file.url.lastPathComponent) in Finder")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    private func skippedCard(_ skippedFiles: [DuplicateSkippedFile]) -> some View {
        CardSurface(padding: 14, elevation: .flat, tint: Tint.orange) {
            DisclosureGroup {
                VStack(spacing: 8) {
                    ForEach(skippedFiles) { file in
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(Tint.orange)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.url.path)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(file.detail.map { "\(file.reason.label): \($0)" } ?? file.reason.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                            } label: {
                                Image(systemName: "arrow.forward.square")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Reveal skipped item in Finder")
                        }
                    }
                }
                .padding(.top, 10)
            } label: {
                HStack {
                    IconTile(systemName: "exclamationmark.triangle", tint: Tint.orange, size: 30, corner: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Skipped items")
                            .font(.system(size: 14, weight: .semibold))
                        Text("\(skippedFiles.count) unsafe or unavailable items were not scanned")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func selectionBar(_ result: DuplicateScanResult) -> some View {
        let copies = matchingCopies
        return CardSurface(padding: 14, elevation: .raised, tint: selection.urls.isEmpty ? nil : Tint.accent) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.urls.isEmpty ? "Nothing selected" : "\(selection.urls.count) selected")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    Text(selection.urls.isEmpty ? "\(copies.count) matching extra copies · Keep one per group" : "Selected size: \(format(selectedSize(in: result)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isMovingToTrash {
                    Button("Stop moving") { trashTask?.cancel() }
                        .accessibilityIdentifier("duplicates.stopMoving")
                }
                Button("Clear Selection") { selection.clear() }
                    .buttonStyle(.borderless)
                    .disabled(selection.urls.isEmpty || isMovingToTrash)
                    .accessibilityIdentifier("duplicates.clearSelection")
                Button(filterIsActive ? "Select All Filtered Copies" : "Select All Extra Copies") {
                    selection.selectAll(in: activeGroups, matching: copies)
                }
                    .buttonStyle(.bordered)
                    .disabled(isMovingToTrash || copies.isEmpty || selection.urls == copies)
                    .accessibilityIdentifier("duplicates.selectAll")
                Button {
                    var reviewSelection = selection
                    reviewSelection.retainSelection(in: activeGroups, matching: matchingCopies)
                    let groups = reviewSelection.groupsForReview(in: activeGroups)
                    if !groups.isEmpty { pendingTrash = DuplicateTrashReview(groups: groups) }
                } label: {
                    if isMovingToTrash {
                        ProgressView()
                            .controlSize(.small)
                            .frame(minWidth: 100)
                    } else {
                        Label("Review Selected Copies", systemImage: "list.bullet.clipboard")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Tint.accent)
                .disabled(selection.urls.isEmpty || isMovingToTrash || state == .scanning)
                .accessibilityIdentifier("duplicates.review")
                .accessibilityHint("Shows a confirmation before moving the selected copies")
            }
        }
    }

    private var headerSubtitle: String {
        if state == .scanning, let current = progress.currentURL {
            return current.deletingLastPathComponent().path
        }
        return selectedFolder?.path ?? String(localized: "Exact-match cleanup with a protected copy in every group")
    }

    private var progressSummary: String {
        switch progress.phase {
        case .discovering:
            return String(localized: "\(progress.filesInspected.formatted()) files inspected")
        case .hashing:
            return String(localized: "\(progress.filesHashed.formatted()) of \(progress.filesToHash.formatted()) candidates · \(format(progress.bytesHashed)) verified")
        }
    }

    private func selectedSize(in result: DuplicateScanResult) -> Int64 {
        result.groups.reduce(into: Int64(0)) { size, group in
            for file in group.files where selection.urls.contains(file.url) {
                size += file.size
            }
        }
    }

    private func selectionBinding(for url: URL, in group: DuplicateGroup) -> Binding<Bool> {
        Binding(
            get: { selection.urls.contains(url) },
            set: { selection.setSelected($0, url: url, in: group) }
        )
    }

    private func toggleExpanded(_ group: DuplicateGroup) {
        withAnimation(MotionTokens.gentle) {
            if expandedGroupIDs.contains(group.id) {
                expandedGroupIDs.remove(group.id)
            } else {
                expandedGroupIDs.insert(group.id)
            }
        }
    }

    private func chooseFolder() {
        guard !isMovingToTrash else { return }
        if let sampleFolder {
            startScan(sampleFolder)
            return
        }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a folder to check for duplicate files")
        panel.prompt = String(localized: "Scan Folder")
        panel.message = String(localized: "Cachora reads the selected folder and does not change anything during a scan.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let folder = panel.url {
            startScan(folder)
        }
    }

    private func startScan(_ folder: URL) {
        guard !isMovingToTrash else { return }
        scanTask?.cancel()
        let generation = UUID()
        scanGeneration = generation
        selectedFolder = folder
        selection = DuplicateSelection()
        expandedGroupIDs.removeAll()
        invalidatedIgnoreCount = 0
        result = nil
        progress = DuplicateScanProgress(
            phase: .discovering,
            filesInspected: 0,
            filesToHash: 0,
            filesHashed: 0,
            bytesHashed: 0,
            currentURL: folder
        )
        state = .scanning
        scanTask = Task { @MainActor in
            let usesScopedAccess = folder.startAccessingSecurityScopedResource()
            defer {
                if usesScopedAccess {
                    folder.stopAccessingSecurityScopedResource()
                }
            }
            do {
                if sampleFolder != nil { try RecoveryFileSystem.checkDirectory(folder.path) }
                let scanResult = try await finder.scan(folder: folder) { update in
                    await MainActor.run {
                        guard scanGeneration == generation else { return }
                        progress = update
                    }
                }
                try Task.checkCancellation()
                guard scanGeneration == generation else { return }
                var reconciled = ignored
                invalidatedIgnoreCount = reconciled.reconcile(scanResult)
                if invalidatedIgnoreCount > 0 {
                    // Changed groups must reappear even if saving the expired rules fails.
                    if !saveIgnored(reconciled) {
                        ignored = reconciled
                        ignoreError = String(localized: "Changed groups are available for review, but the expired ignore records could not be saved.")
                    }
                }
                result = scanResult
                expandedGroupIDs = Set(scanResult.groups.prefix(3).map(\.id))
                state = .finished
            } catch is CancellationError {
                guard scanGeneration == generation else { return }
                state = .idle
            } catch {
                guard scanGeneration == generation else { return }
                state = .failed(error.localizedDescription)
            }
            if scanGeneration == generation {
                scanTask = nil
            }
        }
    }

    private func moveSelectedToTrash(_ review: DuplicateTrashReview) {
        guard let currentResult = result, !isMovingToTrash,
              review.selection.urls.isSubset(of: selection.urls) else { return }
        let generation = scanGeneration
        let folder = currentResult.folder
        isMovingToTrash = true
        appState.duplicateMoveInProgress = true
        trashTask = Task { @MainActor in
            let usesScopedAccess = currentResult.folder.startAccessingSecurityScopedResource()
            defer {
                appState.duplicateMoveInProgress = false
                if usesScopedAccess {
                    currentResult.folder.stopAccessingSecurityScopedResource()
                }
                if scanGeneration == generation {
                    isMovingToTrash = false
                    trashTask = nil
                }
            }
            var movedFiles: [DuplicateFile] = []
            var failures: [String] = []
            var cancelled = false
            for group in review.groups {
                if Task.isCancelled { cancelled = true; break }
                do {
                    let copies = Set(group.files.dropFirst().map(\.url))
                    let report = try await finder.moveToTrash(group: group, selectedIDs: copies)
                    movedFiles.append(contentsOf: report.trashedFiles)
                    failures.append(contentsOf: report.failures.map { "\($0.url.lastPathComponent): \($0.message)" })
                    if report.cancelled { cancelled = true; break }
                } catch is CancellationError {
                    cancelled = true
                    break
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            guard scanGeneration == generation,
                  selectedFolder?.standardizedFileURL.path == folder.path,
                  result?.folder == folder else { return }
            applyTrashResult(movedFiles)
            let movedSummary = String(localized: "\(movedFiles.count) files totaling \(format(movedFiles.reduce(0) { $0 + $1.size })) were moved.")
            if cancelled {
                actionMessage = ActionMessage(title: String(localized: "Move stopped"),
                    detail: ([movedSummary, String(localized: "Remaining files were left in place. Moved copies can be restored from the Trash.")] + failures).joined(separator: "\n"))
            } else if failures.isEmpty {
                actionMessage = ActionMessage(
                    title: String(localized: "Moved to Trash"),
                    detail: movedSummary
                )
            } else {
                actionMessage = ActionMessage(
                    title: movedFiles.isEmpty ? String(localized: "Nothing was moved") : String(localized: "Review the move results"),
                    detail: ([movedSummary] + failures).joined(separator: "\n")
                )
            }
        }
    }

    private func applyTrashResult(_ movedFiles: [DuplicateFile]) {
        guard let currentResult = result, !movedFiles.isEmpty else { return }
        let movedIDs = Set(movedFiles.map(\.url))
        let remainingGroups = currentResult.groups.compactMap { group -> DuplicateGroup? in
            let remaining = group.files.filter { !movedIDs.contains($0.url) }
            guard remaining.count > 1 else { return nil }
            return DuplicateGroup(digest: group.digest, files: remaining)
        }
        result = DuplicateScanResult(
            folder: currentResult.folder,
            groups: remainingGroups,
            skippedFiles: currentResult.skippedFiles,
            filesInspected: currentResult.filesInspected,
            bytesHashed: currentResult.bytesHashed
        )
        let remainingGroupIDs = Set(remainingGroups.map(\.id))
        selection.removeMoved(movedIDs, remainingGroups: remainingGroupIDs)
        expandedGroupIDs.formIntersection(remainingGroupIDs)
    }

    private func skippedSummary(_ skippedFiles: [DuplicateSkippedFile]) -> String {
        skippedFiles.isEmpty
            ? String(localized: "Every eligible file was checked.")
            : String(localized: "\(skippedFiles.count) unsafe or unavailable items were skipped.")
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct DuplicateTrashReview: Identifiable {
    let groups: [DuplicateGroup]
    let selection: TrashSelection
    let size: Int64

    var id: UUID { selection.id }

    init(groups: [DuplicateGroup]) {
        self.groups = groups
        let copies = groups.flatMap { $0.files.dropFirst() }
        selection = TrashSelection(urls: Set(copies.map(\.url)))
        size = copies.reduce(0) { $0 + $1.size }
    }
}

private struct ActionMessage: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}
