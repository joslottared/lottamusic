import Foundation
import Security

enum Storage {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return makeDir(base.appendingPathComponent("Lotta", isDirectory: true))
    }()

    static let downloads = makeDir(root.appendingPathComponent("Downloads", isDirectory: true))
    static let artwork = makeDir(root.appendingPathComponent("Artwork", isDirectory: true))
    static let lyrics = makeDir(root.appendingPathComponent("Lyrics", isDirectory: true))

    private static func makeDir(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
        return url
    }

    static func writeJSON<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: root.appendingPathComponent(name), options: .atomic)
    }

    static func readJSON<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
    }
}

/// Credentials live in the Keychain (falls back to UserDefaults if the
/// Keychain is unavailable for the signing identity).
enum CredentialStore {
    private static let service = "lotta.credentials"
    private static let fallbackKey = "lotta.credentials.fallback"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "default"]
    }

    static func save(_ creds: ServerCredentials) {
        guard let data = try? JSONEncoder().encode(creds) else { return }
        clear()
        var q = baseQuery
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(q as CFDictionary, nil) != errSecSuccess {
            UserDefaults.standard.set(data, forKey: fallbackKey)
        }
    }

    static func load() -> ServerCredentials? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let data: Data?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess {
            data = out as? Data
        } else {
            data = UserDefaults.standard.data(forKey: fallbackKey)
        }
        return data.flatMap { try? JSONDecoder().decode(ServerCredentials.self, from: $0) }
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey)
    }
}
