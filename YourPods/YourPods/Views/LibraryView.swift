import SwiftUI

/// Library screen showing all subscribed podcasts with reorder, filter, and management.
struct LibraryView: View {
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(PlayerManager.self) private var playerManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(NavigationState.self) private var navigationState
    @State private var searchText = ""
    @State private var filterMode: LibraryFilter = .all
    @State private var isEditing = false
    @State private var showManageGroups = false
    @State private var moveToGroupPodcast: Podcast? = nil
    @State private var showMoveToGroup = false
    @State private var showNoGroupsAlert = false
    
    // Multi-select for bulk move to group
    @State private var isSelectingForGroup = false
    @State private var selectedPodcasts: Set<String> = []  // Podcast URLs (unique ID)
    @State private var showBulkMoveSheet = false
    
    // Group collapse state — tracks which group IDs are collapsed
    @State private var collapsedGroups: Set<String> = []
    
    // Trigger to force re-read of groups from UserDefaults
    @State private var groupsVersion = 0
    
    // Programmatic navigation path for cross-tab deep linking
    @State private var libraryPath = NavigationPath()
    
    enum LibraryFilter: String, CaseIterable {
        case all = "All"
        case groups = "Groups"
        case downloaded = "Downloaded"
        case unplayed = "Unplayed"
        case inProgress = "In Progress"
    }
    
    /// Current profile's groups, loaded from UserDefaults.
    private var groups: [PodcastGroup] {
        // groupsVersion dependency forces SwiftUI to re-read on mutation
        _ = groupsVersion
        guard let profileId = settingsManager.activeProfileId else { return [] }
        return PodcastGroup.loadGroups(forProfileId: profileId)
    }
    
