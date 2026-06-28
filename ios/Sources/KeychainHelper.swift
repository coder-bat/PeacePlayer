//
//  KeychainHelper.swift
//  PeacePlayer
//
//  Minimal Keychain wrapper for storing the session JWT and
//  per-user metadata. iOS only — uses the
//  kSecClassGenericPassword item class with a constant
//  service prefix so the items are scoped to this app.
//
//  2026-06-28
//

import Foundation
import Security

final class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}

    private let service = "com.peaceplayer.PeacePlayer"

    // MARK: - Public API

    /// Returns the value for `key` or nil if the item is missing
    /// or the user denied access. Errors are logged but not thrown
    /// — Keychain failures shouldn't crash the app.
    func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Writes (or overwrites) the value at `key`.
    func write(_ key: String, _ value: String) {
        let data = Data(value.utf8)

        // First try to update an existing item.
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess { return }

        // No existing item — add a new one.
        if updateStatus == errSecItemNotFound {
            var addQuery: [String: Any] = updateQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                #if DEBUG
                print("Keychain add failed for \(key): \(addStatus)")
                #endif
            }
        } else {
            #if DEBUG
            print("Keychain update failed for \(key): \(updateStatus)")
            #endif
        }
    }

    /// Removes the value at `key`. Silent if the item doesn't exist.
    func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            #if DEBUG
            print("Keychain delete failed for \(key): \(status)")
            #endif
        }
    }

    /// Removes every key we own. Used by sign-out and tests.
    func deleteAll() {
        for key in [
            "peaceplayer.session_token",
            "peaceplayer.user_id",
            "peaceplayer.email",
            "peaceplayer.expires_at",
        ] {
            delete(key)
        }
    }
}
