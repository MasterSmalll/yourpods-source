import Foundation
import SwiftData
import Security
import os

/// One-shot migrator that reads the Flutter app's persisted data on first launch
/// and imports it into the native Swift data stores.
///
/// Storage mapping:
///   Flutter SharedPreferences  →  UserDefaults.standard  (keys prefixed with "flutter.")
///   Flutter flutter_secure_storage  →  iOS Keychain (service = bundle ID)
///   Flutter Documents dir JSON  →  SwiftData models
final class FlutterDataMigrator {
    
    private static let logger = Logger(subsystem: "com.yourpods", category: "FlutterMigration")
    private static let migrationFlag = "flutterMigrationCompleted"
    
    /// The bundle ID used as the Keychain service name by flutter_secure_storage.
    private static let flutterKeychainService = "com.asecretcompany.yourpods"
    
    // MARK: - Public API
    
    /// Returns true if Flutter data was detected and hasn't been migrated yet.
    static var needsMigration: Bool {
        guard !UserDefaults.standard.bool(forKey: migrationFlag) else { return false }
        return hasFlutterData
    }
    
    /// Run the full migration. Call this once from app startup.
    /// Returns true if a non-local profile was migrated (user may need to re-enter password).
    @MainActor
    @discardableResult
    static func migrateIfNeeded(
        podcastManager: PodcastManager,
        settingsManager: SettingsManager,
        modelContext: ModelContext
    ) -> Bool {
        guard needsMigration else { return false }
        
        logger.info("Flutter data detected — starting migration")
        
        migrateSettings(to: settingsManager)
        let hasServerProfile = migrateProfiles(settingsManager: settingsManager)
        migrateSubscriptions(modelContext: modelContext)
        migrateQueue()
        migrateEpisodeActions()
        cleanupFlutterDownloads()
        
        UserDefaults.standard.set(true, forKey: migrationFlag)
        logger.info("Flutter data migration completed")
        return hasServerProfile
    }
    
    // MARK: - Detection
    
    /// Check if any flutter-prefixed keys exist in UserDefaults.
    private static var hasFlutterData: Bool {
        let defaults = UserDefaults.standard
        // Check for the most common Flutter SharedPreferences keys
        let found = defaults.object(forKey: "flutter.current_profile_id") != nil
            || defaults.object(forKey: "flutter.sync_interval") != nil
            || defaults.string(forKey: "flutter.server_profiles") != nil
            || defaults.string(forKey: "flutter.audio_queue") != nil
            || defaults.object(forKey: "flutter.playback_speed") != nil
        logger.info("hasFlutterData check: \(found)")
        return found
    }
    
    // MARK: - Settings Migration
    
    /// Maps Flutter snake_case SharedPreferences keys to Swift camelCase UserDefaults keys.
    private static func migrateSettings(to settings: SettingsManager) {
        let defaults = UserDefaults.standard
        
        // Playback settings
        if let speed = defaults.object(forKey: "flutter.playback_speed") as? Double, speed > 0 {
            settings.playbackSpeed = speed
        }
        if let val = defaults.object(forKey: "flutter.skip_intro_seconds") as? Int {
            settings.skipIntroSeconds = val
        }
        if let val = defaults.object(forKey: "flutter.skip_outro_seconds") as? Int {
            settings.skipOutroSeconds = val
        }
        if let val = defaults.object(forKey: "flutter.skip_forward_seconds") as? Int {
            settings.skipForwardSeconds = val
        }
        if let val = defaults.object(forKey: "flutter.skip_backward_seconds") as? Int {
            settings.skipBackwardSeconds = val
        }
        
        // Sync settings
        if let val = defaults.object(forKey: "flutter.sync_interval") as? Int {
            settings.syncInterval = val
        }
        
        // Flutter stores enum as int index; Swift stores as rawValue string
        if let idx = defaults.object(forKey: "flutter.sync_conflict_strategy") as? Int {
            let strategies: [SyncStrategy] = [.ask, .serverWins, .deviceWins]
            if idx >= 0, idx < strategies.count {
                settings.syncConflictStrategy = strategies[idx]
            }
        }
        if let idx = defaults.object(forKey: "flutter.queue_sync_strategy") as? Int {
            let strategies: [QueueSyncStrategy] = [.ask, .serverWins, .deviceWins]
            if idx >= 0, idx < strategies.count {
                settings.queueSyncStrategy = strategies[idx]
            }
        }
        
        // Display settings
        if let val = defaults.object(forKey: "flutter.show_percent_listened") as? Bool {
            settings.showPercentListened = val
        }
        
        logger.info("Migrated settings from Flutter SharedPreferences")
    }
    
    // MARK: - Profile Migration
    
