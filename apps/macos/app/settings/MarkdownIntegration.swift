import AppKit
import UniformTypeIdentifiers
import ZephyrCore

/// File associations use the system's public API. They do not change other text formats.
@MainActor enum MarkdownIntegration {
    static var types: [UTType] {
        let markdown = UTType(importedAs: "net.daringfireball.markdown")
        var types = [markdown]
        for ext in FolderScanner.markdownExtensions.sorted() {
            if let type = UTType(filenameExtension: ext), !type.isDynamic,
               type != .plainText, type != .text, type != .data, !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    static var isDefault: Bool {
        types.allSatisfy { NSWorkspace.shared.urlForApplication(toOpen: $0)?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL }
    }

    static var defaultDescription: String {
        if isDefault { return String(localized: "Zephyr opens Markdown files from Finder.") }
        let names = Set(types.compactMap { NSWorkspace.shared.urlForApplication(toOpen: $0)?.deletingPathExtension().lastPathComponent }).sorted()
        return String(localized: "Current: \(names.joined(separator: ", "))")
    }

    static func setDefault() async throws {
        for type in types {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
    }

    /// Quick Look is a separate system extension choice, made only by this explicit action.
    static func enablePreview() async throws {
        let app = Bundle.main.bundleURL
        let plugin = app.appendingPathComponent("Contents/PlugIns/ZephyrQuickLook.appex")
        try await Task.detached(priority: .userInitiated) {
            for args in [["-a", plugin.path], ["-e", "use", "-i", "dev.zephyr.Zephyr.QuickLook"]] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
                process.arguments = args
                let error = Pipe()
                process.standardError = error
                process.standardOutput = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let message = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? String(localized: "Enable Zephyr in System Settings → General → Login Items & Extensions → Quick Look.") : message])
                }
            }
        }.value
    }
}
