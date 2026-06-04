import Foundation

/// A named group for organizing podcasts in the Library.
/// Stored in UserDefaults (profile-scoped), not SwiftData.
struct PodcastGroup: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var sortOrder: Int
    var iconName: String?
    var colorHex: String?
    
    init(id: String = UUID().uuidString, name: String, sortOrder: Int = 0, iconName: String? = "folder.fill", colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.iconName = iconName
        self.colorHex = colorHex
    }
}

// MARK: - Persistence (UserDefaults, profile-scoped)

extension PodcastGroup {
    
    private static func storageKey(forProfileId profileId: String) -> String {
        "podcastGroups_\(profileId)"
    }
    
    /// Load groups for the given profile. Returns empty array if none saved.
    static func loadGroups(forProfileId profileId: String) -> [PodcastGroup] {
        guard let data = UserDefaults.standard.data(forKey: storageKey(forProfileId: profileId)),
              let groups = try? JSONDecoder().decode([PodcastGroup].self, from: data) else {
            return []
        }
        return groups.sorted { $0.sortOrder < $1.sortOrder }
    }
    
    /// Save groups for the given profile.
    static func saveGroups(_ groups: [PodcastGroup], forProfileId profileId: String) {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: storageKey(forProfileId: profileId))
    }
    
    /// Delete a group by ID. Returns the updated groups array with sort orders renumbered.
    /// Note: Caller is responsible for clearing groupId on affected Podcasts.
    static func deleteGroup(id: String, from groups: [PodcastGroup], forProfileId profileId: String) -> [PodcastGroup] {
        var updated = groups.filter { $0.id != id }
        // Renumber sort orders
        for i in updated.indices {
            updated[i].sortOrder = i
        }
        saveGroups(updated, forProfileId: profileId)
        return updated
    }
}
