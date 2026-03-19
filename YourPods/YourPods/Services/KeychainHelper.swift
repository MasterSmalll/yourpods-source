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
}
