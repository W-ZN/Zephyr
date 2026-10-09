import Foundation
import Testing
@testable import ZephyrRender

@Suite struct LinkPreviewFileReaderTests {
    @Test func oversizedUnanchoredFileIsRejectedBeforeUTF8Decoding() throws {
        try withFixture { directory in
            let url = directory.appendingPathComponent("oversized.txt")
            try Data(repeating: 0xFF, count: LinkPreviewFileReader.readLimit + 1).write(to: url)
            #expect(try LinkPreviewFileReader.read(url, lines: nil).isTooLarge)
        }
    }

    @Test func anchoredReadFindsIndentedLinesPastTheUnanchoredLimit() throws {
        try withFixture { directory in
            let url = directory.appendingPathComponent("source.txt")
            let prefix = String(repeating: "x", count: LinkPreviewFileReader.readLimit + 128)
            try (prefix + "\n    indented\nnext").data(using: .utf8)!.write(to: url)
            let lines = try #require(LinkPreviewLineRange(fragment: "L2-L3"))
            #expect(try LinkPreviewFileReader.read(url, lines: lines).text == "2      indented\n3  next")
        }
    }

    @Test func anchoredReadTreatsLFCRLFAndCRAsSingleLineBreaks() throws {
        try withFixture { directory in
            let url = directory.appendingPathComponent("newlines.txt")
            try Data("one\r\ntwo\rthree\nfour".utf8).write(to: url)
            let lines = try #require(LinkPreviewLineRange(fragment: "L2-L4"))
            #expect(try LinkPreviewFileReader.read(url, lines: lines).text == "2  two\n3  three\n4  four")
        }
    }

    @Test func anchoredReadStopsAtTheScanLimitWhenTheRequestedStartIsLater() throws {
        try withFixture { directory in
            let url = directory.appendingPathComponent("late.txt")
            var data = Data(repeating: 0x78, count: LinkPreviewFileReader.scanLimit)
            data.append(contentsOf: "\nrequested".utf8)
            try data.write(to: url)
            let lines = try #require(LinkPreviewLineRange(fragment: "L2"))
            #expect(try LinkPreviewFileReader.read(url, lines: lines).isLinesUnavailable)
        }
    }

    @Test func anchoredReadBoundsSelectedOutputAndRejectsInvalidSelectedUTF8() throws {
        try withFixture { directory in
            let longURL = directory.appendingPathComponent("long.txt")
            try Data(repeating: 0x61, count: (70 << 10)).write(to: longURL)
            let firstLine = try #require(LinkPreviewLineRange(fragment: "L1"))
            let text = try #require(try LinkPreviewFileReader.read(longURL, lines: firstLine).text)
            #expect(text.hasPrefix("1  "))
            #expect(text.count <= LinkPreviewFileReader.displayLimit)

            let invalidURL = directory.appendingPathComponent("invalid.txt")
            try Data([0x6F, 0x6B, 0x0A, 0xFF]).write(to: invalidURL)
            let secondLine = try #require(LinkPreviewLineRange(fragment: "L2"))
            #expect(try LinkPreviewFileReader.read(invalidURL, lines: secondLine).isNotUTF8)
        }
    }

    private func withFixture(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build.noindex/output/file-reader-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private extension LinkPreviewFileReader.Result {
    var text: String? {
        guard case let .text(text) = self else { return nil }
        return text
    }

    var isTooLarge: Bool {
        guard case .tooLarge = self else { return false }
        return true
    }

    var isNotUTF8: Bool {
        guard case .notUTF8 = self else { return false }
        return true
    }

    var isLinesUnavailable: Bool {
        guard case .linesUnavailable = self else { return false }
        return true
    }
}
