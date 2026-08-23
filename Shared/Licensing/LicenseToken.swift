import CryptoKit
import Foundation

/// A license as the app sees it: a signed assertion it can check entirely on its own.
///
/// Verification is offline by design. Redact's whole promise is that footage never leaves the
/// Mac, and an app that phones home before it will run breaks that promise in spirit even if the
/// frames stay put. So the signature is checked locally against a public key compiled into the
/// binary, and the network is used only for the things that genuinely need it — claiming a seat
/// and learning about revocation.
public struct LicenseToken: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case full
        case trial
    }

    public let licenseID: String
    public let accountEmail: String
    public let accountName: String
    public let seats: Int
    public let issuedAt: Date
    /// `nil` means perpetual.
    public let expiresAt: Date?
    public let features: [String]
    public let kind: Kind
    /// The original string, kept so it can be sent back for activation and heartbeats.
    public let raw: String

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    public var daysRemaining: Int? {
        guard let expiresAt else { return nil }
        let seconds = expiresAt.timeIntervalSinceNow
        return seconds <= 0 ? 0 : Int(ceil(seconds / 86_400))
    }

    public func has(_ feature: String) -> Bool { features.contains(feature) }
}

public enum LicenseTokenError: LocalizedError, Equatable {
    case malformed
    case badSignature
    case unreadablePayload
    case unsupportedVersion(Int)
    case trialTooLong

    public var errorDescription: String? {
        switch self {
        case .malformed:
            return "That doesn't look like a RizwanAI license key. Copy the whole key, including "
                 + "the RZAI1 at the start."
        case .badSignature:
            return "This license key isn't valid. It wasn't issued by RizwanAI, or it was altered "
                 + "after it was issued."
        case .unreadablePayload:
            return "This license key is damaged. Ask for a fresh copy."
        case .unsupportedVersion(let version):
            return "This license needs a newer version of the app (format v\(version))."
        case .trialTooLong:
            return "This trial key claims a longer run than trials are allowed."
        }
    }
}

/// Checks license tokens against the keys baked into this build.
///
/// Two keys, with deliberately different powers. `licensePublicKey` matches a private key that
/// exists only on Rizwan's machine and never touches a server, so a full license cannot be minted
/// by anyone who breaks into the backend. `trialPublicKey` matches a key that does live on the
/// server, because trials must issue automatically — and anything it signs is capped here at
/// ``trialDayLimit`` and refused as a full license, so stealing it yields nothing better than the
/// trial a visitor could request anyway.
public enum LicenseVerifier {
    /// Replace both with the output of `python3 -m redactapi.licensetool keygen`.
    /// These placeholders verify nothing — every key is rejected until they are set.
    public static let licensePublicKey = ""
    public static let trialPublicKey = ""

    public static let trialDayLimit = 14

    public static var isConfigured: Bool {
        !licensePublicKey.isEmpty && !trialPublicKey.isEmpty
    }

    /// Verify against explicit keys. The no-argument form uses the keys compiled into this
    /// build; this overload exists so the self-check tool can prove the Swift verifier and the
    /// Python signer agree byte-for-byte, without shipping test keys in the app.
    public static func verify(
        _ token: String,
        licenseKey: String = licensePublicKey,
        trialKey: String = trialPublicKey
    ) throws -> LicenseToken {
        let cleaned = token.components(separatedBy: .whitespacesAndNewlines).joined()
        let parts = cleaned.components(separatedBy: ".")
        guard parts.count == 3, parts[0] == "RZAI1" else { throw LicenseTokenError.malformed }

        guard let body = Self.base64URLDecode(parts[1]),
              let signature = Self.base64URLDecode(parts[2]) else {
            throw LicenseTokenError.malformed
        }

        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw LicenseTokenError.unreadablePayload
        }

        let version = json["v"] as? Int ?? 0
        guard version == 1 else { throw LicenseTokenError.unsupportedVersion(version) }

        let kind = LicenseToken.Kind(rawValue: json["k"] as? String ?? "full") ?? .full

        // The claimed kind picks the key. A token signed by the online trial key but claiming to
        // be a full license lands here on `licensePublicKey`, which never signed it, and fails.
        let keyMaterial = kind == .trial ? trialKey : licenseKey
        guard let keyData = Self.base64URLDecode(keyMaterial),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw LicenseTokenError.badSignature
        }
        guard publicKey.isValidSignature(signature, for: body) else {
            throw LicenseTokenError.badSignature
        }

        let issuedAt = Date(timeIntervalSince1970: TimeInterval(json["iat"] as? Int ?? 0))
        let expiresAt = (json["exp"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }

        if kind == .trial {
            // Belt and braces against the server key being abused: even a correctly-signed trial
            // is refused if it tries to run longer than a trial may.
            guard let expiresAt else { throw LicenseTokenError.trialTooLong }
            let days = expiresAt.timeIntervalSince(issuedAt) / 86_400
            guard days <= Double(trialDayLimit) + 1 else { throw LicenseTokenError.trialTooLong }
        }

        return LicenseToken(
            licenseID: json["id"] as? String ?? "",
            accountEmail: json["sub"] as? String ?? "",
            accountName: json["nm"] as? String ?? "",
            seats: json["st"] as? Int ?? 1,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            features: json["ft"] as? [String] ?? ["redact"],
            kind: kind,
            raw: cleaned
        )
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var padded = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        return Data(base64Encoded: padded)
    }
}
