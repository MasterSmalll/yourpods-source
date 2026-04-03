import Foundation
import Security
import os

/// Protocol for Keychain operations, enabling mock injection in tests.
protocol KeychainStore {
    func save(password: String, forProfileId profileId: String) -> Bool
    func password(forProfileId profileId: String) -> String?
    func deletePassword(forProfileId profileId: String)
}

/// Secure storage for gPodder sync passwords using the iOS Keychain.
///
/// Uses `kSecAttrAccessibleAfterFirstUnlock` so passwords remain available during
/// background refresh and cold starts before unlock.
///
/// Service: `com.asecretcompany.yourpods.profile`
/// Account: profile ID
final class KeychainHelper: KeychainStore {
    
    static let shared = KeychainHelper()
    
    private static let logger = Logger(subsystem: "com.yourpods", category: "keychain")
    private static let service = "com.asecretcompany.yourpods.profile"
    
    // MARK: - Save
    
    /// Store or update a password in the Keychain for the given profile.
    /// Returns `true` on success.
    @discardableResult
    func save(password: String, forProfileId profileId: String) -> Bool {
        guard let data = password.data(using: .utf8) else {
            Self.logger.warning("Failed to encode password as UTF-8 for profile \(profileId)")
            return false
        }
        
        // Try to update first (avoids delete + add race)
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: profileId
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
        
        if updateStatus == errSecSuccess {
            Self.logger.debug("Updated Keychain password for profile \(profileId)")
            return true
        }
        
        if updateStatus == errSecItemNotFound {
            // Item doesn't exist yet — add it
            var addQuery = updateQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                Self.logger.debug("Saved Keychain password for profile \(profileId)")
                return true
            } else {
                Self.logger.warning("Failed to add Keychain password for profile \(profileId): \(addStatus)")
                return false
            }
        }
        
