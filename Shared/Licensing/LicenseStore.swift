import CryptoKit
import Foundation
import IOKit

/// Where the license lives on this Mac, and the guard against winding the clock back.
///
/// The token goes in the Keychain rather than `UserDefaults` for one practical reason: it
/// survives a reinstall. Someone who deletes the app and downloads it again keeps their license
/// and does not have to re-activate — and, on the other side, cannot reset an expired trial by
/// dragging the app to the Bin.
public enum LicenseStore {
    private static let service = "com.rizwanai.apps.license"
    private static let tokenAccount = "license-token"
    private static let watermarkAccount = "time-watermark"
    private static let machineAccount = "machine-id"

    // MARK: - Token

    public static func saveToken(_ token: String) {
        write(token.data(using: .utf8) ?? Data(), account: tokenAccount)
    }

    public static func loadToken() -> String? {
        read(account: tokenAccount).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func clearToken() {
        delete(account: tokenAccount)
    }

    // MARK: - Clock tampering

    /// The latest date this app has ever seen, so time cannot quietly run backwards.
    ///
    /// Expiry is a comparison against the system clock, and the system clock belongs to the
    /// user. Without this, setting the date back a month makes an expired trial work again. The
    /// watermark only ever moves forward, so that trick shows up as "now is earlier than a
    /// moment we have already lived through" — which is not something that happens honestly.
    ///
    /// Deliberately tolerant: a few hours of drift, a timezone change, or an NTP correction are
    /// normal. Only a large jump backwards is treated as tampering.
    public static let clockTolerance: TimeInterval = 6 * 3600

    public static func recordTimeWatermark(_ now: Date = Date()) {
        guard let existing = loadTimeWatermark(), existing > now else {
            write(String(now.timeIntervalSince1970).data(using: .utf8) ?? Data(),
                  account: watermarkAccount)
            return
        }
        // Now is behind the watermark: leave the watermark where it is.
    }

    public static func loadTimeWatermark() -> Date? {
        guard let data = read(account: watermarkAccount),
              let text = String(data: data, encoding: .utf8),
              let seconds = TimeInterval(text) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public static func clockLooksTampered(now: Date = Date()) -> Bool {
        guard let watermark = loadTimeWatermark() else { return false }
        return now.timeIntervalSince(watermark) < -clockTolerance
    }

    // MARK: - Machine identity

    /// A stable per-machine identifier, hashed so the raw hardware UUID never leaves the Mac.
    ///
    /// Identifies a machine for seat counting, not a person: it carries no name, account or
    /// hardware detail, and is derived the same way on every launch so re-activating the same
    /// Mac does not consume a second seat.
    public static func machineID() -> String {
        if let cached = read(account: machineAccount).flatMap({ String(data: $0, encoding: .utf8) }),
           !cached.isEmpty {
            return cached
        }

        let hardwareUUID = hardwareIdentifier() ?? UUID().uuidString
        let digest = SHA256Digest.hex(of: "rizwanai-apps:\(hardwareUUID)")
        write(digest.data(using: .utf8) ?? Data(), account: machineAccount)
        return digest
    }

    private static func hardwareIdentifier() -> String? {
        let entry = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice")
        )
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }

        let property = IORegistryEntryCreateCFProperty(
            entry, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        )
        return property?.takeRetainedValue() as? String
    }

    // MARK: - Keychain primitives

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func write(_ data: Data, account: String) {
        var query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        // Never syncs to iCloud and never leaves this Mac: a license is per-machine, and a seat
        // that silently followed someone to another device would be a licensing bug.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func read(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}

enum SHA256Digest {
    static func hex(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