    /// Reads profiles from flutter_secure_storage (Keychain) and the SharedPreferences fallback.
    /// Writes them using the SAME format and keys the Swift app expects.
    /// Returns true if a non-local profile was migrated (password may need re-entry).
    @discardableResult
    private static func migrateProfiles(settingsManager: SettingsManager) -> Bool {
        var jsonString: String?
        
        // Try Keychain first (has passwords)
        if let kcStr = readFlutterKeychainItem(key: "server_profiles") {
            jsonString = kcStr
            logger.info("Found profiles in Keychain")
        }
        // Fall back to SharedPreferences
        else if let spStr = UserDefaults.standard.string(forKey: "flutter.server_profiles") {
            jsonString = spStr
            logger.info("Found profiles in SharedPreferences")
        }
        
        guard let jsonString,
              let data = jsonString.data(using: .utf8),
              let profiles = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            logger.info("No profiles found to migrate")
            return false
        }
        
        // Convert Flutter profiles to Swift ServerProfile objects
        var swiftProfiles: [ServerProfile] = []
        var hasNonLocalProfile = false
        
        for p in profiles {
            let id = p["id"] as? String ?? UUID().uuidString
            let name = p["name"] as? String ?? "Unknown"
            let baseUrl = p["baseUrl"] as? String
            let username = p["username"] as? String
            
            let profile = ServerProfile(id: id, name: name, baseUrl: baseUrl, username: username)
            swiftProfiles.append(profile)
            
            if baseUrl != nil { hasNonLocalProfile = true }
            
            // Try to get password from multiple sources:
            // 1. Password field in the profile JSON (from Keychain source)
            // 2. flutter_secure_storage Keychain entry for this profile
            // 3. SharedPreferences fallback
            var password: String?
            
            if let pw = p["password"] as? String, !pw.isEmpty {
                password = pw
                logger.info("Got password from profile JSON for \(id)")
            }
            
            // Try flutter_secure_storage keys (it may store password per-profile)
            if password == nil {
                for key in ["gpodder_password_\(id)", "password_\(id)", "profile_password_\(id)"] {
                    if let pw = readFlutterKeychainItem(key: key), !pw.isEmpty {
                        password = pw
                        logger.info("Got password from Keychain key '\(key)'")
                        break
                    }
                }
            }
            
            // Store password in Keychain (secure storage)
            if let password {
                KeychainHelper.shared.save(password: password, forProfileId: id)
                logger.info("Stored password for profile \(id) in Keychain")
            } else if baseUrl != nil {
                logger.info("No password found for profile \(id) — user will need to re-enter")
            }
        }
        
        // Store profiles using the SAME key and format the Swift app reads
        // ProfileSelectionView reads from "serverProfiles" as Data via JSONDecoder
        if let encoded = try? JSONEncoder().encode(swiftProfiles) {
            UserDefaults.standard.set(encoded, forKey: "serverProfiles")
            logger.info("Migrated \(swiftProfiles.count) profiles to 'serverProfiles' key")
        }
        
        // Migrate current profile selection using the SAME key SettingsManager reads
        if let currentId = readFlutterKeychainItem(key: "current_profile_id") {
            settingsManager.activeProfileId = currentId
            logger.info("Set active profile from Keychain: \(currentId)")
        } else if let currentId = UserDefaults.standard.string(forKey: "flutter.current_profile_id") {
            settingsManager.activeProfileId = currentId
            logger.info("Set active profile from SharedPreferences: \(currentId)")
        }
        
