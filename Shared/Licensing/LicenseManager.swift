import Combine
import Foundation
import SwiftUI

/// Whether the app may run, and why.
public enum LicenseState: Equatable {
    /// Still reading the Keychain on launch. Nothing is blocked yet.
    case checking
    /// No license and no trial on this Mac.
    case unlicensed
    case trial(daysRemaining: Int)
    case licensed(LicenseToken)
    case trialExpired
    case licenseExpired
    case revoked
    /// The system clock moved backwards far enough that expiry can't be trusted.
    case clockTampered
    /// This build has no public keys compiled in, so it cannot check a license at all.
    ///
    /// Fails *open*. A build without keys is a build mistake, not an unlicensed user, and
    /// bricking the app on a misconfiguration punishes the wrong person — every real customer,
    /// for a packaging slip. `redact-selfcheck` fails loudly on this so it is caught before a
    /// release rather than after one.
    case unconfigured

    /// The single question the rest of the app asks.
    public var allowsUse: Bool {
        switch self {
        case .checking, .trial, .licensed, .unconfigured: return true
        case .unlicensed, .trialExpired, .licenseExpired, .revoked, .clockTampered: return false
        }
    }
}

/// Owns the app's licensing state: what's stored, whether it's still valid, and what the server
/// says about revocation.
///
/// Verification is local and always happens first, so the app is fully usable offline. The
/// network is only consulted to claim a seat and to learn about revocation, and a failure to
/// reach it never downgrades a valid license — an unreachable server must not stop someone
/// redacting footage on a plane.
@MainActor
public final class LicenseManager: ObservableObject {
    public static let shared = LicenseManager()

    @Published public private(set) var state: LicenseState = .checking
    @Published public private(set) var isWorking = false
    @Published public var errorMessage: String?

    private init() {}

    public var token: LicenseToken? {
        if case .licensed(let token) = state { return token }
        return nil
    }

    public func has(_ feature: String) -> Bool {
        switch state {
        case .licensed(let token): return token.has(feature)
        // A trial gets the core app, not the paid extras — otherwise the trial is the product.
        case .trial: return feature == "redact"
        case .unconfigured: return true
        default: return false
        }
    }

    // MARK: - Launch

