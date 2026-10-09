import CryptoKit
import Foundation
import IOKit
import Security
import ZephyrCore

/// API keys, encrypted by Zephyr in its own data folder (design §10), one entry per endpoint: the
/// key is bound to the endpoint it was saved for and never leaves the app (not to CLI, MCP,
/// prompts or logs). Zephyr does not use the keychain at all, so rebuilt or re-signed apps never
/// ask for access (keys saved there by earlier versions are not read; they are entered again).
///
/// `credentials.json` holds AES-GCM sealed boxes with the endpoint as associated data (an entry
/// moved to another endpoint does not open). The key comes from HKDF over a random secret in
/// `credentials.key` and this Mac's hardware UUID, so a copy of the files, or a backup of them,
/// opens on no other Mac. Both files are readable by this user only. What this cannot do is hide
/// the key from a program running as the same user on this Mac; the login keychain could, at the
/// price of access prompts.
enum CredentialStore {
    /// `~/Library/Application Support/Zephyr`, the folder of `appearance.json`.
    static let folder = AppearanceState.fileURL.deletingLastPathComponent()
    private static var file: URL { folder.appendingPathComponent("credentials.json") }
    private static var secretFile: URL { folder.appendingPathComponent("credentials.key") }

    static func key(for account: String) -> String? {
        guard let sealed = entries()?[account].flatMap({ Data(base64Encoded: $0) }), let symmetric = symmetricKey(creating: false),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: symmetric, authenticating: Data(account.utf8)) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// A key that opens here: one restored from another Mac, or damaged, counts as none.
    static func hasKey(for account: String) -> Bool { key(for: account) != nil }

    static func setKey(_ key: String, for account: String) -> Bool {
        guard var all = entries(), let symmetric = symmetricKey(creating: true),
              let sealed = try? AES.GCM.seal(Data(key.utf8), using: symmetric, authenticating: Data(account.utf8)).combined else { return false }
        all[account] = sealed.base64EncodedString()
        return write(all)
    }

    static func removeKey(for account: String) -> Bool {
        guard var all = entries() else { return false }
        return all.removeValue(forKey: account) == nil || write(all)
    }

    // MARK: Files

    /// The saved entries; nil when the file is there but unreadable, so nothing overwrites it.
    private static func entries() -> [String: String]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
    }

    private static func write(_ entries: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(entries) else { return false }
        return save(data, to: file)
    }

    /// Written whole and readable by this user only.
    private static func save(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// The secret (made on first save, never replaced) bound to this Mac.
    private static func symmetricKey(creating: Bool) -> SymmetricKey? {
        var secret = try? Data(contentsOf: secretFile)
        if secret == nil, !FileManager.default.fileExists(atPath: secretFile.path) {
            guard creating else { return nil }
            var bytes = Data(count: 32)
            guard bytes.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess,
                  save(bytes, to: secretFile) else { return nil }
            secret = bytes
        }
        guard let secret, secret.count == 32, let machine = hardwareUUID else { return nil }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(machine.utf8),
                                      info: Data("dev.zephyr.Zephyr credentials v1".utf8), outputByteCount: 32)
    }

    private static let hardwareUUID: String? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }()
}