    var filteredSubscriptions: [Podcast] {
        var podcasts = podcastManager.subscriptions
        
        // Text search
        if !searchText.isEmpty {
            podcasts = podcasts.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        
        // Category filter (groups mode handled separately in body)
        switch filterMode {
        case .all, .groups:
            break
        case .downloaded:
            podcasts = podcasts.filter { podcast in
                podcast.episodes.contains { !$0.isStale && downloadManager.isDownloaded($0.guid) }
            }
        case .unplayed:
            podcasts = podcasts.filter { podcast in
                let markedBefore = podcast.effectiveSettings.markedPlayedBefore
                return podcast.episodes.contains { ep in
                    guard !ep.isStale else { return false }
                    guard !ep.isPlayed else { return false }
                    guard let pubDate = ep.pubDate else { return false }
                    if let markedBefore { return pubDate > markedBefore }
                    return true
                }
            }
        case .inProgress:
            podcasts = podcasts.filter { podcast in
                podcast.episodes.contains { ep in
                    !ep.isStale && podcastManager.getLatestAction(for: ep.guid) != nil
                }
            }
        }
        
        return podcasts
    }
    
    var body: some View {
        NavigationStack(path: $libraryPath) {
            VStack(spacing: 0) {
                // Filter bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LibraryFilter.allCases, id: \.self) { filter in
                            // Only show Groups pill if there are groups
                            if filter == .groups && groups.isEmpty { EmptyView() }
                            else {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        filterMode = filter
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        if filter == .groups {
                                            Image(systemName: "folder.fill")
                                                .font(.caption2)
                                        }
                                        Text(filter.rawValue)
                                    }
                                    .font(.subheadline.weight(filterMode == filter ? .bold : .regular))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(
                                        filterMode == filter
                                            ? Color.accentColor.opacity(0.15)
                                            : Color.gray.opacity(0.1)
                                    )
                                    .foregroundColor(filterMode == filter ? .accentColor : .primary)
                                    .clipShape(Capsule())
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                
                // Connectivity banner
                OfflineBanner {
                    Task {
                        let strategy = settingsManager.syncConflictStrategy
                        let conflicts = await podcastManager.refreshAndSync(
                            playerManager: playerManager,
                            downloadManager: downloadManager,
                            settingsManager: settingsManager,
                            strategy: strategy
                        )
                        if !conflicts.isEmpty && strategy == .ask {
                            playerManager.pendingConflicts = conflicts
                        }
                    }
                }
                
                if filterMode == .groups {
                    groupedListView
                } else {
                    flatListView
                }
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search podcasts")
            .toolbar {
                if isSelectingForGroup {
                    ToolbarItem(placement: .automatic) {
                        Button("Done") {
                            isSelectingForGroup = false
                            selectedPodcasts.removeAll()
                        }
                    }
                } else {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            navigationState.switchToAddPodcasts()
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                    
                    ToolbarItem(placement: .automatic) {
                        Menu {
                            Button {
                                isEditing.toggle()
                            } label: {
                                Label(isEditing ? "Done Reordering" : "Reorder", systemImage: "arrow.up.arrow.down")
                            }
                            
                            Divider()
                            
                            Button {
                                showManageGroups = true
                            } label: {
                                Label("Create Group", systemImage: "folder.badge.plus")
                            }
                            
                            Button {
                                if groups.isEmpty {
                                    showNoGroupsAlert = true
                                } else {
                                    isSelectingForGroup = true
                                    selectedPodcasts.removeAll()
                                }
                            } label: {
                                Label("Move to Group", systemImage: "folder")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .navigationDestination(for: Podcast.self) { podcast in
                PodcastDetailView(podcast: podcast)
            }
            .overlay {
                if podcastManager.subscriptions.isEmpty {
                    ContentUnavailableView(
                        "No Podcasts",
                        systemImage: "waveform",
                        description: Text("Tap + to search and add podcasts.")
                    )
                }
            }
            .sheet(isPresented: $showManageGroups) {
                ManageGroupsView()
                    .environment(settingsManager)
                    .environment(podcastManager)
                    .onDisappear { groupsVersion += 1 }
            }
            .sheet(isPresented: $showMoveToGroup) {
                if let podcast = moveToGroupPodcast {
                    MoveToGroupSheet(podcast: podcast, groups: groups)
                }
            }
            .sheet(isPresented: $showBulkMoveSheet) {
                BulkMoveToGroupSheet(
                    podcasts: podcastManager.subscriptions.filter { selectedPodcasts.contains($0.url) },
                    groups: groups
                ) {
                    isSelectingForGroup = false
                    selectedPodcasts.removeAll()
                }
            }
            .alert("No Groups Yet", isPresented: $showNoGroupsAlert) {
                Button("Create Group") { showManageGroups = true }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Create a group first, then you can move podcasts into it.")
            }
            // Multi-select floating button
            .overlay(alignment: .bottom) {
                if isSelectingForGroup && !selectedPodcasts.isEmpty {
                    Button {
                        showBulkMoveSheet = true
                    } label: {
                        Label("Move \(selectedPodcasts.count) Selected", systemImage: "folder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isSelectingForGroup)
            .animation(.easeInOut(duration: 0.2), value: selectedPodcasts.count)
            .onAppear {
                handlePendingPodcastNavigation()
            }
            .onChange(of: navigationState.podcastToNavigate) { _, podcast in
                if podcast != nil {
                    handlePendingPodcastNavigation()
                }
            }
        }
    }
    
    /// Consume `navigationState.podcastToNavigate` and push it onto the library nav stack.
    private func handlePendingPodcastNavigation() {
        guard let podcast = navigationState.podcastToNavigate else { return }
        navigationState.podcastToNavigate = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            libraryPath.append(podcast)
        }
    }
    
    // MARK: - Flat List (All / Downloaded / Unplayed / In Progress)
    
    private var flatListView: some View {
        List {
            ForEach(filteredSubscriptions) { podcast in
                if isSelectingForGroup {
                    selectableRow(podcast)
                } else {
                    NavigationLink(value: podcast) {
                        PodcastRow(podcast: podcast, unplayedCount: unplayedCount(podcast))
                    }
                    .contextMenu { podcastContextMenu(podcast) }
                }
            }
            .onDelete { indexSet in
                for idx in indexSet {
                    let podcast = filteredSubscriptions[idx]
                    Task { await podcastManager.removeSubscription(podcast) }
                }
            }
            .onMove { from, to in
                podcastManager.reorderSubscriptions(from: from, to: to, filteredList: filteredSubscriptions)
            }
        }
        .listStyle(.plain)
        #if os(iOS)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        #endif
        .refreshable {
            let strategy = settingsManager.syncConflictStrategy
            let conflicts = await podcastManager.refreshAndSync(
                playerManager: playerManager,
                downloadManager: downloadManager,
                settingsManager: settingsManager,
                strategy: strategy
            )
            if !conflicts.isEmpty && strategy == .ask {
                playerManager.pendingConflicts = conflicts
            }
        }
    }
    
    // MARK: - Grouped List
    
    private var groupedListView: some View {
        List {
            // Manage Groups button
            Button {
                showManageGroups = true
            } label: {
                Label("Manage Groups", systemImage: "folder.badge.gearshape")
                    .foregroundStyle(Color.accentColor)
            }
            
            // Grouped sections
            ForEach(groups) { group in
                let groupPodcasts = filteredSubscriptions.filter { $0.groupId == group.id }
                if !groupPodcasts.isEmpty || !searchText.isEmpty {
                    Section {
                        if !collapsedGroups.contains(group.id) {
                            ForEach(groupPodcasts) { podcast in
                                if isSelectingForGroup {
                                    selectableRow(podcast)
                                } else {
                                    NavigationLink(value: podcast) {
                                        PodcastRow(podcast: podcast, unplayedCount: unplayedCount(podcast))
                                    }
                                    .contextMenu { podcastContextMenu(podcast) }
                                }
                            }
                        }
                    } header: {
                        groupHeader(group: group, count: groupPodcasts.count)
                    }
                }
            }
            
            // Ungrouped section
            let ungrouped = filteredSubscriptions.filter { $0.groupId == nil }
            if !ungrouped.isEmpty {
                Section {
                    if !collapsedGroups.contains("_ungrouped") {
                        ForEach(ungrouped) { podcast in
                            if isSelectingForGroup {
                                selectableRow(podcast)
                            } else {
                                NavigationLink(value: podcast) {
                                    PodcastRow(podcast: podcast, unplayedCount: unplayedCount(podcast))
                                }
                                .contextMenu { podcastContextMenu(podcast) }
                            }
                        }
                    }
                } header: {
                    groupHeader(
                        group: PodcastGroup(id: "_ungrouped", name: "Ungrouped", iconName: "tray"),
                        count: ungrouped.count
                    )
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            let strategy = settingsManager.syncConflictStrategy
            let conflicts = await podcastManager.refreshAndSync(
                playerManager: playerManager,
                downloadManager: downloadManager,
                settingsManager: settingsManager,
                strategy: strategy
            )
            if !conflicts.isEmpty && strategy == .ask {
                playerManager.pendingConflicts = conflicts
            }
        }
    }
    
    // MARK: - Group Header
    
    @ViewBuilder
    private func groupHeader(group: PodcastGroup, count: Int) -> some View {
        let isUngrouped = group.id == "_ungrouped"
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if collapsedGroups.contains(group.id) {
                    collapsedGroups.remove(group.id)
                } else {
                    collapsedGroups.insert(group.id)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsedGroups.contains(group.id) ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                
                Image(systemName: group.iconName ?? "folder.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                
                Text("(\(count))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                
                Spacer()
            }
        }
        .textCase(nil)
        .contextMenu {
            if !isUngrouped {
                let idx = groups.firstIndex(where: { $0.id == group.id })
                
                if let idx, idx > 0 {
                    Button {
                        moveGroup(group, direction: .up)
                    } label: {
                        Label("Move Up", systemImage: "arrow.up")
                    }
                }
                
                if let idx, idx < groups.count - 1 {
                    Button {
                        moveGroup(group, direction: .down)
                    } label: {
                        Label("Move Down", systemImage: "arrow.down")
                    }
                }
            }
        }
    }
    
    private enum MoveDirection { case up, down }
    
    private func moveGroup(_ group: PodcastGroup, direction: MoveDirection) {
        guard let profileId = settingsManager.activeProfileId else { return }
        var mutableGroups = PodcastGroup.loadGroups(forProfileId: profileId)
        guard let idx = mutableGroups.firstIndex(where: { $0.id == group.id }) else { return }
        
        let targetIdx = direction == .up ? idx - 1 : idx + 1
        guard mutableGroups.indices.contains(targetIdx) else { return }
        
        mutableGroups.swapAt(idx, targetIdx)
        for i in mutableGroups.indices {
            mutableGroups[i].sortOrder = i
        }
        PodcastGroup.saveGroups(mutableGroups, forProfileId: profileId)
        groupsVersion += 1
    }
    
    // MARK: - Selectable Row (Multi-select mode)
    
    private func selectableRow(_ podcast: Podcast) -> some View {
        Button {
            if selectedPodcasts.contains(podcast.url) {
                selectedPodcasts.remove(podcast.url)
            } else {
                selectedPodcasts.insert(podcast.url)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedPodcasts.contains(podcast.url) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedPodcasts.contains(podcast.url) ? Color.accentColor : Color.secondary)
                
                PodcastRow(podcast: podcast, unplayedCount: unplayedCount(podcast))
            }
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Context Menu
    
    @ViewBuilder
    private func podcastContextMenu(_ podcast: Podcast) -> some View {
        // Group actions
        if groups.isEmpty {
            Button {
                showManageGroups = true
            } label: {
                Label("New Group…", systemImage: "folder.badge.plus")
            }
        } else {
            Button {
                moveToGroupPodcast = podcast
                showMoveToGroup = true
            } label: {
                Label("Move to Group…", systemImage: "folder")
            }
            
            Button {
                showManageGroups = true
            } label: {
                Label("New Group…", systemImage: "folder.badge.plus")
            }
            
            if podcast.groupId != nil {
                Button {
                    podcast.groupId = nil
                    try? podcastManager.saveContext()
                } label: {
                    Label("Remove from Group", systemImage: "folder.badge.minus")
                }
            }
        }
        
        Divider()
        
        // Reorder
        Button {
            isEditing.toggle()
        } label: {
            Label(isEditing ? "Done Reordering" : "Reorder Library", systemImage: "arrow.up.arrow.down")
        }
    }
    
    /// Count unplayed episodes since markedPlayedBefore.
    private func unplayedCount(_ podcast: Podcast) -> Int {
        let markedBefore = podcast.effectiveSettings.markedPlayedBefore
        return podcast.episodes.filter { ep in
            guard !ep.isStale else { return false }
            guard !ep.isPlayed else { return false }
            guard let pubDate = ep.pubDate else { return false }
            if let markedBefore { return pubDate > markedBefore }
            return true
        }.count
    }
}

// MARK: - Subviews

struct PodcastRow: View {
    let podcast: Podcast
    let unplayedCount: Int
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: URL(string: podcast.logoUrl ?? "")) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                        .overlay {
                            Image(systemName: "waveform")
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                if podcast.requiresAuth {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(3)
                        .background(Color.orange, in: Circle())
                        .offset(x: 4, y: 4)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(podcast.title)
                        .font(.body.bold())
                        .lineLimit(1)
                    
                    if podcast.explicit == true {
                        Text("E")
                            .font(.system(size: 8, weight: .black))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.12))
                            .foregroundStyle(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                    
                    if podcast.isComplete {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    
                    if unplayedCount > 0 {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                    }
                }
                
                if let author = podcast.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                HStack(spacing: 4) {
                    if unplayedCount > 0 {
                        Text("\(unplayedCount) unplayed")
                            .foregroundStyle(Color.accentColor)
                        Text("•")
                            .foregroundStyle(.tertiary)
                    }
                    Text("\(podcast.episodes.filter { !$0.isStale }.count) total")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Move to Group Sheet

private struct MoveToGroupSheet: View {
    let podcast: Podcast
    let groups: [PodcastGroup]
    @Environment(\.dismiss) private var dismiss
    @Environment(PodcastManager.self) private var podcastManager
    
    var body: some View {
        NavigationStack {
            List {
                // Ungrouped option
                Button {
                    podcast.groupId = nil
                    try? podcastManager.saveContext()
                    dismiss()
                } label: {
                    HStack {
                        Label("Ungrouped", systemImage: "tray")
                        Spacer()
                        if podcast.groupId == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                
                ForEach(groups) { group in
                    Button {
                        podcast.groupId = group.id
                        try? podcastManager.saveContext()
                        dismiss()
                    } label: {
                        HStack {
                            Label(group.name, systemImage: group.iconName ?? "folder.fill")
                            Spacer()
                            if podcast.groupId == group.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Move to Group")
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Bulk Move to Group Sheet

private struct BulkMoveToGroupSheet: View {
    let podcasts: [Podcast]
    let groups: [PodcastGroup]
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(PodcastManager.self) private var podcastManager
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(podcasts.count) podcast\(podcasts.count == 1 ? "" : "s") selected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Section("Choose a Group") {
                    ForEach(groups) { group in
                        Button {
                            movePodcasts(to: group)
                        } label: {
                            Label(group.name, systemImage: group.iconName ?? "folder.fill")
                        }
                    }
                }
            }
            .navigationTitle("Move to Group")
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
    
    private func movePodcasts(to group: PodcastGroup) {
        for podcast in podcasts {
            podcast.groupId = group.id
        }
        try? podcastManager.saveContext()
        dismiss()
        onComplete()
    }
}
