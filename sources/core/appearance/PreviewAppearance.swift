import Foundation

/// The active appearance flattened for Finder's Quick Look extension. The extension can read this
/// narrow preference domain without access to the app's support files or theme folders.
public enum PreviewAppearance {
    public static let domain = "dev.zephyr.Zephyr.PreviewAppearance"
    public static let settingsKey = "flattenedAppearanceSettings"
    /// A setting may hold 64 KiB of custom CSS; allow its JSON envelope and the remaining settings
    /// while still rejecting an unexpectedly large preference value before parsing it.
    public static let maximumDataSize = 128 << 10

    /// Core Foundation preferences ignore `CFFIXED_USER_HOME` on this system. Test runs that set it
    /// therefore must not replace the user's real Finder appearance snapshot automatically.
    public static var isIsolatedRun: Bool { ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil }

    public enum SnapshotError: LocalizedError {
        case tooLarge
        case invalid([String])
        case synchronizeFailed

        public var errorDescription: String? {
            switch self {
            case .tooLarge: return "The Quick Look appearance snapshot is too large."
            case let .invalid(problems): return "The Quick Look appearance snapshot is invalid: \(problems.joined(separator: "; "))"
            case .synchronizeFailed: return "The Quick Look appearance snapshot could not be synchronized."
            }
        }
    }

    /// Writes the complete flattened raw settings, before CSS and process-only launch overrides.
    public static func publish(_ settings: AppearanceSettings, domain: String = Self.domain) throws {
        let data = settings.json()
        guard data.count <= maximumDataSize else { throw SnapshotError.tooLarge }
        CFPreferencesSetAppValue(settingsKey as CFString, data as CFData, domain as CFString)
        guard CFPreferencesAppSynchronize(domain as CFString) else { throw SnapshotError.synchronizeFailed }
    }

    /// Reads one fresh snapshot. `nil` means Zephyr has never published one; malformed snapshots
    /// are surfaced to the caller instead of being silently treated as the default appearance.
    public static func load(domain: String = Self.domain) throws -> AppearanceSettings? {
        _ = CFPreferencesAppSynchronize(domain as CFString)
        guard let data = CFPreferencesCopyAppValue(settingsKey as CFString, domain as CFString) as? Data else { return nil }
        guard data.count <= maximumDataSize else { throw SnapshotError.tooLarge }
        let parsed = AppearanceSettings.parse(json: data)
        guard parsed.problems.isEmpty else { throw SnapshotError.invalid(parsed.problems) }
        return parsed.settings
    }
}