        return hasNonLocalProfile
    }
    
    // MARK: - Subscription Migration
    
    /// Reads subscription JSON files from Documents directory and creates SwiftData entities.
    private static func migrateSubscriptions(modelContext: ModelContext) {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        // Find all subs_*.json files (one per profile)
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: documentsDir.path) else {
            logger.info("No documents directory contents to migrate")
            return
        }
        
        let subFiles = contents.filter { $0.hasPrefix("subs_") && $0.hasSuffix(".json") }
        logger.info("Found \(subFiles.count) subscription files to migrate")
        
        for fileName in subFiles {
            let fileURL = documentsDir.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: fileURL),
                  let podcasts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                logger.warning("Failed to parse subscription file: \(fileName)")
                continue
            }
            
            for (index, p) in podcasts.enumerated() {
                guard let url = p["url"] as? String else { continue }
                
                // Check if already exists in SwiftData
                let descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.url == url })
                if let existing = try? modelContext.fetch(descriptor), !existing.isEmpty { continue }
                
                let podcast = Podcast(
                    url: url,
                    title: p["title"] as? String ?? "Unknown",
                    podcastDescription: p["description"] as? String,
                    logoUrl: p["logo_url"] as? String ?? p["logoUrl"] as? String,
                    website: p["website"] as? String,
                    author: p["author"] as? String
                )
                podcast.sortOrder = index
                modelContext.insert(podcast)
            }
            
            try? modelContext.save()
            logger.info("Migrated subscriptions from \(fileName) (\(podcasts.count) podcasts)")
        }
    }
    
    // MARK: - Queue Migration
    
    /// Reads the Flutter audio queue from SharedPreferences and converts to Swift QueueItem format.
    private static func migrateQueue() {
        let defaults = UserDefaults.standard
        
        // Get the profile ID to find profile-scoped queue data
        let profileId = defaults.string(forKey: "flutter.current_profile_id")
        
        let queueKeys = [
            profileId.map { "flutter.audio_queue_\($0)" },
            "flutter.audio_queue"
        ].compactMap { $0 }
        
        for key in queueKeys {
            if let queueJson = defaults.string(forKey: key),
               let data = queueJson.data(using: .utf8),
               let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                
                // Convert Flutter MediaItem format to Swift QueueItem format
                var queueItems: [QueueItem] = []
                for item in items {
                    let extras = item["extras"] as? [String: Any]
                    let id = item["id"] as? String ?? UUID().uuidString
                    let title = item["title"] as? String ?? "Unknown"
                    let album = item["album"] as? String ?? ""
                    let artUri = item["artUri"] as? String
                    let durationMs = item["duration"] as? Int
                    let audioUrl = extras?["url"] as? String ?? ""
                    let podcastUrl = extras?["podcastUrl"] as? String ?? ""
                    let positionSeconds = extras?["position_seconds"] as? Int ?? 0
                    
                    // Parse pubDate
                    var pubDate: Date? = nil
                    if let dateStr = extras?["pubDate"] as? String {
                        let formatter = ISO8601DateFormatter()
                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        pubDate = formatter.date(from: dateStr)
                        if pubDate == nil {
                            // Try without fractional seconds
                            formatter.formatOptions = [.withInternetDateTime]
                            pubDate = formatter.date(from: dateStr)
                        }
                    }
                    
                    let queueItem = QueueItem(
                        id: id,
                        title: title,
                        podcastTitle: album,
                        audioUrl: audioUrl,
                        artworkUrl: artUri,
                        durationSeconds: durationMs.map { $0 / 1000 },
                        positionSeconds: positionSeconds,
                        podcastUrl: podcastUrl,
                        pubDate: pubDate
                    )
                    queueItems.append(queueItem)
                }
                
                // Store using the SAME key and format AudioManager reads
                // AudioManager reads "savedQueue" as Data via JSONDecoder
                if let encoded = try? JSONEncoder().encode(queueItems) {
                    defaults.set(encoded, forKey: "savedQueue")
                    logger.info("Migrated queue (\(queueItems.count) items) to 'savedQueue' key")
                }
                
                // Migrate current item and position
                if let first = queueItems.first {
                    if let currentData = try? JSONEncoder().encode(first) {
                        defaults.set(currentData, forKey: "savedCurrentItem")
                    }
                    defaults.set(TimeInterval(first.positionSeconds), forKey: "savedCurrentPosition")
                    logger.info("Set current item to: \(first.title) at \(first.positionSeconds)s")
                }
                
                break
            }
        }
    }
    
    // MARK: - Episode Actions Migration
    
    /// Episode actions are complex — better to re-sync from the gPodder server.
    private static func migrateEpisodeActions() {
        logger.info("Episode actions will be re-synced from gPodder server. Trigger a sync to pull down listen history.")
    }
    
    // MARK: - Flutter Download Cleanup
    
    /// Remove orphaned Flutter audio downloads and caches.
    /// These files can't be mapped back to episodes reliably, so we free the space.
    private static func cleanupFlutterDownloads() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        
        // Known Flutter audio download/cache locations
        let foldersToRemove = [
            caches.appendingPathComponent("just_audio_cache"),
            caches.appendingPathComponent("audio_cache"),
            caches.appendingPathComponent("flutter_cache"),
            docs.appendingPathComponent("downloads"),
            docs.appendingPathComponent("audio_downloads"),
            appSupport.appendingPathComponent("audio_cache"),
        ]
        
        var cleanedCount = 0
        for folder in foldersToRemove {
            guard fm.fileExists(atPath: folder.path) else { continue }
            do {
                try fm.removeItem(at: folder)
                cleanedCount += 1
                logger.info("Cleaned up Flutter folder: \(folder.lastPathComponent)")
            } catch {
                logger.warning("Failed to remove \(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
        
        if cleanedCount > 0 {
            logger.info("Removed \(cleanedCount) Flutter download/cache folder(s)")
        }
    }
    
    // MARK: - Keychain Helpers
    
    /// Read a single item from flutter_secure_storage's Keychain entries.
    private static func readFlutterKeychainItem(key: String) -> String? {
        let servicesToTry = [
            flutterKeychainService,
            "flutter_secure_storage_service" // Older versions of the Flutter plugin used this hardcoded service name
        ]
        
        for service in servicesToTry {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            
            if status == errSecSuccess, let data = result as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }
}