    /// Read whatever is stored and decide the state. Cheap, offline, and safe to call on launch.
    public func refresh() {
        guard LicenseVerifier.isConfigured else {
            if state != .unconfigured {
                print("""
                [licensing] WARNING: no public keys are compiled into this build, so licensing                 is not enforced. Set LicenseVerifier.licensePublicKey and .trialPublicKey from                 `python3 -m redactapi.licensetool keygen` before shipping.
                """)
            }
            state = .unconfigured
            return
        }

        LicenseStore.recordTimeWatermark()

        guard !LicenseStore.clockLooksTampered() else {
            state = .clockTampered
            return
        }

        guard let raw = LicenseStore.loadToken() else {
            state = .unlicensed
            return
        }

        do {
            let token = try LicenseVerifier.verify(raw)
            if token.isExpired {
                state = token.kind == .trial ? .trialExpired : .licenseExpired
            } else if token.kind == .trial {
                state = .trial(daysRemaining: token.daysRemaining ?? 0)
            } else {
                state = .licensed(token)
            }
        } catch {
            // A stored token that no longer verifies is worthless; drop it rather than leaving
            // the app stuck in an unfixable state.
            LicenseStore.clearToken()
            state = .unlicensed
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Activation

    /// Verify a pasted key, claim a seat for this Mac, and store it.
    ///
    /// The signature is checked before anything is sent, so a typo or a fake key fails instantly
    /// and offline rather than after a round trip.
    public func activate(pastedKey: String) async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }

        let token: LicenseToken
        do {
            token = try LicenseVerifier.verify(pastedKey)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        if token.isExpired {
            errorMessage = token.kind == .trial
                ? "That trial has already ended."
                : "That license expired on \(Self.dateLabel(token.expiresAt))."
            return
        }

        do {
            _ = try await LicenseClient.activate(token: token.raw)
        } catch let error as LicenseClient.ClientError {
            switch error {
            case .server(let message):
                // The server refused outright — seats full, revoked, unknown. Do not store it.
                errorMessage = message
                return
            case .unreachable:
                // Offline activation is allowed: the key is cryptographically valid, and seat
                // enforcement catches up at the next heartbeat.
                break
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        LicenseStore.saveToken(token.raw)
        refresh()
    }

    /// Start the 14-day trial for an account.
    public func startTrial(email: String, password: String) async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }

        do {
            let raw = try await LicenseClient.startTrial(email: email, password: password)
            let token = try LicenseVerifier.verify(raw)
            guard !token.isExpired else {
                errorMessage = "This account's trial has already been used."
                state = .trialExpired
                return
            }
            _ = try? await LicenseClient.activate(token: raw)
            LicenseStore.saveToken(raw)
            refresh()
        } catch let error as LicenseClient.ClientError {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Ask the server whether this license is still good. Called on launch, in the background.
    ///
    /// Only ever *removes* access — it can revoke, never grant — so a hostile or spoofed server
    /// cannot unlock the app, and an unreachable one changes nothing.
    public func checkRevocation() async {
        guard let raw = LicenseStore.loadToken(), state.allowsUse else { return }

        do {
            let result = try await LicenseClient.heartbeat(token: raw)
            if result.revoked {
                LicenseStore.clearToken()
                state = .revoked
            } else if result.expired {
                refresh()
            }
        } catch {
            // Offline, or the service is down. Keep working.
        }
    }

    public func signOut() {
        LicenseStore.clearToken()
        refresh()
    }

    static func dateLabel(_ date: Date?) -> String {
        guard let date else { return "an unknown date" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

/// Thin HTTP client for the licensing endpoints. No third-party dependency, no retry storm.
public enum LicenseClient {
    /// Where the licensing service lives. Point at your own deployment.
    ///
    /// Lives here rather than on `LicenseManager` so the networking layer stays off the main
    /// actor — the client is called from background tasks and must not hop actors to read a URL.
    public nonisolated(unsafe) static var serviceOrigin = URL(string: "https://rizwanai.com")!

    public enum ClientError: LocalizedError {
        case unreachable
        case server(String)

        public var message: String {
            switch self {
            case .unreachable:
                return "Couldn't reach the licensing service. Check your connection."
            case .server(let text):
                return text
            }
        }

        public var errorDescription: String? { message }
    }

    public struct HeartbeatResult: Sendable {
        public let valid: Bool
        public let revoked: Bool
        public let expired: Bool
    }

    private static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    private static func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: serviceOrigin.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError.unreachable
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse else { throw ClientError.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.server(json["error"] as? String ?? "The licensing service refused that request.")
        }
        return json
    }

    public static func startTrial(email: String, password: String) async throws -> String {
        let json = try await post("v1/license/trial", body: ["email": email, "password": password])
        guard let token = json["token"] as? String, !token.isEmpty else {
            throw ClientError.server("The service did not return a trial key.")
        }
        return token
    }

    @discardableResult
    public static func activate(token: String) async throws -> Bool {
        let json = try await post("v1/license/activate", body: [
            "token": token,
            "machine_id": LicenseStore.machineID(),
            "machine_name": Host.current().localizedName ?? "Mac",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
        ])
        return json["activated"] as? Bool ?? false
    }

    public static func heartbeat(token: String) async throws -> HeartbeatResult {
        let json = try await post("v1/license/heartbeat", body: [
            "token": token, "machine_id": LicenseStore.machineID(),
        ])
        return HeartbeatResult(
            valid: json["valid"] as? Bool ?? false,
            revoked: json["revoked"] as? Bool ?? false,
            expired: json["expired"] as? Bool ?? false
        )
    }
}
