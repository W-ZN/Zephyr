import AppKit
import Foundation
import Testing
@testable import ZephyrRender

@MainActor
@Suite struct LinkPreviewLoadingTests {
    @Test func markdownIsRenderedUnlessExplicitLinesAreRequested() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-preview-loading-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("reference.md")
        try Data("# Heading\n\n**Actual Markdown**\n".utf8).write(to: url)
        let rendered = await LinkPreviewLoader.load(.markdown(url, nil))
        guard case let .markdown(_, text, baseURL, _) = rendered else { Issue.record("Expected native rendered Markdown"); return }
        #expect(text.hasPrefix("# Heading"))
        #expect(baseURL.path == directory.path)
        let anchored = await LinkPreviewLoader.load(.markdown(url, LinkPreviewLineRange(fragment: "L3")))
        guard case let .text(_, excerpt) = anchored else { Issue.record("Expected exact numbered source lines"); return }
        #expect(excerpt == "3  **Actual Markdown**")
    }

    @Test func hugeUnanchoredMarkdownUsesSmallOpenHint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-preview-large-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("huge.md")
        try Data(repeating: 0xFF, count: LinkPreviewLoader.markdownReadLimit + 1).write(to: url)
        let content = await LinkPreviewLoader.load(.markdown(url, nil))
        guard case let .failure(title, detail) = content else { Issue.record("Expected size hint without parsing"); return }
        #expect(title == "huge.md")
        #expect(!detail.isEmpty)
    }

    @Test func binaryFilesGetAnOpenHintWithoutDisplayingNulBytes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-binary-\(UUID()).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("bplist00\0data".utf8).write(to: url)
        let content = await LinkPreviewLoader.load(.text(url, nil))
        guard case let .file(title, detail) = content else { Issue.record("Expected binary file hint"); return }
        #expect(title == url.lastPathComponent && !detail.isEmpty)
    }
}
