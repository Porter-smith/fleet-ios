import Foundation
import Observation
import Security
import FleetKit

/// The pairing: which server, with which token. The token lives in the Keychain,
/// the URL in UserDefaults. FLEET_URL and FLEET_TOKEN in the launch environment
/// (UI tests, Xcode scheme) pair without touching either, and `-FleetDemo` runs on
/// the bundled fixtures with no server at all.
@MainActor @Observable
final class AppModel {
    private(set) var client: FleetClient?
    private(set) var serverURL: String
    private(set) var actor: FleetKit.Actor?
    /// Changes on every pairing, so the screens below start over.
    private(set) var pairing = UUID()

    init() {
        if ProcessInfo.processInfo.arguments.contains("-FleetDemo") {
            serverURL = "Demo"
            client = Demo.client()
            return
        }
        let env = ProcessInfo.processInfo.environment
        if let url = env["FLEET_URL"], let token = env["FLEET_TOKEN"], let base = FleetClient.normalize(url) {
            serverURL = base.absoluteString
            client = FleetClient(baseURL: base, token: token)
            return
        }
        serverURL = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        if let base = FleetClient.normalize(serverURL), let token = Keychain.read() {
            client = FleetClient(baseURL: base, token: token)
        }
    }

    private static let urlKey = "serverURL"

    /// Checks the token against GET /api/me before saving anything.
    func pair(url: String, token: String) async throws {
        guard let base = FleetClient.normalize(url) else { throw FleetError.badURL }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw FleetError.unauthorized("Paste a Fleet token.") }
        let candidate = FleetClient(baseURL: base, token: token)
        let me = try await candidate.me()
        try Keychain.save(token)
        UserDefaults.standard.set(base.absoluteString, forKey: Self.urlKey)
        serverURL = base.absoluteString
        actor = me.actor
        client = candidate
        pairing = UUID()
    }

    /// Runs the app on the bundled fixtures until Unpair. Nothing is saved.
    func startDemo() {
        serverURL = "Demo"
        actor = nil
        client = Demo.client()
        pairing = UUID()
    }

    func loadActor() async {
        guard let client else { return }
        if let me = try? await client.me() { actor = me.actor }
    }

    func unpair() {
        if serverURL != "Demo" { Keychain.delete() }
        serverURL = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        client = nil
        actor = nil
        pairing = UUID()
    }
}

/// One generic-password item holding the Fleet token, readable after first unlock, never synced.
enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.portersmith.fleet",
        kSecAttrAccount as String: "fleet-token",
    ]

    static func save(_ token: String) throws {
        delete()
        var query = base
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw FleetError.transport("Couldn't save the token in the Keychain (OSStatus \(status)).") }
    }

    static func read() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }
}
