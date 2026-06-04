import SwiftUI

/// CRUD screen for managing podcast groups (create, rename, delete, reorder).
struct ManageGroupsView: View {
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var groups: [PodcastGroup] = []
    @State private var showAddGroup = false
    @State private var editingGroup: PodcastGroup? = nil
    @State private var newGroupName = ""
    @State private var newGroupIcon = "folder.fill"
    
    private var profileId: String {
        settingsManager.activeProfileId ?? "global"
    }
    
    private static let iconOptions = [
        "folder.fill", "star.fill", "heart.fill", "bolt.fill",
        "flame.fill", "leaf.fill", "book.fill", "mic.fill",
        "headphones", "sparkles", "globe", "desktopcomputer",
        "gamecontroller.fill", "theatermasks.fill", "sportscourt.fill",
        "newspaper.fill", "brain.head.profile", "waveform"
    ]
    
    var body: some View {
        NavigationStack {
            groupList
                .navigationTitle("Manage Groups")
                .inlineNavigationBarTitle()
                .toolbar { toolbarContent }
                .onAppear { loadGroups() }
                .alert("New Group", isPresented: $showAddGroup) {
                    TextField("Group Name", text: $newGroupName)
                    Button("Create") { createGroup() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Enter a name for the new group.")
                }
                .alert("Edit Group", isPresented: Binding(
                    get: { editingGroup != nil },
                    set: { if !$0 { editingGroup = nil } }
                )) {
                    TextField("Group Name", text: $newGroupName)
                    Button("Save") { saveEditedGroup() }
                    Button("Cancel", role: .cancel) { editingGroup = nil }
                } message: {
                    Text("Rename this group.")
                }
            #if os(macOS)
            .frame(minWidth: 400, minHeight: 350)
            #endif
        }
    }
    
    private var groupList: some View {
        List {
            if groups.isEmpty {
                ContentUnavailableView(
                    "No Groups",
                    systemImage: "folder.badge.plus",
                    description: Text("Create groups to organize your podcast library.")
                )
            } else {
                ForEach(groups) { group in
                    groupRow(group)
                }
                .onDelete(perform: deleteGroups)
                .onMove(perform: moveGroups)
            }
        }
    }
    
    private func groupRow(_ group: PodcastGroup) -> some View {
        Button {
            editingGroup = group
            newGroupName = group.name
            newGroupIcon = group.iconName ?? "folder.fill"
        } label: {
            HStack(spacing: 12) {
                Image(systemName: group.iconName ?? "folder.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.body.weight(.medium))
                    
                    let count = podcastManager.subscriptions.filter { $0.groupId == group.id }.count
                    Text("\(count) podcast\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .tint(.primary)
    }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                newGroupName = ""
                newGroupIcon = "folder.fill"
                showAddGroup = true
            } label: {
                Image(systemName: "plus")
            }
        }
    }
    
    private func loadGroups() {
        groups = PodcastGroup.loadGroups(forProfileId: profileId)
    }
    
    private func createGroup() {
        let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let group = PodcastGroup(
            name: trimmed,
            sortOrder: groups.count,
            iconName: newGroupIcon
        )
        groups.append(group)
        PodcastGroup.saveGroups(groups, forProfileId: profileId)
    }
    
    private func saveEditedGroup() {
        guard let editing = editingGroup,
              let idx = groups.firstIndex(where: { $0.id == editing.id }) else { return }
        
        let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        groups[idx].name = trimmed
        groups[idx].iconName = newGroupIcon
        PodcastGroup.saveGroups(groups, forProfileId: profileId)
        editingGroup = nil
    }
    
    private func deleteGroups(at offsets: IndexSet) {
        for idx in offsets {
            let group = groups[idx]
            // Clear groupId on all podcasts in this group
            for podcast in podcastManager.subscriptions where podcast.groupId == group.id {
                podcast.groupId = nil
            }
        }
        groups.remove(atOffsets: offsets)
        // Renumber sort orders
        for i in groups.indices {
            groups[i].sortOrder = i
        }
        PodcastGroup.saveGroups(groups, forProfileId: profileId)
        try? podcastManager.saveContext()
    }
    
    private func moveGroups(from source: IndexSet, to destination: Int) {
        groups.move(fromOffsets: source, toOffset: destination)
        for i in groups.indices {
            groups[i].sortOrder = i
        }
        PodcastGroup.saveGroups(groups, forProfileId: profileId)
    }
}