        Self.logger.warning("Failed to update Keychain password for profile \(profileId): \(updateStatus)")
        return false
    }
    
    // MARK: - Read
    
    /// Retrieve the stored password for the given profile, or `nil` if not found.
    func password(forProfileId profileId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: profileId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                Self.logger.warning("Keychain read failed for profile \(profileId): \(status)")
            }
            return nil
        }
        
        return String(data: data, encoding: .utf8)
    }
    
    // MARK: - Delete
    
    /// Remove the stored password for the given profile.
    func deletePassword(forProfileId profileId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: profileId
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Self.logger.warning("Keychain delete failed for profile \(profileId): \(status)")
        }
    }
    
    // MARK: - Migration
    
    /// Migrate passwords from UserDefaults to Keychain for all saved profiles.
    /// Call once during app startup. Idempotent — skips if already migrated.
    static func migrateFromUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        let migrationKey = "keychainPasswordMigrationCompleted"
        
        guard !defaults.bool(forKey: migrationKey) else { return }
        
        guard let data = defaults.data(forKey: "serverProfiles"),
              let profiles = try? JSONDecoder().decode([ServerProfile].self, from: data) else {
            // No profiles to migrate — mark as done
            defaults.set(true, forKey: migrationKey)
            return
        }
        
        let helper = KeychainHelper.shared
        
        for profile in profiles where !profile.isLocal {
            let udKey = "gpodder_password_\(profile.id)"
            if let password = defaults.string(forKey: udKey), !password.isEmpty {
                if helper.save(password: password, forProfileId: profile.id) {
                    defaults.removeObject(forKey: udKey)
                    logger.info("Migrated password to Keychain for profile \(profile.id)")
                } else {
                    // Leave in UserDefaults if Keychain write failed — don't lose the password
                    logger.warning("Keychain write failed for profile \(profile.id) — password kept in UserDefaults")
                }
            }
        }
        
        defaults.set(true, forKey: migrationKey)
        logger.info("Keychain password migration completed")
    }
    
    // MARK: - Feed Credentials (per-podcast auth)
    
    /// Separate Keychain service for feed-level credentials (distinct from gPodder profile passwords).
    private static let feedService = "com.asecretcompany.yourpods.feed"
    
    /// JSON container for feed credentials.
    private struct FeedCreds: Codable {
        let u: String  // username
        let p: String  // password
    }
    
    /// Store feed credentials in the Keychain for a podcast URL.
    /// Returns `true` on success.
    @discardableResult
    func saveFeedCredentials(username: String, password: String, forPodcastUrl podcastUrl: String) -> Bool {
        guard let data = try? JSONEncoder().encode(FeedCreds(u: username, p: password)) else {
            Self.logger.warning("Failed to encode feed credentials for \(podcastUrl)")
            return false
        }
        
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.feedService,
            kSecAttrAccount as String: podcastUrl
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
        
        if updateStatus == errSecSuccess {
            Self.logger.debug("Updated feed credentials for \(podcastUrl)")
            return true
        }
        
        if updateStatus == errSecItemNotFound {
            var addQuery = updateQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                Self.logger.debug("Saved feed credentials for \(podcastUrl)")
                return true
            } else {
                Self.logger.warning("Failed to add feed credentials for \(podcastUrl): \(addStatus)")
                return false
            }
        }
        
        Self.logger.warning("Failed to update feed credentials for \(podcastUrl): \(updateStatus)")
        return false
    }
    
    /// Retrieve stored feed credentials for a podcast URL.
    func feedCredentials(forPodcastUrl podcastUrl: String) -> (username: String, password: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.feedService,
            kSecAttrAccount as String: podcastUrl,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let creds = try? JSONDecoder().decode(FeedCreds.self, from: data) else {
            if status != errSecItemNotFound {
                Self.logger.warning("Feed credential read failed for \(podcastUrl): \(status)")
            }
            return nil
        }
        
        return (creds.u, creds.p)
    }
    
    /// Remove stored feed credentials for a podcast URL.
    func deleteFeedCredentials(forPodcastUrl podcastUrl: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.feedService,
            kSecAttrAccount as String: podcastUrl
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Self.logger.warning("Feed credential delete failed for \(podcastUrl): \(status)")
        }
    }
    
    /// Build a Basic auth header from stored feed credentials.
    /// Returns `"Basic <base64>"` or `nil` if no credentials stored.
    func buildBasicAuthHeader(forPodcastUrl podcastUrl: String) -> String? {
        guard let creds = feedCredentials(forPodcastUrl: podcastUrl) else { return nil }
        let combined = "\(creds.username):\(creds.password)"
        let encoded = Data(combined.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }
    
    // MARK: - Podcast Index API Credentials
    
    /// Separate Keychain service for Podcast Index API credentials.
    private static let podcastIndexService = "com.asecretcompany.yourpods.podcastindex"
    
    /// Store a Podcast Index credential (key or secret) in the Keychain.
    /// - Parameters:
    ///   - value: The credential value
    ///   - account: The account identifier ("apiKey" or "apiSecret")
    /// - Returns: `true` on success.
    @discardableResult
    func savePodcastIndexCredential(_ value: String, forAccount account: String) -> Bool {
        guard let data = value.data(using: .utf8) else {
            Self.logger.warning("Failed to encode Podcast Index credential for \(account)")
            return false
        }
        
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.podcastIndexService,
            kSecAttrAccount as String: account
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
        
        if updateStatus == errSecSuccess {
            Self.logger.debug("Updated Podcast Index credential for \(account)")
            return true
        }
        
        if updateStatus == errSecItemNotFound {
            var addQuery = updateQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                Self.logger.debug("Saved Podcast Index credential for \(account)")
                return true
            } else {
                Self.logger.warning("Failed to add Podcast Index credential for \(account): \(addStatus)")
                return false
            }
        }
        
        Self.logger.warning("Failed to update Podcast Index credential for \(account): \(updateStatus)")
        return false
    }
    
    /// Retrieve a Podcast Index credential from the Keychain.
    func podcastIndexCredential(forAccount account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.podcastIndexService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                Self.logger.warning("Podcast Index credential read failed for \(account): \(status)")
            }
            return nil
        }
        
        return String(data: data, encoding: .utf8)
    }
    
    /// Remove a Podcast Index credential from the Keychain.
    func deletePodcastIndexCredential(forAccount account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.podcastIndexService,
            kSecAttrAccount as String: account
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Self.logger.warning("Podcast Index credential delete failed for \(account): \(status)")
        }
    }
    
    // MARK: - Podcast Index Migration
    
    /// Migrate Podcast Index API credentials from UserDefaults to Keychain.
    /// Call once during app startup. Idempotent — skips if already migrated.
    static func migratePodcastIndexCredsFromUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        let migrationKey = "keychainPodcastIndexMigrationCompleted"
        
        guard !defaults.bool(forKey: migrationKey) else { return }
        
        let helper = KeychainHelper.shared
        
        if let apiKey = defaults.string(forKey: "podcastIndexApiKey"), !apiKey.isEmpty {
            if helper.savePodcastIndexCredential(apiKey, forAccount: "apiKey") {
                defaults.removeObject(forKey: "podcastIndexApiKey")
                logger.info("Migrated Podcast Index API key to Keychain")
            } else {
                logger.warning("Keychain write failed for Podcast Index API key — kept in UserDefaults")
            }
        }
        
        if let apiSecret = defaults.string(forKey: "podcastIndexApiSecret"), !apiSecret.isEmpty {
            if helper.savePodcastIndexCredential(apiSecret, forAccount: "apiSecret") {
                defaults.removeObject(forKey: "podcastIndexApiSecret")
                logger.info("Migrated Podcast Index API secret to Keychain")
            } else {
                logger.warning("Keychain write failed for Podcast Index API secret — kept in UserDefaults")
            }
        }
        
        defaults.set(true, forKey: migrationKey)
        logger.info("Podcast Index credential migration completed")
    }
}

